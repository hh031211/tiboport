// =============================================================================
//  TiboPort.mm —— M1「打招呼版」dylib   (build 标记见运行时日志)
//
//  它只做四件事，**不碰游戏逻辑**：
//    1. 证明自己活着（dylib 被加载 + 签名有效）
//    2. 保持你的登录绕过（dlopen OfflineProvider.dylib）
//    3. 等 Unity 起来，探 il2cpp
//    4. 把 Goose.* / MiniGame.* 的类名全表 dump 出来（后续所有功能的地基）
//
//  输出双通道（任一条通即可拿到结果）：
//    A. NSLog  → syslog，用爱思助手「实时日志」过滤 TiboPort
//    B. 文件   → <沙盒>/Documents/TiboPort.log + TiboPort-classes.txt
//
//  设计原则：任何一步失败都只写日志、绝不抛异常、绝不 exit —— 保证"最坏也只是没功能"。
// =============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <unistd.h>
#include <stdarg.h>

// ---------------------------------------------------------------- 日志 ---------
static NSString *gLogPath   = nil;
static NSString *gClassPath = nil;
static NSLock   *gLock      = nil;
static volatile int gDone   = 0;

static void KP(NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[TiboPort] %@", body];

    NSLog(@"%@", line);                         // 通道 A

    @try {                                      // 通道 B
        [gLock lock];
        if (gLogPath) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:gLogPath])
                [fm createFileAtPath:gLogPath contents:nil attributes:nil];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[[line stringByAppendingString:@"\n"]
                               dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        }
        [gLock unlock];
    } @catch (NSException *e) { }
}

static void KPLine(NSString *text)
{
    @try {
        [gLock lock];
        if (gClassPath) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:gClassPath])
                [fm createFileAtPath:gClassPath contents:nil attributes:nil];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gClassPath];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[[text stringByAppendingString:@"\n"]
                               dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        }
        [gLock unlock];
    } @catch (NSException *e) { }
}

// ------------------------------------------------------ il2cpp API 类型 ----------
typedef void*        (*fn_domain_get)(void);
typedef void*        (*fn_thread_attach)(void *domain);
typedef const void** (*fn_domain_get_assemblies)(void *domain, size_t *count);
typedef const void*  (*fn_assembly_get_image)(const void *assembly);
typedef const char*  (*fn_image_get_name)(const void *image);
typedef size_t       (*fn_image_get_class_count)(const void *image);
typedef void*        (*fn_image_get_class)(const void *image, size_t index);
typedef const char*  (*fn_class_get_name)(void *klass);
typedef const char*  (*fn_class_get_namespace)(void *klass);

static fn_domain_get            p_domain_get;
static fn_thread_attach         p_thread_attach;
static fn_domain_get_assemblies p_domain_get_assemblies;
static fn_assembly_get_image    p_assembly_get_image;
static fn_image_get_name        p_image_get_name;
static fn_image_get_class_count p_image_get_class_count;
static fn_image_get_class       p_image_get_class;
static fn_class_get_name        p_class_get_name;
static fn_class_get_namespace   p_class_get_namespace;

static BOOL resolve_il2cpp(void)
{
    if (p_domain_get) return YES;

    void *h = dlopen("@executable_path/Frameworks/UnityFramework.framework/UnityFramework",
                     RTLD_NOW | RTLD_NOLOAD);
    void *scope[2];
    scope[0] = h ? h : RTLD_DEFAULT;   // 绝不把 NULL 当 handle 传给 dlsym
    scope[1] = RTLD_DEFAULT;

    #define R(sym, var)                                        \
        do {                                                   \
            var = NULL;                                        \
            for (int _i = 0; _i < 2 && !var; _i++)              \
                var = (void*)dlsym(scope[_i], sym);             \
        } while (0)

    R("il2cpp_domain_get",            p_domain_get);
    R("il2cpp_thread_attach",         p_thread_attach);
    R("il2cpp_domain_get_assemblies", p_domain_get_assemblies);
    R("il2cpp_assembly_get_image",    p_assembly_get_image);
    R("il2cpp_image_get_name",        p_image_get_name);
    R("il2cpp_image_get_class_count", p_image_get_class_count);
    R("il2cpp_image_get_class",       p_image_get_class);
    R("il2cpp_class_get_name",        p_class_get_name);
    R("il2cpp_class_get_namespace",   p_class_get_namespace);
    #undef R

    return p_domain_get && p_thread_attach && p_domain_get_assemblies &&
           p_assembly_get_image && p_image_get_name &&
           p_image_get_class_count && p_image_get_class &&
           p_class_get_name && p_class_get_namespace;
}

// ------------------------------------------------------- 登录绕过层（可选）------
//  实测：OfflineProvider.dylib 是登录绕过（WYLoginController / IsAuthorized /
//  ValidateLogin / chupianer.com/wy.php），原先由 KakaSDK dlopen。
//  这里只 dlopen（跑它的构造器），不猜函数签名 —— 没有这个文件也不会崩。
#define KP_LOAD_OFFLINE_PROVIDER 0   // 官方干净包里没有这个文件；破解包才需要 1

