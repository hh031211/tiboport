// =============================================================================
//  TiboPort.mm  v7  —— 真·透视（ESP）
//
//  已从 v6 的地图里确认（Goose.dll）：
//      Goose.GooseGame :: GameSystem
//        F players @0x40 : Dictionary<Int64, Goose.Actors.PlayerActor>
//        F <player>k__BackingField @0x48 : Goose.Actors.MainPlayer
//        ... 且 Goose.Actors.PlayerActor / MainPlayer 类名可运行时查到
//
//  本版做的事：
//    1) 运行时定位 Goose.GooseGame 实例（静态 getter 探测）
//    2) 取 players 字典 → get_Values() → CopyTo(PlayerActor[]) 拿到全部玩家
//    3) 每个 PlayerActor：transform.position → Camera.WorldToScreenPoint
//    4) 在只读覆盖层上画框 + 距离 + 队友/敌人分色（按与本地玩家距离判定自身）
//    5) 全套崩溃护栏 + 详细诊断日志（找不到哪一步会明说）
//
//  设计原则：任何一步失败只写日志、不崩、不影响游戏；所有覆盖层 userInteractionEnabled=NO。
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
#include <stdint.h>
#include <setjmp.h>
#include <signal.h>
#include <pthread.h>
#include <os/log.h>

// ------------------------------------------------------------------ 日志 ------
static NSMutableArray<NSString *> *gLines = nil;
static NSLock   *gLock  = nil;
static NSString *gLogPath = nil, *gClassPath = nil, *gDumpPath = nil, *gCfgPath = nil, *gApiPath = nil;

// 前向声明（后面 8xx 行才定义，先声明免得编译报错）
static void write_file(NSString *path, NSString *content);
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
    if (gLines) { [gLines addObject:line]; if (gLines.count > 500) [gLines removeObjectsInRange:NSMakeRange(0, 100)]; }
    [gLock unlock];
    @try {
        if (gLogPath) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:gLogPath]) [fm createFileAtPath:gLogPath contents:nil attributes:nil];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            if (fh) { [fh seekToEndOfFile]; [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        }
    } @catch (NSException *e) { }
}

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
typedef void*        (*fn_object_unbox)(void *o);
typedef void*        (*fn_object_get_class)(void *o);
typedef void*        (*fn_array_new)(void *klass, size_t n);
typedef uint64_t     (*fn_array_length)(void *arr);
typedef void*        (*fn_class_get_type)(void *k);
typedef void*        (*fn_type_get_object)(void *t);
typedef void*        (*fn_method_get_return_type)(void *m);

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
static fn_class_from_name       p_class_from_name;
static fn_class_get_method_from_name p_class_get_method_from_name;
static fn_runtime_invoke        p_runtime_invoke;
static fn_object_unbox          p_object_unbox;
static fn_object_get_class      p_object_get_class;
static fn_array_new             p_array_new;
static fn_array_length          p_array_length;
static fn_class_get_type        p_class_get_type;
static fn_type_get_object       p_type_get_object;
static fn_method_get_return_type p_method_get_return_type;

static BOOL resolve_il2cpp(void)
{
    if (p_domain_get) return YES;
    void *h = dlopen("@executable_path/Frameworks/UnityFramework.framework/UnityFramework",
                     RTLD_NOW | RTLD_NOLOAD);
    void *scope[2]; scope[0] = h ? h : RTLD_DEFAULT; scope[1] = RTLD_DEFAULT;
    #define R(sym, var) do { var=NULL; for (int _i=0;_i<2&&!var;_i++) *(void **)&var=dlsym(scope[_i],sym); } while(0)
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
    R("il2cpp_object_unbox", p_object_unbox);
    R("il2cpp_object_get_class", p_object_get_class);
    R("il2cpp_array_new", p_array_new);
    R("il2cpp_array_length", p_array_length);
    R("il2cpp_class_get_type", p_class_get_type);
    R("il2cpp_type_get_object", p_type_get_object);
    R("il2cpp_method_get_return_type", p_method_get_return_type);
    #undef R
    return p_domain_get && p_thread_attach && p_class_from_name && p_runtime_invoke && p_object_unbox;
}

// ---------------------------------------------------------------- 崩溃护栏 ----
static sigjmp_buf gProbeJmp;          // 探测上下文（后台线程）
static volatile sig_atomic_t gProbeGuard = 0;
static volatile uintptr_t gProbeThread = 0;

static sigjmp_buf gEspJmp;            // 主线程上下文（ESP / FOV 调用托管方法）
static volatile sig_atomic_t gEspGuard = 0;
static volatile uintptr_t gEspThread = 0;

