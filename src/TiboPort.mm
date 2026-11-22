// =============================================================================
//  TiboPort.mm  v6  —— 真机可见 · 零触摸干扰 · 自动地图
//
//  这一版给你两样看得见的东西：
//    1. 屏幕左上角一个只读 HUD（程序集数 / Goose 类数 / 刷新时间）
//       —— userInteractionEnabled = NO，物理上不可能挡住任何触摸
//    2. Documents/TiboPort-dump.txt：带「字段名+偏移+类型」「方法名+参数个数」的
//       详细地图（下一版透视就用它定位）
//
//  稳定措施（前几版踩过的坑全部固化）：
//    - il2cpp 早期调用会 SIGSEGV(0x135) → sigsetjmp/siglongjmp 护栏 + 线程校验
//    - 覆盖层吞触摸 → HUD 整层 userInteractionEnabled=NO，且是子视图不是独立窗口
//    - 类名表随场景陆续加载 → 每 30 秒重扫，共 10 分钟
// =============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdlib.h>
#include <setjmp.h>
#include <signal.h>
#include <pthread.h>
#include <os/log.h>
#include <stdint.h>

// ------------------------------------------------------------------ 日志 ------
#define KP_MAX_LINES 400
static NSMutableArray<NSString *> *gLines = nil;
static NSLock   *gLock  = nil;
static NSString *gLogPath = nil, *gClassPath = nil, *gDumpPath = nil, *gCfgPath = nil;
static volatile int gProbeState = 0;

static void KP(NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ [TiboPort] %@",
                      [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle], body];

    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "%{public}s", line.UTF8String ?: "");

    [gLock lock];
    if (gLines) { [gLines addObject:line]; if (gLines.count > KP_MAX_LINES) [gLines removeObjectsInRange:NSMakeRange(0, 80)]; }
    [gLock unlock];

    @try {
        if (gLogPath) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:gLogPath]) [fm createFileAtPath:gLogPath contents:nil attributes:nil];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        }
    } @catch (NSException *e) { }
}

