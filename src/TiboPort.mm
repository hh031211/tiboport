// =============================================================================
//  TiboPort.mm  v16  —— 只做一件事：会议里显示每个人的真实职业
//
//  功能只有一个：
//      屏幕左上角常驻一份名单，按座位号排序
//          1号 小明 - 秃鹫
//          2号 小李 - 警长
//          3号 我  - 正义使者 (我)
//      死亡的玩家也照常显示，并标「已死」
//      拉铃/报告尸体进入会议时，这份名单同样在，直接对上号码牌
//
//  已删除：透视方框、自瞄、传送、视野调节、坐标投影、HUD 统计…全部不要
//
//  数据来源（全部本地内存，不联网、不连任何服务器）：
//      Goose.GooseGame.players  -> Dictionary<Int64, PlayerActor>
//      PlayerActor.get_ShowID   -> 座位号
//      PlayerActor.get_name     -> 昵称
//      PlayerActor.get_camp     -> 阵营
//      PlayerActor.get_status / get_IsNowDead -> 是否死亡
//      职业：baseData 链上模糊匹配 career/role/job 字段，或 get_career 之类方法
//
//  附带诊断：TiboPort-fields.txt（每 30 秒一版，导出现场整型字段值，
//  用来判断"职业是否真在本地"以及定位到底哪个字段是职业）
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
#include <stdint.h>
#include <setjmp.h>
#include <signal.h>
#include <pthread.h>
#include <os/log.h>

// ------------------------------------------------------------------ 日志 ------
static NSLock   *gLock = nil;
static NSString *gLogPath = nil, *gFieldsPath = nil, *gCfgPath = nil;
static volatile int gProbeState = 0;

static void KP(NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ [ID] %@",
                      [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle], body];
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "%{public}s", line.UTF8String ?: "");
    @try {
        [gLock lock];
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
        [gLock unlock];
    } @catch (NSException *e) { }
}