static void tp_signal_handler(int sig, siginfo_t *si, void *uc)
{
    if (gProbeGuard && (uintptr_t)pthread_self() == gProbeThread) { gProbeGuard = 0; siglongjmp(gProbeJmp, 1); }
    if (gEspGuard   && (uintptr_t)pthread_self() == gEspThread)   { gEspGuard   = 0; siglongjmp(gEspJmp, 1); }
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

// ---- 受护栏保护的"调用托管方法" ----
static void *gLastInvokeResult = NULL;
static void *invoke_guarded(void *method, void *obj, void **args)
{
    if (!method || !p_runtime_invoke) return NULL;
    if (sigsetjmp(gEspJmp, 1) != 0) {
        gEspGuard = 0;
        KP(@"调用托管方法时被护栏拦下（已跳过，未崩溃）");
        return NULL;
    }
    gEspGuard = 1; gEspThread = (uintptr_t)pthread_self();
    void *exc = NULL;
    void *r = p_runtime_invoke(method, obj, args, &exc);
    gEspGuard = 0;
    if (exc) { KP(@"托管方法抛异常（已忽略）"); return NULL; }
    return r;
}


static CGRect gCanvasScreenBounds = {0};

@interface ESP : NSObject
@property (nonatomic, strong) UIView *canvas;
@property (nonatomic, strong) NSMutableArray<UIView *> *boxes;
@property (nonatomic, strong) NSMutableArray<UILabel *> *labels;
+ (instancetype)shared;
- (void)refresh;
- (void)clear;
- (void)draw:(NSArray *)pts;
@end

// ------------------------------------------------------------------ HUD -------
static UIView  *gHudHost = nil;
static UILabel *gHudLabel = nil;
static int gAsmCount = 0, gGooseCount = 0, gMiniCount = 0, gPlayerCount = 0;
static NSString *gLastDumpTime = @"-", *gEspState = @"off";

static UIWindow *tp_key_window(void)
{
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) { if (w.isKeyWindow) return w; }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static void hud_text(NSString *s)
{
    if (!gHudLabel) return;
    dispatch_async(dispatch_get_main_queue(), ^{ gHudLabel.text = s; });
}

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

        gHudLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 70, 300, 104)];
        gHudLabel.numberOfLines = 0;
        gHudLabel.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
        gHudLabel.textColor = [UIColor colorWithRed:0.55 green:1.0 blue:0.75 alpha:1.0];
        gHudLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        gHudLabel.layer.cornerRadius = 6;
        gHudLabel.clipsToBounds = YES;
        gHudLabel.text = @"TiboPort v10 启动中…";
        [gHudHost addSubview:gHudLabel];
        [gHudHost addSubview:[ESP shared].canvas];
        [kw addSubview:gHudHost];
    });
}

// ------------------------------------------------------------------ ESP -------
#define ESP_MAX_BOX 40
#define IL2CPP_ARRAY_HDR 0x20

@implementation ESP

+ (instancetype)shared
{
    static ESP *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ESP new]; [s setup]; });
    return s;
}

- (void)setup
{
    _canvas = [[UIView alloc] initWithFrame:CGRectZero];
    _canvas.userInteractionEnabled = NO;
    _canvas.backgroundColor = [UIColor clearColor];
    _boxes = [NSMutableArray array];
    _labels = [NSMutableArray array];
    for (int i = 0; i < ESP_MAX_BOX; i++) {
        UIView *b = [UIView new];
        b.userInteractionEnabled = NO;
        b.backgroundColor = [UIColor clearColor];
        b.layer.borderWidth = 1.5;
        b.layer.borderColor = [UIColor redColor].CGColor;
        b.hidden = YES;
        [_canvas addSubview:b];
        [_boxes addObject:b];

        UILabel *l = [UILabel new];
        l.userInteractionEnabled = NO;
        l.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
        l.textColor = [UIColor whiteColor];
        l.hidden = YES;
        [_canvas addSubview:l];
        [_labels addObject:l];
    }
}

// ---- 缓存的运行时句柄 ----
// 依据 TiboPort-api.txt 实测：
//   PlayerActor : SpineCharacterActor : SpineRoleActor : AssetActor`1 : ActorBase : RenderObject
//   全程没有 get_transform / position —— 这是 Spine 2D 骨骼角色
//   可用：get_center(Vector3) get_size(Vector3) get_name(string) get_uid(long)
//         get_status(RoleStatus) get_ShowID(int)
static void *s_ggKlass = NULL;
static void *s_playersField = NULL;
static int32_t s_playersOff = -1;
static void *s_paKlass = NULL;
static void *s_getCenter = NULL, *s_getSize = NULL, *s_getName = NULL;
static void *s_getUid = NULL, *s_getStatus = NULL, *s_getShowID = NULL;
static void *s_getScreenPos = NULL;   // SpineRoleActor.GetScreenPosition(int) -> Vector2
static void *s_getMainPlayer = NULL;
static void *s_camKlass = NULL, *s_camMain = NULL, *s_w2s = NULL;
static int   s_ready = 0;