// ---- 运行期开关 ----
static BOOL tp_cfg_bool(NSString *key, BOOL def)
{
    @try {
        if (!gCfgPath) return def;
        NSString *txt = [NSString stringWithContentsOfFile:gCfgPath encoding:NSUTF8StringEncoding error:nil];
        if (!txt) return def;
        for (NSString *raw in [txt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *v = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([k isEqualToString:key]) return ([v intValue] != 0);
        }
    } @catch (NSException *e) { }
    return def;
}

static double tp_cfg_double(NSString *key, double def)
{
    @try {
        if (!gCfgPath) return def;
        NSString *txt = [NSString stringWithContentsOfFile:gCfgPath encoding:NSUTF8StringEncoding error:nil];
        if (!txt) return def;
        for (NSString *raw in [txt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (![k isEqualToString:key]) continue;
            NSString *v = [[line substringFromIndex:eq.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            return [v doubleValue];
        }
    } @catch (NSException *e) { }
    return def;
}

// -------------------------------------------------------------- il2cpp ---------
typedef void*        (*fn_domain_get)(void);
typedef void*        (*fn_thread_attach)(void *d);
typedef const void** (*fn_domain_get_assemblies)(void *d, size_t *n);
typedef const void*  (*fn_assembly_get_image)(const void *a);
typedef const char*  (*fn_image_get_name)(const void *i);
typedef size_t       (*fn_image_get_class_count)(const void *i);
typedef void*        (*fn_image_get_class)(const void *i, size_t idx);
typedef const char*  (*fn_class_get_name)(void *k);
typedef const char*  (*fn_class_get_namespace)(void *k);
typedef void*        (*fn_class_get_parent)(void *k);
typedef void*        (*fn_class_get_fields)(void *k, void **iter);
typedef void*        (*fn_class_get_methods)(void *k, void **iter);
typedef const char*  (*fn_field_get_name)(void *f);
typedef int32_t      (*fn_field_get_offset)(void *f);
typedef void*        (*fn_field_get_type)(void *f);
typedef const char*  (*fn_type_get_name)(void *t);
typedef const char*  (*fn_method_get_name)(void *m);
typedef uint32_t     (*fn_method_get_param_count)(void *m);
typedef void*        (*fn_class_from_name)(const void *img, const char *ns, const char *nm);
typedef void*        (*fn_class_get_method_from_name)(void *k, const char *nm, int argc);
typedef void*        (*fn_runtime_invoke)(void *m, void *obj, void **params, void **exc);

static fn_domain_get            p_domain_get;
static fn_thread_attach         p_thread_attach;
static fn_domain_get_assemblies p_domain_get_assemblies;
static fn_assembly_get_image    p_assembly_get_image;
static fn_image_get_name        p_image_get_name;
static fn_image_get_class_count p_image_get_class_count;
static fn_image_get_class       p_image_get_class;
static fn_class_get_name        p_class_get_name;
static fn_class_get_namespace   p_class_get_namespace;
static fn_class_get_parent      p_class_get_parent;
static fn_class_get_fields      p_class_get_fields;
static fn_class_get_methods     p_class_get_methods;
static fn_field_get_name        p_field_get_name;
static fn_field_get_offset      p_field_get_offset;
static fn_field_get_type        p_field_get_type;
static fn_type_get_name         p_type_get_name;
static fn_method_get_name       p_method_get_name;
static fn_method_get_param_count p_method_get_param_count;
static fn_class_from_name        p_class_from_name;
static fn_class_get_method_from_name p_class_get_method_from_name;
static fn_runtime_invoke         p_runtime_invoke;

static BOOL resolve_il2cpp(void)
{
    if (p_domain_get) return YES;
    void *h = dlopen("@executable_path/Frameworks/UnityFramework.framework/UnityFramework",
                     RTLD_NOW | RTLD_NOLOAD);
    void *scope[2]; scope[0] = h ? h : RTLD_DEFAULT; scope[1] = RTLD_DEFAULT;
    #define R(sym, var) do { var = NULL; for (int _i=0;_i<2&&!var;_i++) *(void **)&var=dlsym(scope[_i],sym); } while(0)
    R("il2cpp_domain_get", p_domain_get);
    R("il2cpp_thread_attach", p_thread_attach);
    R("il2cpp_domain_get_assemblies", p_domain_get_assemblies);
    R("il2cpp_assembly_get_image", p_assembly_get_image);
    R("il2cpp_image_get_name", p_image_get_name);
    R("il2cpp_image_get_class_count", p_image_get_class_count);
    R("il2cpp_image_get_class", p_image_get_class);
    R("il2cpp_class_get_name", p_class_get_name);
    R("il2cpp_class_get_namespace", p_class_get_namespace);
    R("il2cpp_class_get_parent", p_class_get_parent);
    R("il2cpp_class_get_fields", p_class_get_fields);
    R("il2cpp_class_get_methods", p_class_get_methods);
    R("il2cpp_field_get_name", p_field_get_name);
    R("il2cpp_field_get_offset", p_field_get_offset);
    R("il2cpp_field_get_type", p_field_get_type);
    R("il2cpp_type_get_name", p_type_get_name);
    R("il2cpp_method_get_name", p_method_get_name);
    R("il2cpp_method_get_param_count", p_method_get_param_count);
    R("il2cpp_class_from_name", p_class_from_name);
    R("il2cpp_class_get_method_from_name", p_class_get_method_from_name);
    R("il2cpp_runtime_invoke", p_runtime_invoke);
    #undef R
    return p_domain_get && p_thread_attach && p_domain_get_assemblies && p_assembly_get_image &&
           p_image_get_name && p_image_get_class_count && p_image_get_class &&
           p_class_get_name && p_class_get_namespace;
}


// ============================================================================
//  第一个真功能：视野调节（上帝视角的基础）
//  用法：Documents/TiboPort.cfg 写一行   fov=90
//        （游戏里每秒应用一次；改大=看得更远，改小=拉近）
//  走的是 UnityEngine.Camera.main.set_fieldOfView —— 不依赖任何游戏私有类
// ============================================================================
static void *gCamKlass = NULL, *gCamMain = NULL, *gCamSetFov = NULL;

static void *tp_find_class(const char *ns, const char *nm)
{
    if (!p_class_from_name || !p_domain_get) return NULL;
    void *domain = p_domain_get();
    if (!domain) return NULL;
    p_thread_attach(domain);
    size_t n = 0;
    const void **asms = p_domain_get_assemblies(domain, &n);
    for (size_t i = 0; i < n; i++) {
        const void *img = p_assembly_get_image(asms[i]);
        if (!img) continue;
        void *k = p_class_from_name(img, ns, nm);
        if (k) return k;
    }
    return NULL;
}

static void apply_fov(void)
{
    double want = tp_cfg_double(@"fov", 95);   // 默认 95°，比原版略宽；写 fov=0 可关闭
    if (want < 20 || want > 170) return;
    if (!p_runtime_invoke || !p_class_get_method_from_name) return;

    if (!gCamKlass) {
        gCamKlass = tp_find_class("UnityEngine", "Camera");
        if (!gCamKlass) { KP(@"找不到 UnityEngine.Camera"); return; }
        gCamMain   = p_class_get_method_from_name(gCamKlass, "get_main", 0);
        gCamSetFov = p_class_get_method_from_name(gCamKlass, "set_fieldOfView", 1);
        KP(@"Camera 定位：main=%p setFov=%p", gCamMain, gCamSetFov);
    }
    if (!gCamMain || !gCamSetFov) return;

    void *domain = p_domain_get(); if (domain) p_thread_attach(domain);
    void *exc = NULL;
    void *cam = p_runtime_invoke(gCamMain, NULL, NULL, &exc);
    if (!cam || exc) return;
    float f = (float)want;
    void *args[1] = { &f };
    exc = NULL;
    p_runtime_invoke(gCamSetFov, cam, args, &exc);
}

// ---------------------------------------------------------------- 崩溃护栏 ----
static sigjmp_buf gProbeJmp;
static volatile sig_atomic_t gProbeGuard = 0;
static volatile uintptr_t gProbeThread = 0;

static void tp_signal_handler(int sig, siginfo_t *si, void *uc)
{
    if (gProbeGuard && (uintptr_t)pthread_self() == gProbeThread) {
        gProbeGuard = 0; siglongjmp(gProbeJmp, 1);
    }
    struct sigaction sa; memset(&sa, 0, sizeof(sa)); sa.sa_handler = SIG_DFL;
    sigaction(sig, &sa, NULL); raise(sig);
}
static void tp_install_guard(void)
{
    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = tp_signal_handler; sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL);
}
static BOOL tp_image_loaded(const char *needle)
{
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) { const char *nm = _dyld_get_image_name(i); if (nm && strstr(nm, needle)) return YES; }
    return NO;
}

// ------------------------------------------------------------------ HUD -------
static UIView  *gHudHost = nil;
static UILabel *gHudLabel = nil;
static int gAsmCount = 0, gGooseCount = 0, gMiniCount = 0;
static NSString *gLastDumpTime = @"-";

static UIWindow *tp_key_window(void)
{
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static void hud_text(NSString *s)
{
    if (!gHudLabel) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        gHudLabel.text = s;
    });
}

// HUD 是"只读层"：userInteractionEnabled=NO ⇒ 系统在做 hitTest 时会整层跳过，
// 连子视图都不会被命中，物理上不可能挡住游戏触摸。
static void install_hud(void)
{
    if (gHudHost) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gHudHost) return;
        UIWindow *kw = tp_key_window();
        if (!kw) return;
        gHudHost = [[UIView alloc] initWithFrame:kw.bounds];
        gHudHost.userInteractionEnabled = NO;
        gHudHost.backgroundColor = [UIColor clearColor];
        gHudHost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        gHudLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 70, 300, 96)];
        gHudLabel.numberOfLines = 0;
        gHudLabel.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
        gHudLabel.textColor = [UIColor colorWithRed:0.55 green:1.0 blue:0.75 alpha:1.0];
        gHudLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        gHudLabel.layer.cornerRadius = 6;
        gHudLabel.clipsToBounds = YES;
        gHudLabel.text = @"TiboPort 启动中…";
        [gHudHost addSubview:gHudLabel];
        [kw addSubview:gHudHost];
    });
}

