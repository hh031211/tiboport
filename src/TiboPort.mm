// =============================================================================
//  TiboPort.mm —— M2-lite：悬浮球 + 日志面板 + il2cpp 探测
//
//  为什么这么改：你没有数据线，也没兴趣为了"看日志"再装一次包。
//  所以把"能看见"直接做进 UI —— 装一次，自己就能诊断，不需要电脑。
//
//  这一版自带验证：
//      屏幕上出现一个绿色的「TP」圆球  ⇒ dylib 已加载、签名正确、代码在跑
//      点它弹出日志面板             ⇒ 看到 il2cpp / 类名 / 游戏版本
//
//  设计上刻意**不碰渲染管线**（不 Hook Metal/GLES），只用 UIKit 覆盖层：
//  风险最低，和游戏互不干扰；真要画 ESP 再上渲染 Hook。
// =============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdlib.h>
#include <os/log.h>

// ------------------------------------------------------------------ 日志 ------
#define KP_MAX_LINES 600
static NSMutableArray<NSString *> *gLines = nil;
static NSLock   *gLock  = nil;
static NSString *gLogPath   = nil;
static NSString *gClassPath = nil;
static volatile int gProbeState = 0;   // 0=未开始 1=已就绪 2=完成/失败

static void KP(NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"%@ [TiboPort] %@", stamp, body];

    // 关键：NSLog 的动态内容在 iOS 统一日志里会被脱敏成 <private>，
    // 必须用 os_log + {public} 才能看到明文
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "%{public}s",
                     line.UTF8String ?: "");

    [gLock lock];
    if (gLines) {
        [gLines addObject:line];
        if (gLines.count > KP_MAX_LINES) [gLines removeObjectsInRange:NSMakeRange(0, 100)];
    }
    [gLock unlock];

    // 落盘（有 UIFileSharingEnabled 时可在「文件」App 里看到）
    @try {
        if (gLogPath) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:gLogPath])
                [fm createFileAtPath:gLogPath contents:nil attributes:nil];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        }
    } @catch (NSException *e) { }
}

static NSString *KPSnapshot(void)
{
    [gLock lock];
    NSString *s = [gLines componentsJoinedByString:@"\n"];
    [gLock unlock];
    return s;
}

// -------------------------------------------------------------- il2cpp ---------
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
    scope[0] = h ? h : RTLD_DEFAULT;
    scope[1] = RTLD_DEFAULT;
    #define R(sym, var)                                        \
        do { var = NULL;                                       \
             for (int _i = 0; _i < 2 && !var; _i++)             \
                 var = (void*)dlsym(scope[_i], sym); } while (0)
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

static void dump_classes(void *domain)
{
    size_t acount = 0;
    const void **asms = p_domain_get_assemblies(domain, &acount);
    KP(@"程序集数量 = %zu", acount);

    NSMutableString *buf = [NSMutableString stringWithString:@"# TiboPort class dump\n"];
    int goose = 0, mini = 0, other = 0;

    for (size_t i = 0; i < acount; i++) {
        const void *img = p_assembly_get_image(asms[i]);
        if (!img) continue;
        const char *iname = p_image_get_name(img);
        size_t cc = p_image_get_class_count(img);
        if (!iname) continue;
        KP(@"  %-40s classes=%zu", iname, cc);
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
            } else other++;
        }
    }
    KP(@"完成：Goose类=%d  MiniGame类=%d  其它=%d", goose, mini, other);

    @try {
        if (gClassPath)
            [buf writeToFile:gClassPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
}

static void probe_once(void)
{
    static int sQuiet = -1;   // 避免每秒刷屏
    if (!resolve_il2cpp()) {
        if (sQuiet != 0) { KP(@"il2cpp 符号未就绪（等 Unity 加载）"); sQuiet = 0; }
        gProbeState = 0; return;
    }
    void *domain = p_domain_get();
    if (!domain) {
        if (sQuiet != 1) { KP(@"il2cpp domain=NULL（Unity 还没初始化，继续等）"); sQuiet = 1; }
        gProbeState = 0; return;
    }
    sQuiet = 2;

    p_thread_attach(domain);
    KP(@"il2cpp 就绪 domain=%p，开始枚举", domain);

    dump_classes(domain);

    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    KP(@"游戏版本 %@ (%@)  iOS %@",
       info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"],
       [[UIDevice currentDevice] systemVersion]);
    KP(@"镜像数 %u", _dyld_image_count());

    Dl_info di; memset(&di, 0, sizeof(di));
    if (dladdr((void*)&probe_once, &di) && di.dli_fname) KP(@"self: %s", di.dli_fname);

    gProbeState = 2;
}

// ------------------------------------------------------------------ UI --------
static UIWindow   *gWin = nil;
static UIButton   *gBall = nil;
static UIView     *gPanel = nil;
static UITextView *gTV = nil;
static NSTimer    *gTimer = nil;
static BOOL        gPanelOpen = NO;

@interface TPShield : NSObject
+ (void)install;
+ (void)toggle;
+ (void)copyLog;
@end

@implementation TPShield

+ (UIWindowScene *)activeScene
{
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)s;
    }
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