static void *tp_find_class(const char *ns, const char *nm)
{
    if (!p_class_from_name || !p_domain_get) return NULL;
    void *domain = p_domain_get(); if (!domain) return NULL;
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

static void *tp_field_by_name(void *klass, const char *name)
{
    if (!klass || !p_class_get_fields) return NULL;
    void *it = NULL;
    while (1) {
        void *f = p_class_get_fields(klass, &it);
        if (!f) break;
        const char *fn = p_field_get_name(f);
        if (fn && strcmp(fn, name) == 0) return f;
    }
    return NULL;
}

static void *tp_method_in_hierarchy(void *k, const char *name, int argc)
{
    void *cur = k;
    for (int i = 0; i < 12 && cur; i++) {
        void *m = p_class_get_method_from_name(cur, name, argc);
        if (m) return m;
        cur = p_class_get_parent ? p_class_get_parent(cur) : NULL;
    }
    return NULL;
}

static void *tp_field_ptr(void *obj, int32_t off)
{
    if (!obj || off < 0) return NULL;
    return *(void **)((char *)obj + off);
}

// Il2CppString -> NSString  (layout: klass(8) monitor(8) length(4) utf16chars)
static NSString *tp_str(void *il2cppStr)
{
    if (!il2cppStr) return nil;
    @try {
        int32_t len = *(int32_t *)((char *)il2cppStr + 0x10);
        if (len <= 0 || len > 256) return nil;
        const unichar *p = (const unichar *)((char *)il2cppStr + 0x14);
        return [NSString stringWithCharacters:p length:(NSUInteger)len];
    } @catch (NSException *e) { return nil; }
}

static int32_t tp_int(void *boxed)
{
    if (!boxed || !p_object_unbox) return 0;
    int32_t *p = (int32_t *)p_object_unbox(boxed);
    return p ? *p : 0;
}
static int64_t tp_long(void *boxed)
{
    if (!boxed || !p_object_unbox) return 0;
    int64_t *p = (int64_t *)p_object_unbox(boxed);
    return p ? *p : 0;
}
static BOOL tp_vec(void *boxed, float out[3])
{
    if (!boxed || !p_object_unbox) return NO;
    float *p = (float *)p_object_unbox(boxed);
    if (!p) return NO;
    out[0] = p[0]; out[1] = p[1]; out[2] = p[2];
    return YES;
}

// ---------------------------------------------------------------- 实例发现 ----
static void *s_ggInstance = NULL;

static BOOL tp_is_goose_ns(const char *ns)
{
    if (!ns) return NO;
    return strncmp(ns, "Goose", 5) == 0 || strncmp(ns, "MiniGame", 8) == 0;
}
static BOOL tp_name_like_singleton(const char *cn)
{
    if (!cn) return NO;
    const char *keys[] = { "System","Game","Mgr","Manager","World","Ctl","Root","App","Service" };
    for (size_t i = 0; i < sizeof(keys)/sizeof(keys[0]); i++) if (strstr(cn, keys[i])) return YES;
    return NO;
}

static void *tp_discover_by_scan(void)
{
    static const char *getters[] = { "get_Instance","get_instance","get_Current","get_current",
                                     "get_Singleton","get_singleton","get_Game","get_game" };
    if (!p_domain_get || !p_object_get_class) return NULL;
    void *domain = p_domain_get(); if (!domain) return NULL;
    p_thread_attach(domain);
    size_t acount = 0;
    const void **asms = p_domain_get_assemblies(domain, &acount);
    int calls = 0;
    for (size_t i = 0; i < acount && calls < 200; i++) {
        const void *img = p_assembly_get_image(asms[i]);
        if (!img) continue;
        size_t cc = p_image_get_class_count(img);
        for (size_t k = 0; k < cc && calls < 200; k++) {
            void *klass = p_image_get_class(img, k);
            if (!klass) continue;
            const char *cn = p_class_get_name(klass);
            const char *ns = p_class_get_namespace(klass);
            if (!tp_is_goose_ns(ns) || !tp_name_like_singleton(cn)) continue;
            for (size_t g = 0; g < sizeof(getters)/sizeof(getters[0]); g++) {
                void *m = p_class_get_method_from_name(klass, getters[g], 0);
                if (!m) continue;
                calls++;
                void *obj = invoke_guarded(m, NULL, NULL);
                if (obj && p_object_get_class(obj) == s_ggKlass) {
                    KP(@"实例发现：%s.%s() 命中", ns ? ns : "", getters[g]);
                    return obj;
                }
            }
        }
    }
    KP(@"实例发现：扫描 %d 次未命中", calls);
    return NULL;
}

static void *tp_discover_by_unity(void)
{
    if (!p_type_get_object || !p_class_get_type) return NULL;
    void *objKlass = tp_find_class("UnityEngine", "Object");
    if (!objKlass) return NULL;
    void *m = tp_method_in_hierarchy(objKlass, "FindObjectOfType", 1);
    if (!m) m = tp_method_in_hierarchy(objKlass, "FindFirstObjectByType", 1);
    if (!m) m = tp_method_in_hierarchy(objKlass, "FindAnyObjectByType", 1);
    if (!m) { KP(@"实例发现：无 FindObjectOfType"); return NULL; }
    void *typeObj = p_type_get_object(p_class_get_type(s_ggKlass));
    if (!typeObj) return NULL;
    void *args[1] = { typeObj };
    void *r = invoke_guarded(m, NULL, args);
    if (r && p_object_get_class(r) == s_ggKlass) { KP(@"实例发现：FindObjectOfType 命中"); return r; }
    return NULL;
}

static void *tp_goosegame_instance(void)
{
    if (s_ggInstance) return s_ggInstance;
    if (!s_ggKlass) return NULL;
    s_ggInstance = tp_discover_by_scan();
    if (!s_ggInstance) s_ggInstance = tp_discover_by_unity();
    return s_ggInstance;
}

static void tp_dump_class_api(void *klass, const char *label, NSMutableString *out)
{
    if (!klass) return;
    const char *cn = p_class_get_name ? p_class_get_name(klass) : "?";
    const char *ns = p_class_get_namespace ? p_class_get_namespace(klass) : "";
    void *parent = p_class_get_parent ? p_class_get_parent(klass) : NULL;
    const char *pn = (parent && p_class_get_name) ? p_class_get_name(parent) : "";
    [out appendFormat:@"\n### %s  %s.%s  ::  %s\n", label, ns ? ns : "", cn, pn ? pn : ""];
    if (p_class_get_fields) {
        void *it = NULL;
        while (1) {
            void *f = p_class_get_fields(klass, &it);
            if (!f) break;
            const char *tn = "";
            if (p_field_get_type && p_type_get_name) { void *t = p_field_get_type(f); if (t) tn = p_type_get_name(t) ?: ""; }
            [out appendFormat:@"  F %s @0x%x : %s\n", p_field_get_name(f),
             p_field_get_offset ? p_field_get_offset(f) : -1, tn];
        }
    }
    if (p_class_get_methods) {
        void *it = NULL; int n = 0;
        while (n++ < 220) {
            void *m = p_class_get_methods(klass, &it);
            if (!m) break;
            const char *rt = "";
            if (p_method_get_return_type && p_type_get_name) { void *t = p_method_get_return_type(m); if (t) rt = p_type_get_name(t) ?: ""; }
            [out appendFormat:@"  M %s/%u -> %s\n", p_method_get_name ? p_method_get_name(m) : "?",
             p_method_get_param_count ? p_method_get_param_count(m) : 0, rt];
        }
    }
}

static void tp_dump_target_apis(void)
{
    NSMutableString *out = [NSMutableString stringWithString:@"# TiboPort target APIs (v10)\n"];
    void *cur = s_paKlass;
    for (int i = 0; i < 8 && cur; i++) { tp_dump_class_api(cur, "PlayerActor-chain", out); cur = p_class_get_parent ? p_class_get_parent(cur) : NULL; }
    cur = s_ggKlass;
    for (int i = 0; i < 4 && cur; i++) { tp_dump_class_api(cur, "GooseGame-chain", out); cur = p_class_get_parent ? p_class_get_parent(cur) : NULL; }
    write_file(gApiPath, out);
    KP(@"目标类 API 已写入 TiboPort-api.txt");
}

static void esp_init(void)
{
    if (s_ready) return;
    if (!resolve_il2cpp()) { gEspState = @"il2cpp 未就绪"; return; }

    s_ggKlass  = tp_find_class("Goose", "GooseGame");
    s_paKlass  = tp_find_class("Goose.Actors", "PlayerActor");
    s_camKlass = tp_find_class("UnityEngine", "Camera");

    if (s_ggKlass) {
        s_playersField = tp_field_by_name(s_ggKlass, "players");
        if (s_playersField && p_field_get_offset) s_playersOff = p_field_get_offset(s_playersField);
        s_getMainPlayer = tp_method_in_hierarchy(s_ggKlass, "get_player", 0);
    }
    if (s_paKlass) {
        s_getCenter   = tp_method_in_hierarchy(s_paKlass, "get_center", 0);
        s_getSize     = tp_method_in_hierarchy(s_paKlass, "get_size", 0);
        s_getName     = tp_method_in_hierarchy(s_paKlass, "get_name", 0);
        s_getUid      = tp_method_in_hierarchy(s_paKlass, "get_uid", 0);
        s_getStatus   = tp_method_in_hierarchy(s_paKlass, "get_status", 0);
        s_getShowID   = tp_method_in_hierarchy(s_paKlass, "get_ShowID", 0);
        s_getScreenPos = tp_method_in_hierarchy(s_paKlass, "GetScreenPosition", 1);
    }
    if (s_camKlass) {
        s_camMain = tp_method_in_hierarchy(s_camKlass, "get_main", 0);
        if (!s_camMain) s_camMain = tp_method_in_hierarchy(s_camKlass, "get_current", 0);
        s_w2s = tp_method_in_hierarchy(s_camKlass, "WorldToScreenPoint", 1);
    }

    NSMutableString *miss = [NSMutableString string];
    if (!s_ggKlass) [miss appendString:@"GG "];
    if (!s_playersField || s_playersOff < 0) [miss appendString:@"players "];
    if (!s_paKlass) [miss appendString:@"PA "];
    if (!s_getCenter) [miss appendString:@"center "];
    if (!s_camKlass) [miss appendString:@"camera "];
    if (!s_w2s) [miss appendString:@"w2s "];

    KP(@"ESP 句柄 GG=%p players=%p(off=%d) PA=%p center=%p size=%p name=%p uid=%p status=%p showID=%p cam=%p w2s=%p mp=%p",
       s_ggKlass, s_playersField, s_playersOff, s_paKlass,
       s_getCenter, s_getSize, s_getName, s_getUid, s_getStatus, s_getShowID,
       s_camKlass, s_w2s, s_getMainPlayer);
    KP(@"备用位置源 GetScreenPosition=%p", s_getScreenPos);

    @try { if (s_paKlass || s_ggKlass) tp_dump_target_apis(); } @catch (NSException *e) { }

    if (miss.length == 0) { s_ready = 1; gEspState = @"handles ok"; }
    else gEspState = [NSString stringWithFormat:@"缺:%@", miss];
}

- (void)refresh
{
    @try {
        if (!s_ready) { esp_init(); if (!s_ready) { [self clear]; return; } }

        void *gg = tp_goosegame_instance();
        if (!gg) { gEspState = @"无实例"; [self clear]; return; }

        void *dict = tp_field_ptr(gg, s_playersOff);
        if (!dict) { gEspState = @"players=null"; [self clear]; return; }
        if (!p_object_get_class || !p_object_unbox) { gEspState = @"缺unbox"; [self clear]; return; }

        void *dictClass = p_object_get_class(dict);
        void *vcM = dictClass ? p_class_get_method_from_name(dictClass, "get_Values", 0) : NULL;
        void *vc = vcM ? invoke_guarded(vcM, dict, NULL) : NULL;
        if (!vc) { gEspState = @"无Values"; [self clear]; return; }

        void *vcClass = p_object_get_class(vc);
        void *cntM = vcClass ? p_class_get_method_from_name(vcClass, "get_Count", 0) : NULL;
        void *cntObj = cntM ? invoke_guarded(cntM, vc, NULL) : NULL;
        if (!cntObj) { gEspState = @"无Count"; [self clear]; return; }
        int count = tp_int(cntObj);
        if (count <= 0 || count > 200) { gEspState = [NSString stringWithFormat:@"人数%d", count]; [self clear]; return; }

        void *arr = p_array_new ? p_array_new(s_paKlass, (size_t)count) : NULL;
        if (!arr) { gEspState = @"数组失败"; [self clear]; return; }
        void *copyM = p_class_get_method_from_name(vcClass, "CopyTo", 2);
        if (copyM) { int32_t zero = 0; void *args[2] = { arr, &zero }; invoke_guarded(copyM, vc, args); }

        void *cam = s_camMain ? invoke_guarded(s_camMain, NULL, NULL) : NULL;
        if (!cam) { gEspState = @"无相机"; [self clear]; return; }

        // 本地玩家 uid（用于标记自己）
        int64_t selfUid = 0;
        if (s_getMainPlayer && s_getUid) {
            void *mp = invoke_guarded(s_getMainPlayer, gg, NULL);
            if (mp) selfUid = tp_long(invoke_guarded(s_getUid, mp, NULL));
        }

        gPlayerCount = count;
        gEspState = [NSString stringWithFormat:@"OK%d", count];

        CGRect scr = gCanvasScreenBounds;
        NSMutableArray *out = [NSMutableArray array];

        // 位置/投影模式：可用 Documents/TiboPort.cfg 切换，不必重编
        //   pos=center|screen      位置来源（默认 center）
        //   proj=auto|w2s|raw      投影方式（默认 auto：自动选屏幕内占比高的那种）
        NSString *posMode = @"center";
        NSString *projMode = @"auto";
        {
            NSString *pm = [NSString stringWithContentsOfFile:gCfgPath encoding:NSUTF8StringEncoding error:nil];
            if (pm) {
                for (NSString *ln in [pm componentsSeparatedByString:@"\n"]) {
                    NSString *t = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if ([t hasPrefix:@"pos="])  posMode  = [t substringFromIndex:4];
                    if ([t hasPrefix:@"proj="]) projMode = [t substringFromIndex:5];
                }
            }
        }
        BOOL wantScreen = [posMode isEqualToString:@"screen"];

        static int sCalibrated = 0;   // 0未定 1用w2s 2用raw
        NSMutableArray *rawW2S = [NSMutableArray array];
        NSMutableArray *rawDirect = [NSMutableArray array];

        for (int i = 0; i < count && i < ESP_MAX_BOX; i++) {
            void *pa = *(void **)((char *)arr + IL2CPP_ARRAY_HDR + i * 8);
            if (!pa) continue;

            float c[3] = {0,0,0};
            float sz[3] = {1,1,1};
            BOOL haveWorld = NO;

            if (!wantScreen && s_getCenter) {
                haveWorld = tp_vec(invoke_guarded(s_getCenter, pa, NULL), c);
                if (s_getSize) tp_vec(invoke_guarded(s_getSize, pa, NULL), sz);
            }
            // 屏幕坐标（Spine 直接给屏幕点）
            float spDirect[3] = {0,0,0};
            BOOL haveDirect = NO;
            if (s_getScreenPos) {
                int32_t zero = 0;
                void *a1[1] = { &zero };
                float v2[3] = {0,0,0};
                if (tp_vec(invoke_guarded(s_getScreenPos, pa, a1), v2)) {
                    spDirect[0] = v2[0]; spDirect[1] = v2[1]; spDirect[2] = 1.0f;
                    haveDirect = YES;
                }
            }

            if (!haveWorld && !haveDirect) continue;

            // w2s 结果
            float spW[3] = {0,0,0};
            BOOL haveW = NO;
            if (haveWorld && s_w2s) {
                void *args[1] = { c };
                haveW = tp_vec(invoke_guarded(s_w2s, cam, args), spW);
            }

            NSString *nm = s_getName ? tp_str(invoke_guarded(s_getName, pa, NULL)) : nil;
            int64_t uid = s_getUid ? tp_long(invoke_guarded(s_getUid, pa, NULL)) : 0;
            int status = s_getStatus ? tp_int(invoke_guarded(s_getStatus, pa, NULL)) : 0;
            int seat = s_getShowID ? tp_int(invoke_guarded(s_getShowID, pa, NULL)) : 0;

            // 用 size 换算屏幕框高（仅世界坐标模式可用）
            CGFloat boxH = 70;
            if (haveW && s_w2s) {
                float top[3] = { c[0], c[1] + (sz[1] > 0.01f ? sz[1] * 0.5f : 0.5f), c[2] };
                void *a2[1] = { top };
                float tp3[3];
                if (tp_vec(invoke_guarded(s_w2s, cam, a2), tp3)) {
                    CGFloat d2 = fabs(tp3[1] - spW[1]) * 2.0;
                    if (d2 > 14 && d2 < 500) boxH = d2;
                }
            }

            NSDictionary *base = @{ @"name": (nm.length ? nm : [NSString stringWithFormat:@"#%d", seat]),
                                    @"seat": @(seat),
                                    @"self": @(uid != 0 && uid == selfUid),
                                    @"alive": @(status == 0 || status == 1),
                                    @"h": @(boxH),
                                    @"cx": @(c[0]), @"cy": @(c[1]), @"cz": @(c[2]),
                                    @"sy": @(sz[1]) };

            if (haveW) {
                if (spW[2] > 0.05f && spW[0] > -300 && spW[0] < scr.size.width + 300
                    && spW[1] > -300 && spW[1] < scr.size.height + 300)
                    [rawW2S addObject:@{@"pt": @[@(spW[0]), @(spW[1])], @"d": base}];
            }
            if (haveDirect) {
                if (spDirect[0] > -300 && spDirect[0] < scr.size.width + 300
                    && spDirect[1] > -300 && spDirect[1] < scr.size.height + 300)
                    [rawDirect addObject:@{@"pt": @[@(spDirect[0]), @(spDirect[1])], @"d": base}];
            }
        }

        // 自动校准：谁在屏幕内的点多就用谁
        if (sCalibrated == 0) {
            if (projMode.length && ![projMode isEqualToString:@"auto"]) {
                sCalibrated = [projMode isEqualToString:@"raw"] ? 2 : 1;
            } else if (rawW2S.count >= rawDirect.count && rawW2S.count > 0) {
                sCalibrated = 1;
            } else if (rawDirect.count > 0) {
                sCalibrated = 2;
            }
            if (sCalibrated) KP(@"投影校准：%s (w2s内=%lu direct内=%lu)",
                                sCalibrated == 1 ? "WorldToScreenPoint" : "屏幕坐标直用",
                                (unsigned long)rawW2S.count, (unsigned long)rawDirect.count);
        }

        NSArray *chosen = (sCalibrated == 2) ? rawDirect : rawW2S;
        for (NSDictionary *e in chosen) {
            NSArray *pt = e[@"pt"];
            NSMutableDictionary *d = [e[@"d"] mutableCopy];
            d[@"x"] = pt[0];
            d[@"y"] = pt[1];
            [out addObject:d];
        }
        if (out.count) gEspState = [NSString stringWithFormat:@"OK%d/画%lu", count, (unsigned long)out.count];

        if (out.count == 0) gEspState = [NSString stringWithFormat:@"OK%d/画0", count];
        dispatch_async(dispatch_get_main_queue(), ^{ [self draw:out]; });

    } @catch (NSException *e) { KP(@"ESP 异常 %@", e); }
}


- (void)clear
{
    if (_boxes.count == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIView *b in _boxes) b.hidden = YES;
        for (UILabel *l in _labels) l.hidden = YES;
    });
}