// ------------------------------------------------------------ 类名表 / 地图 ---
static const char *kKeyWords[] = {
    "Player","Actor","Role","Character","Camera","GameMgr","GameManager","Meeting",
    "Corpse","Kill","Sabotage","Vote","Task","Target","Vision","Body","Collider",
    "Goose","MiniGame","Seat","Hand","Card"
};

static BOOL kw_match(const char *ns, const char *cls)
{
    size_t n = sizeof(kKeyWords) / sizeof(kKeyWords[0]);
    for (size_t i = 0; i < n; i++) {
        if ((cls && strstr(cls, kKeyWords[i])) || (ns && strstr(ns, kKeyWords[i]))) return YES;
    }
    return NO;
}

static void write_file(NSString *path, NSString *content)
{
    @try { if (path) [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    @catch (NSException *e) { }
}

// 详细地图：命中的类 → 父类 / 字段(名+偏移+类型) / 方法(名+参数个数)
static void dump_detail(void *domain)
{
    if (!p_class_get_fields || !p_field_get_name || !p_class_get_methods) return;

    size_t acount = 0;
    const void **asms = p_domain_get_assemblies(domain, &acount);
    NSMutableString *out = [NSMutableString stringWithString:@"# TiboPort map (class|parent|field:name@offset:type|method:name/params)\n"];
    int classes = 0, hit = 0;

    for (size_t i = 0; i < acount && hit < 4000; i++) {
        const void *img = p_assembly_get_image(asms[i]);
        if (!img) continue;
        const char *iname = p_image_get_name(img);
        size_t cc = p_image_get_class_count(img);
        for (size_t k = 0; k < cc && hit < 4000; k++) {
            void *klass = p_image_get_class(img, k);
            if (!klass) continue;
            const char *cn = p_class_get_name(klass);
            if (!cn) continue;
            const char *ns = p_class_get_namespace(klass);
            classes++;
            if (!kw_match(ns, cn)) continue;
            hit++;

            void *parent = p_class_get_parent ? p_class_get_parent(klass) : NULL;
            const char *pn = (parent && p_class_get_name) ? p_class_get_name(parent) : "";

            [out appendFormat:@"\n[%s] %s.%s  ::  %s\n", iname ? iname : "", ns ? ns : "", cn, pn ? pn : ""];

            void *it = NULL;
            while (1) {
                void *f = p_class_get_fields(klass, &it);
                if (!f) break;
                const char *fn = p_field_get_name(f);
                int32_t off = p_field_get_offset ? p_field_get_offset(f) : -1;
                const char *tn = "";
                if (p_field_get_type && p_type_get_name) {
                    void *t = p_field_get_type(f);
                    if (t) { const char *nm = p_type_get_name(t); if (nm) tn = nm; }
                }
                [out appendFormat:@"  F %s @0x%x : %s\n", fn ? fn : "?", off, tn];
            }

            it = NULL;
            int mc = 0;
            while (mc < 80) {
                void *m = p_class_get_methods(klass, &it);
                if (!m) break;
                const char *mn = p_method_get_name ? p_method_get_name(m) : "?";
                uint32_t pc = p_method_get_param_count ? p_method_get_param_count(m) : 0;
                [out appendFormat:@"  M %s/%u\n", mn ? mn : "?", pc];
                mc++;
            }
        }
    }
    [out appendFormat:@"\n# total classes=%d  matched=%d\n", classes, hit];
    write_file(gDumpPath, out);
    gLastDumpTime = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                  dateStyle:NSDateFormatterNoStyle
                                                  timeStyle:NSDateFormatterMediumStyle];
    KP(@"地图已刷新：扫描 %d 类，命中 %d 类 → TiboPort-dump.txt", classes, hit);
}

static void dump_classnames(void *domain)
{
    size_t acount = 0;
    const void **asms = p_domain_get_assemblies(domain, &acount);
    NSMutableString *buf = [NSMutableString stringWithString:@"# TiboPort class dump\n"];
    int goose = 0, mini = 0;
    for (size_t i = 0; i < acount; i++) {
        const void *img = p_assembly_get_image(asms[i]);
        if (!img) continue;
        const char *iname = p_image_get_name(img);
        size_t cc = p_image_get_class_count(img);
        if (!iname || cc == 0) continue;
        for (size_t k = 0; k < cc; k++) {
            void *klass = p_image_get_class(img, k);
            if (!klass) continue;
            const char *cn = p_class_get_name(klass);
            if (!cn) continue;
            const char *ns = p_class_get_namespace(klass);
            BOOL isG = (ns && strstr(ns, "Goose")) || strstr(cn, "Goose");
            BOOL isM = (ns && strstr(ns, "MiniGame")) || strstr(cn, "MiniGame");
            if (isG || isM) {
                [buf appendFormat:@"%s|%s|%s\n", iname, ns ? ns : "", cn];
                if (isG) goose++; else mini++;
            }
        }
    }
    write_file(gClassPath, buf);
    gAsmCount = (int)acount; gGooseCount = goose; gMiniCount = mini;
    KP(@"类名表：程序集=%zu Goose=%d MiniGame=%d", acount, goose, mini);
}

// ------------------------------------------------------------- 探测 -----------
static void probe_once(void)
{
    static int sQuiet = -1;
    if (!resolve_il2cpp()) { if (sQuiet != 0) { KP(@"il2cpp 未就绪（等 Unity）"); sQuiet = 0; } gProbeState = 0; return; }
    void *domain = p_domain_get();
    if (!domain) { if (sQuiet != 1) { KP(@"il2cpp domain=NULL（等初始化）"); sQuiet = 1; } gProbeState = 0; return; }
    sQuiet = 2;

    p_thread_attach(domain);
    KP(@"il2cpp 就绪 domain=%p", domain);

    dump_classnames(domain);
    dump_detail(domain);

    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    KP(@"游戏 %@ (%@)  iOS %@", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"],
       [[UIDevice currentDevice] systemVersion]);
    gProbeState = 2;
}

static BOOL probe_guarded(void)
{
    if (sigsetjmp(gProbeJmp, 1) != 0) {
        gProbeGuard = 0;
        KP(@"探测撞到未初始化的 il2cpp，已安全跳过（未崩溃）");
        return NO;
    }
    gProbeGuard = 1; gProbeThread = (uintptr_t)pthread_self();
    @try { probe_once(); } @catch (NSException *e) { KP(@"探测异常 %@", e); }
    gProbeGuard = 0;
    return (gProbeState == 2);
}

static void probe_keychain(void)
{
    @try {
        NSDictionary *q = @{ (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
                             (__bridge id)kSecAttrService : @"TiboPortProbe",
                             (__bridge id)kSecAttrAccount : @"probe",
                             (__bridge id)kSecValueData : [@"x" dataUsingEncoding:NSUTF8StringEncoding] };
        SecItemDelete((__bridge CFDictionaryRef)q);
        OSStatus a = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
        SecItemDelete((__bridge CFDictionaryRef)q);
        KP(@"keychain add=%d", (int)a);
    } @catch (NSException *e) { }
}

// ------------------------------------------------------------------ 引导 ------
__attribute__((constructor))
static void tibo_init(void)
{
    gLock = [NSLock new];
    gLines = [NSMutableArray array];

    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs) docs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
        if (docs) {
            gLogPath   = [docs stringByAppendingPathComponent:@"TiboPort.log"];
            gClassPath = [docs stringByAppendingPathComponent:@"TiboPort-classes.txt"];
            gDumpPath  = [docs stringByAppendingPathComponent:@"TiboPort-dump.txt"];
            gCfgPath   = [docs stringByAppendingPathComponent:@"TiboPort.cfg"];
        }
    } @catch (NSException *e) { }

    tp_install_guard();
    KP(@"====== TiboPort v6 已加载 ======");
    KP(@"build %s %s", __DATE__, __TIME__);
    KP(@"log %@", gLogPath ?: @"(无)");
    probe_keychain();

    BOOL hudOn = tp_cfg_bool(@"hud", YES);
    KP(@"HUD = %@（Documents/TiboPort.cfg 写 hud=0 可关闭）", hudOn ? @"开" : @"关");

    // HUD（只读层，不接收触摸）
    if (hudOn) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __block int tries = 0;
            NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
                if (++tries > 60) { [tm invalidate]; return; }
                install_hud();
                if (gHudHost) [tm invalidate];
            }];
            (void)t;
        });
        NSTimer *u = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
            (void)tm;
            hud_text([NSString stringWithFormat:
                      @"TiboPort v6\nasm=%d  goose=%d  mini=%d\nmap=%@\nprobe=%@",
                      gAsmCount, gGooseCount, gMiniCount, gLastDumpTime,
                      gProbeState == 2 ? @"OK" : @"等待中"]);
        }];
        (void)u;
    }

    // 视野功能：主线程每秒应用一次（Unity API 必须在主线程碰）
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *ft = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
            (void)tm;
            @try { apply_fov(); } @catch (NSException *e) { }
        }];
        (void)ft;
    });

    // 后台探测 + 周期性重扫
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int waited = 0;
        while (waited < 120 && !tp_image_loaded("UnityFramework")) { sleep(1); waited++; }
        if (!tp_image_loaded("UnityFramework")) { KP(@"UnityFramework 未出现"); return; }
        KP(@"UnityFramework 已加载（等 %d 秒），再等 6 秒", waited);
        sleep(6);

        for (int i = 0; i < 300 && gProbeState != 2; i++) {
            if (probe_guarded()) break;
            sleep(2);
        }
        if (gProbeState != 2) { KP(@"首轮探测未成功"); return; }

        for (int k = 0; k < 20; k++) {
            sleep(30);
            @try { if (probe_guarded()) { } } @catch (NSException *e) { KP(@"重扫异常 %@", e); }
        }
        KP(@"周期性重扫结束");
    });
}