static void write_file(NSString *path, NSString *content)
{
    @try { if (path) [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    @catch (NSException *e) { }
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
typedef void*        (*fn_class_get_type)(void *k);
typedef void*        (*fn_type_get_object)(void *t);
typedef void*        (*fn_class_from_type)(void *t);
typedef uint32_t     (*fn_method_get_flags)(void *m, uint32_t *iflags);
typedef void*        (*fn_method_get_param)(void *m, uint32_t idx);
typedef void*        (*fn_string_new)(const char *s);
typedef void         (*fn_gchandle_cb)(void *target, void *ud);
typedef void         (*fn_gchandle_foreach)(fn_gchandle_cb cb, void *ud);
typedef void*        (*fn_field_get_value_object)(void *f, void *obj);

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
static fn_class_get_type        p_class_get_type;
static fn_type_get_object       p_type_get_object;
static fn_class_from_type       p_class_from_type;
static fn_method_get_flags      p_method_get_flags;
static fn_method_get_param      p_method_get_param;
static fn_string_new            p_string_new;
static fn_gchandle_foreach      p_gchandle_foreach;
static fn_field_get_value_object p_field_get_value_object;

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
    R("il2cpp_class_get_type", p_class_get_type);
    R("il2cpp_type_get_object", p_type_get_object);
    R("il2cpp_class_from_type", p_class_from_type);
    R("il2cpp_method_get_flags", p_method_get_flags);
    R("il2cpp_method_get_param", p_method_get_param);
    R("il2cpp_string_new", p_string_new);
    R("il2cpp_gchandle_foreach_get_target", p_gchandle_foreach);
    R("il2cpp_field_get_value_object", p_field_get_value_object);
    #undef R
    return p_domain_get && p_thread_attach && p_class_from_name && p_runtime_invoke && p_object_unbox;
}

// ---------------------------------------------------------------- 崩溃护栏 ----
static sigjmp_buf gProbeJmp;
static volatile sig_atomic_t gProbeGuard = 0;
static volatile uintptr_t gProbeThread = 0;
static sigjmp_buf gMainJmp;
static volatile sig_atomic_t gMainGuard = 0;
static volatile uintptr_t gMainThread = 0;

static void tp_signal_handler(int sig, siginfo_t *si, void *uc)
{
    if (gProbeGuard && (uintptr_t)pthread_self() == gProbeThread) { gProbeGuard = 0; siglongjmp(gProbeJmp, 1); }
    if (gMainGuard  && (uintptr_t)pthread_self() == gMainThread)  { gMainGuard  = 0; siglongjmp(gMainJmp, 1); }
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

// 受护栏保护的托管方法调用
static void *invoke_guarded(void *method, void *obj, void **args)
{
    if (!method || !p_runtime_invoke) return NULL;
    if (sigsetjmp(gMainJmp, 1) != 0) { gMainGuard = 0; KP(@"调用被护栏拦下（已跳过）"); return NULL; }
    gMainGuard = 1; gMainThread = (uintptr_t)pthread_self();
    void *exc = NULL;
    void *r = p_runtime_invoke(method, obj, args, &exc);
    gMainGuard = 0;
    if (exc) return NULL;
    return r;
}

// ------------------------------------------------------------------ 工具 ------
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

static void *tp_method_h(void *k, const char *name, int argc)
{
    void *cur = k;
    for (int i = 0; i < 12 && cur; i++) {
        void *m = p_class_get_method_from_name(cur, name, argc);
        if (m) return m;
        cur = p_class_get_parent ? p_class_get_parent(cur) : NULL;
    }
    return NULL;
}

static void *tp_field_h(void *k, const char *name)
{
    void *cur = k;
    for (int i = 0; i < 12 && cur; i++) {
        if (p_class_get_fields) {
            void *it = NULL;
            while (1) {
                void *f = p_class_get_fields(cur, &it);
                if (!f) break;
                const char *fn = p_field_get_name(f);
                if (fn && strcmp(fn, name) == 0) return f;
            }
        }
        cur = p_class_get_parent ? p_class_get_parent(cur) : NULL;
    }
    return NULL;
}

static void *tp_ptr(void *obj, int32_t off)
{
    if (!obj || off < 0) return NULL;
    return *(void **)((char *)obj + off);
}

static NSString *tp_str(void *s)
{
    if (!s) return nil;
    @try {
        int32_t len = *(int32_t *)((char *)s + 0x10);
        if (len <= 0 || len > 256) return nil;
        return [NSString stringWithCharacters:(const unichar *)((char *)s + 0x14) length:(NSUInteger)len];
    } @catch (NSException *e) { return nil; }
}

static int32_t tp_i32(void *boxed)
{
    if (!boxed || !p_object_unbox) return 0;
    int32_t *p = (int32_t *)p_object_unbox(boxed);
    return p ? *p : 0;
}
static int64_t tp_i64(void *boxed)
{
    if (!boxed || !p_object_unbox) return 0;
    int64_t *p = (int64_t *)p_object_unbox(boxed);
    return p ? *p : 0;
}


// 受护栏的裸内存读（后台线程上下文），野指针不至于带走游戏
static int32_t tp_read_i32(void *base, int32_t off)
{
    if (!base || off < 0) return -1;
    if (sigsetjmp(gProbeJmp, 1) != 0) { gProbeGuard = 0; return -1; }
    gProbeGuard = 1; gProbeThread = (uintptr_t)pthread_self();
    int32_t v = *(int32_t *)((char *)base + off);
    gProbeGuard = 0;
    return v;
}

// ---------------------------------------------------------------- 职业表 ------
// 顺序严格取自 Goose.CareerType 枚举（0= None ... 36= TutorialDuck）
static const char *kCareer[] = {
    "无", "鹅", "警长", "正义使者", "工程师", "侦探", "星行者", "观察者", "掘墓人", "复制鸭",
    "冒险家", "肉汁", "游说者", "探险家", "鸭", "专杀", "间谍", "掠夺者", "小丑", "投毒者",
    "连环杀手", "传教士", "嘟嘟鸟", "鸽子", "鹈鹕", "猎鹰", "秃鹫", "斗嘟嘟鸟", "杜鹃", "金鸡",
    "渡鸦", "喜鹊", "爷爷", "双面人", "监视者", "主城角色", "教学鸭"
};
static const int kCareerCount = 37;

static NSString *tp_career_name(int id)
{
    if (id <= 0) return nil;
    if (id >= kCareerCount) return [NSString stringWithFormat:@"职业%d", id];
    return [NSString stringWithUTF8String:kCareer[id]];
}

// ------------------------------------------------------------ 运行时句柄 ------
static void *s_ggKlass = NULL;
static void *s_paKlass = NULL;
static void *s_playersField = NULL;
static int32_t s_playersOff = -1;
static void *s_bdField = NULL;
static int32_t s_bdOff = -1;
static void *s_bdKlass = NULL;
static void *s_careerField = NULL;
static int32_t s_careerOff = -1;
static void *s_careerM = NULL;

static void *s_getName = NULL, *s_getSeat = NULL, *s_getCamp = NULL;
static void *s_getStatus = NULL, *s_getDead = NULL, *s_getUid = NULL;
static void *s_getMainPlayer = NULL;
static int   s_ready = 0;

static void *s_ggInstance = NULL;
static char  s_how[32] = "none";
static NSString *tp_how(void) { return [NSString stringWithUTF8String:s_how]; }

// ------------------------------------------------------------ 实例获取 --------
typedef struct { void *want; void *found; int seen, cap; } ScanCtx;

static void scan_cb(void *target, void *ud)
{
    ScanCtx *c = (ScanCtx *)ud;
    if (!c || c->found) return;
    c->seen++;
    if (!target || c->seen > c->cap) return;
    if (p_object_get_class && p_object_get_class(target) == c->want) c->found = target;
}

static void *tp_gc_scan(void *klass, int cap)
{
    if (!p_gchandle_foreach || !p_object_get_class || !klass) return NULL;
    ScanCtx c; c.want = klass; c.found = NULL; c.seen = 0; c.cap = cap;
    p_gchandle_foreach(scan_cb, &c);
    KP(@"GC 扫描：%d 个句柄，%s", c.seen, c.found ? @"命中" : @"未命中");
    return c.found;
}

static void *tp_by_getsingle(void)
{
    void *io = tp_find_class("ZF.Core.Instancing", "InstanceObject");
    if (!io || !p_method_get_flags || !p_method_get_param || !p_type_get_name) return NULL;
    void *m = tp_method_h(io, "GetSingle", 1);
    if (!m) return NULL;
    uint32_t fl = p_method_get_flags(m, NULL);
    if (!(fl & 0x0010)) { KP(@"GetSingle 非 static，跳过"); return NULL; }
    void *pt = p_method_get_param(m, 0);
    const char *tn = pt ? p_type_get_name(pt) : NULL;
    void *args[1];
    if (tn && strcmp(tn, "System.Type") == 0) {
        args[0] = p_type_get_object(p_class_get_type(s_ggKlass));
    } else if (tn && strcmp(tn, "System.String") == 0) {
        args[0] = p_string_new ? p_string_new("Goose.GooseGame") : NULL;
    } else {
        KP(@"GetSingle 参数类型未知(%s)，跳过", tn ? tn : "?");
        return NULL;
    }
    if (!args[0]) return NULL;
    void *o = invoke_guarded(m, NULL, args);
    if (o && p_object_get_class(o) == s_ggKlass) { KP(@"GetSingle 命中"); return o; }
    return NULL;
}

static void *tp_by_static(void)
{
    if (!p_class_get_fields || !p_field_get_type || !p_type_get_name || !p_field_get_value_object) return NULL;
    void *it = NULL; int n = 0;
    while (n++ < 400) {
        void *f = p_class_get_fields(s_ggKlass, &it);
        if (!f) break;
        void *ft = p_field_get_type(f);
        const char *tn = ft ? p_type_get_name(ft) : NULL;
        if (!tn) continue;
        if (!(strcmp(tn, "Goose.GooseGame") == 0 || strstr(tn, "GameSystem") || strstr(tn, "InstanceObject"))) continue;
        if (sigsetjmp(gMainJmp, 1) != 0) { gMainGuard = 0; return NULL; }
        gMainGuard = 1; gMainThread = (uintptr_t)pthread_self();
        void *v = p_field_get_value_object(f, NULL);
        gMainGuard = 0;
        if (v && p_object_get_class(v) == s_ggKlass) { KP(@"静态字段 %s 命中", p_field_get_name(f)); return v; }
    }
    return NULL;
}

static void *tp_instance(void)
{
    if (s_ggInstance) return s_ggInstance;
    if (!s_ggKlass) return NULL;
    s_ggInstance = tp_by_getsingle();  if (s_ggInstance) { strcpy(s_how, "GetSingle"); return s_ggInstance; }
    s_ggInstance = tp_gc_scan(s_ggKlass, 80000); if (s_ggInstance) { strcpy(s_how, "GCScan"); return s_ggInstance; }
    s_ggInstance = tp_by_static();     if (s_ggInstance) { strcpy(s_how, "Static"); return s_ggInstance; }
    return NULL;
}

// ------------------------------------------------------------ 职业字段定位 ----
static BOOL tp_name_like_career(const char *fn)
{
    if (!fn) return NO;
    return strcasestr(fn, "career") || strcasestr(fn, "roleid") || strcasestr(fn, "jobid") ||
           strcasestr(fn, "vocation") || strcasestr(fn, "identity") ||
           strcmp(fn, "role") == 0 || strcmp(fn, "job") == 0;
}

static void tp_locate_career(void)
{
    if (!s_paKlass) return;

    // 1) 方法式：get_career / get_roleId / get_Career …
    const char *mnames[] = { "get_career","get_Career","get_careerId","get_CareerId",
                             "get_roleId","get_RoleId","get_role","get_Role",
                             "GetCareer","GetCareerId","GetRole" };
    for (size_t i = 0; i < sizeof(mnames)/sizeof(mnames[0]); i++) {
        void *m = tp_method_h(s_paKlass, mnames[i], 0);
        if (m) { s_careerM = m; KP(@"职业方法命中：%s", mnames[i]); break; }
    }

    // 2) 字段式：先找 baseData，再在它的类上找
    s_bdField = tp_field_h(s_paKlass, "baseData");
    if (s_bdField && p_field_get_offset) s_bdOff = p_field_get_offset(s_bdField);
    if (s_bdField && p_field_get_type && p_class_from_type) {
        s_bdKlass = p_class_from_type(p_field_get_type(s_bdField));
    }
    if (!s_bdKlass && s_paKlass) s_bdKlass = s_paKlass;   // 退化为直接在 actor 上找

    if (s_bdKlass && p_class_get_fields) {
        void *it = NULL; int n = 0;
        while (n++ < 400) {
            void *f = p_class_get_fields(s_bdKlass, &it);
            if (!f) break;
            const char *fn = p_field_get_name(f);
            if (!tp_name_like_career(fn)) continue;
            void *ft = p_field_get_type(f);
            const char *tn = ft ? p_type_get_name(ft) : NULL;
            if (!tn) continue;
            if (strcmp(tn, "System.Int32") != 0 && strstr(tn, "CareerType") == NULL) continue;
            int32_t off = p_field_get_offset(f);
            if (off < 0) continue;
            s_careerField = f; s_careerOff = off;
            KP(@"职业字段命中：%s @0x%x (%s)", fn, off, tn);
            break;
        }
    }
    if (!s_careerField) KP(@"职业字段未命中（将依赖快照定位）");
}

// ------------------------------------------------------------ 球员列表 --------
static NSArray *tp_collect_players(int *outCount)
{
    if (outCount) *outCount = 0;
    void *gg = tp_instance();
    if (!gg) { KP(@"无 GooseGame 实例"); return nil; }

    void *dict = tp_ptr(gg, s_playersOff);
    if (!dict) { s_ggInstance = NULL; KP(@"players 为空（已重置实例）"); return nil; }

    if (!p_object_get_class) return nil;
    void *dc = p_object_get_class(dict);
    void *vm = dc ? p_class_get_method_from_name(dc, "get_Values", 0) : NULL;
    void *vc = vm ? invoke_guarded(vm, dict, NULL) : NULL;
    if (!vc) { KP(@"取 Values 失败"); return nil; }

    void *vcc = p_object_get_class(vc);
    void *cm = vcc ? p_class_get_method_from_name(vcc, "get_Count", 0) : NULL;
    void *co = cm ? invoke_guarded(cm, vc, NULL) : NULL;
    if (!co) { KP(@"取 Count 失败"); return nil; }
    int count = tp_i32(co);
    if (count <= 0 || count > 200) { KP(@"人数异常 %d", count); return nil; }

    void *arr = p_array_new ? p_array_new(s_paKlass, (size_t)count) : NULL;
    if (!arr) return nil;
    void *cp = p_class_get_method_from_name(vcc, "CopyTo", 2);
    if (cp) { int32_t z = 0; void *a[2] = { arr, &z }; invoke_guarded(cp, vc, a); }

    NSMutableArray *list = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        void *pa = *(void **)((char *)arr + 0x20 + i * 8);
        if (pa) [list addObject:[NSValue valueWithPointer:pa]];
    }
    if (outCount) *outCount = (int)list.count;
    return list;
}

// 读一个玩家的职业 id
static int tp_career_of(void *pa)
{
    if (!pa) return -1;
    if (s_careerM) {
        int v = tp_i32(invoke_guarded(s_careerM, pa, NULL));
        if (v > 0) return v;
    }
    if (s_careerOff >= 0) {
        void *bd = (s_bdOff >= 0) ? tp_ptr(pa, s_bdOff) : pa;
        if (bd) {
            int v = tp_read_i32(bd, s_careerOff);
            if (v > 0 && v < 64) return v;
        }
    }
    return -1;
}

// ------------------------------------------------------------ 字段快照 --------
static NSString *gFieldsOut = nil;
static int gSnapCount = 0;

static void tp_snapshot(void *pa, NSMutableString *out, int idx)
{
    if (!pa || !p_class_get_fields || !p_field_get_offset) return;
    [out appendFormat:@"\n--- player[%d] ---\n", idx];
    void *cur = p_object_get_class ? p_object_get_class(pa) : NULL;
    for (int d = 0; d < 8 && cur; d++) {
        const char *cn = p_class_get_name ? p_class_get_name(cur) : "?";
        [out appendFormat:@" [%s]\n", cn ? cn : "?"];
        void *it = NULL; int n = 0;
        while (n++ < 400) {
            void *f = p_class_get_fields(cur, &it);
            if (!f) break;
            const char *fn = p_field_get_name(f);
            void *ft = p_field_get_type(f);
            const char *tn = (ft && p_type_get_name) ? p_type_get_name(ft) : NULL;
            if (!fn || !tn) continue;
            int32_t off = p_field_get_offset(f);
            if (off < 0 || off > 0x8000) continue;
            if (strcmp(tn, "System.Int32") == 0 || strcmp(tn, "System.Int16") == 0 ||
                strcmp(tn, "System.Byte") == 0 || strstr(tn, "CareerType") ||
                strstr(tn, "CampType") || strstr(tn, "RoleStatus")) {
                int32_t v = tp_read_i32(pa, off);
                if (v < 0) continue;
                [out appendFormat:@"   %s @0x%x = %d\n", fn, off, v];
            }
        }
        cur = p_class_get_parent ? p_class_get_parent(cur) : NULL;
    }
}

// ------------------------------------------------------------------ 面板 ------
static UIView  *gHost = nil;
static UILabel *gTitle = nil;
static UILabel *gList = nil;
static BOOL     gEnabled = YES;

static UIWindow *tp_key_window(void)
{
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static void tp_install_panel(void)
{
    if (gHost) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gHost) return;
        UIWindow *kw = tp_key_window();
        if (!kw) return;
        gHost = [[UIView alloc] initWithFrame:kw.bounds];
        gHost.userInteractionEnabled = NO;          // 只读层，绝不会挡触摸
        gHost.backgroundColor = [UIColor clearColor];
        gHost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        gTitle = [[UILabel alloc] initWithFrame:CGRectMake(8, 52, 210, 18)];
        gTitle.font = [UIFont boldSystemFontOfSize:12];
        gTitle.textColor = [UIColor whiteColor];
        gTitle.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        gTitle.text = @"身份";
        [gHost addSubview:gTitle];

        gList = [[UILabel alloc] initWithFrame:CGRectMake(8, 70, 260, 420)];
        gList.numberOfLines = 0;
        gList.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
        gList.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        gList.layer.cornerRadius = 6;
        gList.clipsToBounds = YES;
        [gHost addSubview:gList];

        [kw addSubview:gHost];
    });
}