- (void)draw:(NSArray *)pts
{
    if (!_canvas.superview) return;
    _canvas.frame = _canvas.superview.bounds;
    NSUInteger n = MIN(pts.count, (NSUInteger)ESP_MAX_BOX);
    for (NSUInteger i = 0; i < _boxes.count; i++) {
        UIView *b = _boxes[i];
        UILabel *l = _labels[i];
        if (i >= n) { b.hidden = YES; l.hidden = YES; continue; }
        NSDictionary *d = pts[i];
        CGFloat x = [d[@"x"] doubleValue], y = [d[@"y"] doubleValue], h = [d[@"h"] doubleValue];
        BOOL isSelf = [d[@"self"] boolValue];
        BOOL alive  = [d[@"alive"] boolValue];
        CGFloat w = MAX(h * 0.45, 18);
        if (h < 12) h = 60;
        b.frame = CGRectMake(x - w/2, y - h, w, h);
        b.layer.borderColor = (isSelf ? [UIColor greenColor] :
                               (alive ? [UIColor redColor] : [UIColor grayColor])).CGColor;
        b.layer.borderWidth = isSelf ? 2.0 : 1.5;
        b.hidden = NO;

        l.text = [NSString stringWithFormat:@"%@%@", d[@"name"], isSelf ? @" (我)" : @""];
        l.textColor = isSelf ? [UIColor greenColor] : [UIColor whiteColor];
        l.frame = CGRectMake(x - 60, y - h - 13, 130, 12);
        l.hidden = NO;
    }
}