static void load_offline_provider(void)
{
#if KP_LOAD_OFFLINE_PROVIDER
    void *h = dlopen("@executable_path/OfflineProvider.dylib", RTLD_NOW);
    if (h) KP(@"OfflineProvider 已加载（登录绕过保持原样）");
    else   KP(@"OfflineProvider 未加载：%s（不影响游戏，走官方登录）",
              dlerror() ?: "?");
#endif
}

// ------------------------------------------------------------- 类名表 -----------
static int gGoose = 0, gMini = 0, gTotal = 0;

static BOOL ns_match(const char *ns, const char *cls, const char *pat)
{
    if (ns  && strstr(ns,  pat)) return YES;
    if (cls && strstr(cls, pat)) return YES;
    return NO;
}

static void dump_classes(void *domain)
{
    size_t acount = 0;
    const void **asms = p_domain_get_assemblies(domain, &acount);
    KP(@"il2cpp: 程序集数量 = %zu", acount);

    KPLine(@"# TiboPort class dump  (Goose.* / MiniGame.*)");
    KPLine([NSString stringWithFormat:@"# assemblies=%zu", acount]);

    for (size_t i = 0; i < acount; i++) {
        const void *img = p_assembly_get_image(asms[i]);
        if (!img) continue;
        const char *iname = p_image_get_name(img);
        size_t cc = p_image_get_class_count(img);
        KP(@"  image[%zu] %s  classes=%zu", i, iname ? iname : "(null)", cc);
        if (!iname || cc == 0) continue;

        for (size_t k = 0; k < cc; k++) {
            void *klass = p_image_get_class(img, k);
            if (!klass) continue;
            const char *cn = p_class_get_name(klass);
            if (!cn) continue;
            const char *ns = p_class_get_namespace(klass);

            BOOL isGoose = ns_match(ns, cn, "Goose");
            BOOL isMini  = ns_match(ns, cn, "MiniGame");
            if (!isGoose && !isMini) { gTotal++; continue; }

            KPLine([NSString stringWithFormat:@"%s|%s|%s",
                    iname, ns ? ns : "", cn]);
            if (isGoose) gGoose++; else gMini++;
        }
    }
    KP(@"il2cpp: 完成。Goose类=%d  MiniGame类=%d  其它类=%d", gGoose, gMini, gTotal);
    KP(@"类名表 -> Documents/TiboPort-classes.txt（%d 行）", gGoose + gMini);
}

// ------------------------------------------------------------- 探测主体 ---------
static void probe_once(void)
{
    if (!resolve_il2cpp()) { KP(@"il2cpp: 符号未就绪（等下再试）"); return; }

    void *domain = p_domain_get();
    if (!domain) { KP(@"il2cpp: domain_get() = NULL（Unity 还没初始化）"); return; }

    p_thread_attach(domain);
    KP(@"il2cpp: domain=%p 就绪，开始枚举", domain);

    dump_classes(domain);

    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    KP(@"app: %@ v%@ (%@)  iOS %@", info[@"CFBundleIdentifier"],
       info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"],
       [[UIDevice currentDevice] systemVersion]);

    Dl_info di; memset(&di, 0, sizeof(di));
    if (dladdr((void*)&probe_once, &di) && di.dli_fname)
        KP(@"self: %s", di.dli_fname);
    KP(@"dyld: 已加载镜像数 = %u", _dyld_image_count());

    gDone = 1;
}

// --------------------------------------------------------------- 引导 -----------
__attribute__((constructor))
static void TiboPort_init(void)
{
    gLock = [NSLock new];

    @try {
        NSString *docs = nil;
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count) docs = paths.firstObject;
        if (!docs)
            docs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
        if (docs) {
            gLogPath   = [docs stringByAppendingPathComponent:@"TiboPort.log"];
            gClassPath = [docs stringByAppendingPathComponent:@"TiboPort-classes.txt"];
        }
    } @catch (NSException *e) { }

    KP(@"====== M1 打招呼版已加载 ======");
    KP(@"build=%s %s", __DATE__, __TIME__);
    KP(@"log=%@", gLogPath ?: @"(拿不到 Documents 路径，只看 syslog)");

    for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "UnityFramework")) {
            KP(@"UnityFramework 已在镜像列表: %s", nm);
            break;
        }
    }

    @try { load_offline_provider(); }
    @catch (NSException *e) { KP(@"OfflineProvider 加载异常: %@", e); }

    // 后台重试：登录进大厅可能要好几分钟，所以给 300 秒
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 300 && !gDone; i++) {
            @try { probe_once(); } @catch (NSException *e) { KP(@"probe 异常: %@", e); }
            if (gDone) break;
            sleep(1);
        }
        if (!gDone) KP(@"300 秒内 Unity 未就绪（可能没进到主场景，属正常）");
    });
}