static void tp_render(NSArray *rows)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gList) return;
        if (!gEnabled) { gList.attributedText = nil; gList.text = @""; return; }
        NSMutableAttributedString *out = [NSMutableAttributedString new];
        UIFont *f = gList.font;
        for (NSDictionary *r in rows) {
            int camp = [r[@"camp"] intValue];
            int car  = [r[@"career"] intValue];
            BOOL dead = [r[@"dead"] boolValue];
            BOOL me = [r[@"self"] boolValue];
            UIColor *c = me ? [UIColor greenColor]
                        : dead ? [UIColor grayColor]
                        : (camp == 2) ? [UIColor redColor]
                        : (camp == 1) ? [UIColor cyanColor]
                        : (camp >= 3) ? [UIColor yellowColor]
                        : [UIColor whiteColor];
            NSString *cn = tp_career_name(car);
            NSString *line = [NSString stringWithFormat:@"%@号 %@ - %@%@%@\n",
                              r[@"seat"], r[@"name"],
                              cn ?: @"?",
                              dead ? @" [已死]" : @"",
                              me ? @" (我)" : @""];
            [out appendAttributedString:[[NSAttributedString alloc]
                initWithString:line
                    attributes:@{ NSForegroundColorAttributeName: c, NSFontAttributeName: f }]];
        }
        if (out.length == 0)
            [out appendAttributedString:[[NSAttributedString alloc]
                initWithString:@"(对局中才有数据)" attributes:@{ NSForegroundColorAttributeName: [UIColor lightGrayColor], NSFontAttributeName: f }]];
        gList.attributedText = out;
    });
}