@end

// ------------------------------------------------------------ 类名表 / 地图 ---
static void write_file(NSString *path, NSString *content)
{
    @try { if (path) [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    @catch (NSException *e) { }
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
            if (isG || isM) { [buf appendFormat:@"%s|%s|%s\n", iname, ns ? ns : "", cn]; if (isG) goose++; else mini++; }
        }
    }
    write_file(gClassPath, buf);
    gAsmCount = (int)acount; gGooseCount = goose; gMiniCount = mini;
    KP(@"类名表：程序集=%zu Goose=%d MiniGame=%d", acount, goose, mini);
}

// 只 dump Goose*/MiniGame* 命名空间的类，且不设 4000 上限（避免被 mscorlib 的 Handle 类挤爆）
static void dump_detail(void *domain)
{
    if (!p_class_get_fields) return;
    size_t acount = 0;
    const void **asms = p_domain_get_assemblies(domain, &acount);
    NSMutableString *out = [NSMutableString stringWithString:@"# TiboPort map v7\n"];
    int hit = 0;
    for (size_t i = 0; i < acount; i++) {
        const void *img = p_assembly_get_image(asms[i]);
        if (!img) continue;
        const char *iname = p_image_get_name(img);
        size_t cc = p_image_get_class_count(img);
        if (!iname || cc == 0) continue;
        BOOL gameAsm = strstr(iname, "Goose") || strstr(iname, "MiniGame") ||
                       strstr(iname, "UGC") || strstr(iname, "Gameplay") || strstr(iname, "Common");
        if (!gameAsm) continue;
        for (size_t k = 0; k < cc; k++) {
            void *klass = p_image_get_class(img, k);
            if (!klass) continue;
            const char *cn = p_class_get_name(klass);
            if (!cn) continue;
            const char *ns = p_class_get_namespace(klass);
            BOOL want = (ns && (strncmp(ns, "Goose", 5) == 0 || strncmp(ns, "MiniGame", 8) == 0));
            if (!want) continue;
            hit++;
            void *parent = p_class_get_parent ? p_class_get_parent(klass) : NULL;
            const char *pn = (parent && p_class_get_name) ? p_class_get_name(parent) : "";
            [out appendFormat:@"\n[%s] %s.%s  ::  %s\n", iname, ns ? ns : "", cn, pn ? pn : ""];
            void *it = NULL;
            while (1) {
                void *f = p_class_get_fields(klass, &it);
                if (!f) break;
                const char *fn = p_field_get_name(f);
                int32_t off = p_field_get_offset ? p_field_get_offset(f) : -1;
                const char *tn = "";
                if (p_field_get_type && p_type_get_name) { void *t = p_field_get_type(f); if (t) { const char *nm = p_type_get_name(t); if (nm) tn = nm; } }
                [out appendFormat:@"  F %s @0x%x : %s\n", fn ? fn : "?", off, tn];
            }
            it = NULL; int mc = 0;
            while (mc < 60) {
                void *m = p_class_get_methods(klass, &it);
                if (!m) break;
                [out appendFormat:@"  M %s/%u\n", p_method_get_name ? p_method_get_name(m) : "?", p_method_get_param_count ? p_method_get_param_count(m) : 0];
                mc++;
            }
        }
    }
    [out appendFormat:@"\n# matched classes=%d\n", hit];
    write_file(gDumpPath, out);
    gLastDumpTime = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    KP(@"地图刷新：命中 %d 个 Goose/MiniGame 类", hit);
}