+ (void)install
{
    UIWindowScene *sc = [self activeScene];
    if (!sc) return;   // 场景还没好，等重试

    gWin = [[UIWindow alloc] initWithWindowScene:sc];
    gWin.windowLevel = UIWindowLevelAlert + 100;
    gWin.backgroundColor = [UIColor clearColor];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    gWin.rootViewController = vc;
    gWin.hidden = NO;

    CGFloat side = 46;
    CGRect scr = sc.coordinateSpace.bounds;
    gBall = [UIButton buttonWithType:UIButtonTypeCustom];
    gBall.frame = CGRectMake(scr.size.width - side - 12, scr.size.height * 0.35, side, side);
    gBall.backgroundColor = [UIColor colorWithRed:0.18 green:0.85 blue:0.55 alpha:0.85];
    gBall.layer.cornerRadius = side / 2;
    gBall.layer.borderWidth = 1.5;
    gBall.layer.borderColor = [UIColor whiteColor].CGColor;
    [gBall setTitle:@"TP" forState:UIControlStateNormal];
    gBall.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [gBall setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [gBall addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [gWin addSubview:gBall];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    [gBall addGestureRecognizer:pan];

    // 面板
    CGFloat w = MIN(scr.size.width - 40, 520);
    CGFloat h = MIN(scr.size.height - 160, 460);
    gPanel = [[UIView alloc] initWithFrame:CGRectMake((scr.size.width - w) / 2,
                                                     (scr.size.height - h) / 2, w, h)];
    gPanel.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.94];
    gPanel.layer.cornerRadius = 12;
    gPanel.layer.borderWidth = 1;
    gPanel.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:1].CGColor;
    gPanel.hidden = YES;
    [gWin addSubview:gPanel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, w - 130, 28)];
    title.text = @"TiboPort 诊断";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [gPanel addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 44, 6, 36, 32);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:close];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    copy.frame = CGRectMake(w - 130, 6, 78, 32);
    [copy setTitle:@"复制日志" forState:UIControlStateNormal];
    copy.titleLabel.font = [UIFont systemFontOfSize:13];
    [copy setTitleColor:[UIColor colorWithRed:0.3 green:0.9 blue:0.6 alpha:1] forState:UIControlStateNormal];
    [copy addTarget:self action:@selector(copyLog) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:copy];

    UIButton *again = [UIButton buttonWithType:UIButtonTypeSystem];
    again.frame = CGRectMake(w - 214, 6, 78, 32);
    [again setTitle:@"重新探测" forState:UIControlStateNormal];
    again.titleLabel.font = [UIFont systemFontOfSize:13];
    [again setTitleColor:[UIColor colorWithRed:0.4 green:0.8 blue:1 alpha:1] forState:UIControlStateNormal];
    [again addTarget:self action:@selector(reprobe) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:again];

    gTV = [[UITextView alloc] initWithFrame:CGRectMake(10, 40, w - 20, h - 50)];
    gTV.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    gTV.textColor = [UIColor colorWithRed:0.75 green:1 blue:0.85 alpha:1];
    gTV.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    gTV.editable = NO;
    gTV.layer.cornerRadius = 8;
    gTV.text = KPSnapshot();
    [gPanel addSubview:gTV];

    gTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        if (gPanelOpen && gTV) {
            gTV.text = KPSnapshot();
            if (gTV.text.length > 2)
                [gTV scrollRangeToVisible:NSMakeRange(gTV.text.length - 1, 1)];
        }
    }];

    KP(@"悬浮球已就绪（点它看日志）");
}

+ (void)drag:(UIPanGestureRecognizer *)g
{
    UIView *v = g.view;
    CGPoint p = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + p.x, v.center.y + p.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

+ (void)toggle
{
    gPanelOpen = !gPanelOpen;
    gPanel.hidden = !gPanelOpen;
    if (gPanelOpen) gTV.text = KPSnapshot();
}

+ (void)reprobe
{
    KP(@"手动重新探测…");
    gProbeState = 0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try { probe_once(); } @catch (NSException *e) { KP(@"探测异常 %@", e); }
    });
}

+ (void)copyLog
{
    UIPasteboard.generalPasteboard.string = KPSnapshot();
    KP(@"日志已复制到剪贴板");
}

@end

// ------------------------------------------------------------------ 引导 ------
__attribute__((constructor))
static void tibo_init(void)
{
    gLock = [NSLock new];
    gLines = [NSMutableArray array];

    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs)
            docs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
        if (docs) {
            gLogPath   = [docs stringByAppendingPathComponent:@"TiboPort.log"];
            gClassPath = [docs stringByAppendingPathComponent:@"TiboPort-classes.txt"];
        }
    } @catch (NSException *e) { }

    KP(@"====== TiboPort 已加载 ======");
    KP(@"build %s %s", __DATE__, __TIME__);
    KP(@"log %@", gLogPath ?: @"(无)");

    // 场景就绪后装 UI（最多重试 60 次）
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int tries = 0;
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
            if (++tries > 60) { [tm invalidate]; return; }
            if (gWin) { [tm invalidate]; return; }
            if ([TPShield activeScene]) {
                [TPShield install];
                [tm invalidate];
            }
        }];
        (void)t;
    });

    // 后台探测
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 300 && gProbeState != 2; i++) {
            @try { probe_once(); } @catch (NSException *e) { KP(@"探测异常 %@", e); }
            if (gProbeState == 2) break;
            sleep(1);
        }
        if (gProbeState != 2) KP(@"300 秒内 Unity 未就绪（没进主场景属正常）");
    });
}