// ------------------------------------------------------------ 主循环 ----------
static void tp_tick(void)
{
    @try {
        if (!s_ready) {
            if (!resolve_il2cpp()) return;
            s_ggKlass = tp_find_class("Goose", "GooseGame");
            s_paKlass = tp_find_class("Goose.Actors", "PlayerActor");
            if (s_ggKlass) {
                s_playersField = tp_field_h(s_ggKlass, "players");
                if (s_playersField && p_field_get_offset) s_playersOff = p_field_get_offset(s_playersField);
                s_getMainPlayer = tp_method_h(s_ggKlass, "get_player", 0);
            }
            if (s_paKlass) {
                s_getName   = tp_method_h(s_paKlass, "get_name", 0);
                s_getSeat   = tp_method_h(s_paKlass, "get_ShowID", 0);
                s_getCamp   = tp_method_h(s_paKlass, "get_camp", 0);
                s_getStatus = tp_method_h(s_paKlass, "get_status", 0);
                s_getDead   = tp_method_h(s_paKlass, "get_IsNowDead", 0);
                s_getUid    = tp_method_h(s_paKlass, "get_uid", 0);
                tp_locate_career();
            }
            KP(@"初始化 GG=%p PA=%p players=%p(off=%d) name=%p seat=%p camp=%p careerM=%p careerOff=%d",
               s_ggKlass, s_paKlass, s_playersField, s_playersOff,
               s_getName, s_getSeat, s_getCamp, s_careerM, s_careerOff);
            if (s_ggKlass && s_paKlass && s_playersOff >= 0) s_ready = 1;
            else return;
        }

        int count = 0;
        NSArray *players = tp_collect_players(&count);
        if (!players.count) { tp_render(@[]); return; }

        int64_t selfUid = 0;
        void *selfActor = NULL;
        if (s_getMainPlayer) {
            selfActor = invoke_guarded(s_getMainPlayer, tp_instance(), NULL);
            if (selfActor && s_getUid) selfUid = tp_i64(invoke_guarded(s_getUid, selfActor, NULL));
        }

        NSMutableArray *rows = [NSMutableArray array];
        for (NSValue *v in players) {
            void *pa = v.pointerValue;
            if (!pa) continue;
            int seat = s_getSeat ? tp_i32(invoke_guarded(s_getSeat, pa, NULL)) : 0;
            NSString *nm = s_getName ? tp_str(invoke_guarded(s_getName, pa, NULL)) : nil;
            int camp = s_getCamp ? tp_i32(invoke_guarded(s_getCamp, pa, NULL)) : 0;
            int st = s_getStatus ? tp_i32(invoke_guarded(s_getStatus, pa, NULL)) : 0;
            BOOL dead = s_getDead ? (tp_i32(invoke_guarded(s_getDead, pa, NULL)) != 0) : !(st == 0 || st == 1);
            int64_t uid = s_getUid ? tp_i64(invoke_guarded(s_getUid, pa, NULL)) : 0;
            BOOL me = (pa == selfActor) || (uid != 0 && uid == selfUid);

            [rows addObject:@{ @"seat": @(seat),
                               @"name": (nm.length ? nm : @"?"),
                               @"camp": @(camp),
                               @"career": @(tp_career_of(pa)),
                               @"dead": @(dead),
                               @"self": @(me) }];
        }
        [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"seat"] compare:b[@"seat"]];
        }];

        // 字段快照（前 3 人，每 30 秒一版，最多 40 版）
        if (gFieldsPath && gSnapCount < 40) {
            static time_t last = 0;
            time_t now = time(NULL);
            if (now - last >= 30) {
                last = now; gSnapCount++;
                NSMutableString *fo = [NSMutableString stringWithFormat:@"# snapshot %d\n", gSnapCount];
                for (NSUInteger i = 0; i < players.count && i < 3; i++)
                    tp_snapshot(((NSValue *)players[i]).pointerValue, fo, (int)i);
                if (s_bdKlass) {
                    [fo appendString:@"\n=== baseData class ===\n"];
                    void *it = NULL; int n = 0;
                    while (n++ < 400) {
                        void *f = p_class_get_fields(s_bdKlass, &it);
                        if (!f) break;
                        void *ft = p_field_get_type(f);
                        const char *tn = (ft && p_type_get_name) ? p_type_get_name(ft) : "";
                        [fo appendFormat:@"   %s @0x%x : %s\n",
                         p_field_get_name(f), p_field_get_offset(f), tn ? tn : ""];
                    }
                }
                write_file(gFieldsPath, fo);
            }
        }

        tp_render(rows);
        gProbeState = 2;
    } @catch (NSException *e) { KP(@"tick 异常 %@", e); }
}