// ------------------------------------------------------------- 探测 -----------
static void probe_once(void)
{
    static int sQuiet = -1;
    if (!resolve_il2cpp()) { if (sQuiet != 0) { KP(@"il2cpp 未就绪"); sQuiet = 0; } gProbeState = 0; return; }
    void *domain = p_domain_get();
    if (!domain) { if (sQuiet != 1) { KP(@"domain=NULL"); sQuiet = 1; } gProbeState = 0; return; }
    sQuiet = 2;
    p_thread_attach(domain);
    KP(@"il2cpp 就绪");
    dump_classnames(domain);
    dump_detail(domain);
    gProbeState = 2;
}

static BOOL probe_guarded(void)
{
    if (sigsetjmp(gProbeJmp, 1) != 0) { gProbeGuard = 0; KP(@"探测被护栏拦下（未崩溃）"); return NO; }
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
            gApiPath   = [docs stringByAppendingPathComponent:@"TiboPort-api.txt"];
        }
    } @catch (NSException *e) { }

    tp_install_guard();
    KP(@"====== TiboPort v10 已加载 ======");
    KP(@"build %s %s", __DATE__, __TIME__);
    probe_keychain();

    BOOL hudOn = tp_cfg_bool(@"hud", YES);
    if (hudOn) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __block int tries = 0;
            NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
                if (++tries > 60) { [tm invalidate]; return; }
                install_hud();
                if (gHudHost) { [tm invalidate]; }
            }];
            (void)t;
        });
        NSTimer *u = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
            (void)tm;
            UIWindow *kw = tp_key_window();
            if (kw) gCanvasScreenBounds = kw.bounds;
            hud_text([NSString stringWithFormat:
                      @"TiboPort v10\nasm=%d goose=%d mini=%d\nplayers=%d esp=%@\nmap=%@",
                      gAsmCount, gGooseCount, gMiniCount, gPlayerCount, gEspState, gLastDumpTime]);
        }];
        (void)u;
    }

    // 视野
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *ft = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
            (void)tm;
            @try {
                double want = tp_cfg_double(@"fov", 0);
                if (want < 20 || want > 170) return;
                if (!p_runtime_invoke) return;
                static void *ck = NULL, *cm = NULL, *cs = NULL;
                if (!ck) {
                    ck = tp_find_class("UnityEngine", "Camera");
                    if (!ck) return;
                    cm = p_class_get_method_from_name(ck, "get_main", 0);
                    cs = p_class_get_method_from_name(ck, "set_fieldOfView", 1);
                }
                if (!cm || !cs) return;
                void *cam = invoke_guarded(cm, NULL, NULL);
                if (!cam) return;
                float f = (float)want; void *args[1] = { &f };
                invoke_guarded(cs, cam, args);
            } @catch (NSException *e) { }
        }];
        (void)ft;
    });

    // ESP：每 0.5 秒刷一次
    BOOL espOn = tp_cfg_bool(@"esp", YES);
    if (espOn) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimer *et = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *tm) {
                (void)tm;
                @try { [[ESP shared] refresh]; } @catch (NSException *e) { }
            }];
            (void)et;
        });
    }

    // 探测 + 周期重扫
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int waited = 0;
        while (waited < 120 && !tp_image_loaded("UnityFramework")) { sleep(1); waited++; }
        if (!tp_image_loaded("UnityFramework")) { KP(@"UnityFramework 未出现"); return; }
        sleep(6);
        for (int i = 0; i < 300 && gProbeState != 2; i++) { if (probe_guarded()) break; sleep(2); }
        if (gProbeState != 2) { KP(@"首轮探测未成功"); return; }
        for (int k = 0; k < 10; k++) { sleep(30); @try { probe_guarded(); } @catch (NSException *e) { } }
        KP(@"周期重扫结束");
    });
}