// ------------------------------------------------------------ 引导 ------------
__attribute__((constructor))
static void tibo_init(void)
{
    gLock = [NSLock new];

    @try {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs) docs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
        if (docs) {
            gLogPath    = [docs stringByAppendingPathComponent:@"TiboPort.log"];
            gFieldsPath = [docs stringByAppendingPathComponent:@"TiboPort-fields.txt"];
            gCfgPath    = [docs stringByAppendingPathComponent:@"TiboPort.cfg"];
        }
    } @catch (NSException *e) { }

    tp_install_guard();
    gEnabled = tp_cfg_bool(@"ids", YES);
    KP(@"====== 身份版 已加载 (ids=%d) ======", (int)gEnabled);
    KP(@"build %s %s", __DATE__, __TIME__);

    // 面板（只读层）
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int tries = 0;
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
            if (++tries > 60) { [tm invalidate]; return; }
            tp_install_panel();
            if (gHost) [tm invalidate];
        }];
        (void)t;
    });

    // 后台等 Unity 起来，然后每 0.7 秒刷新一次名单
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int w = 0;
        while (w < 180 && !tp_image_loaded("UnityFramework")) { sleep(1); w++; }
        if (!tp_image_loaded("UnityFramework")) { KP(@"UnityFramework 未出现"); return; }
        sleep(6);
        KP(@"开始读取身份");
        while (1) {
            @try { tp_tick(); } @catch (NSException *e) { KP(@"循环异常 %@", e); }
            sleep(1);
        }
    });
}
