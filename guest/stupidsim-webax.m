// stupidsim-webax: loaded into WebKit's WebContent processes inside an x86Sim device, it answers `ui-tree`
// with the accessibility elements of the web pages they draw, which neither AXRuntime nor Xcode's
// AXPTranslator lists (both stop at the web view: checked with Safari on example.com on Xcode 27's
// iOS 27.0 simulator, and with stupidsim-guest under x86Sim 0.5.0, iOS 27.2).
//
// The approach is agent-sim's (https://github.com/Developing-Gamer/agent-sim, hooks/ax.c, Apache-2.0):
// WebKit makes one WKAccessibilityWebPageObject per page and there is no way to find them afterwards,
// so its init and dealloc are swapped to keep a list; a page's elements are the leaves of a
// UIAccessibility walk from its accessibilityRootObjectWrapper, already in screen points.
//
// Which app a page belongs to: its _accessibilityHostPid, the pid of the app whose web view hosts it
// (the page's accessibility container is an AXRemoteElement naming the same pid). It is the pid the
// app sees itself as, which is what stupidsim-guest reports for the app in front.
//
// Protocol, in the device's data/tmp/stupidsim-web (the guest's $HOME/tmp):
//   pages-<pid>     the host app pid of each page this process holds, one per line, kept current by a
//                   thread here once a second. The host asks only processes with a page of the app in
//                   front: a process whose app is in the background may be suspended and never answer.
//   req-<pid>       written by the host to ask; the same thread looks for it every 100 ms (an idle WebContent
//                   process was slow to run work queued for its main thread, per agent-sim), takes it and
//                   runs the walk on the main run loop.
//   web-<pid>.json  the answer, renamed into place whole: {"pid", "request", "pages": [{"host", "elements"}]},
//                   each element in the shape stupidsim-guest's tree uses; "request" echoes req-<pid>.
//
// x86Sim loads it through its per-program environment file (stupidsim-linux writes the line for
// com.apple.WebKit.WebContent). Inert in any other process.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <sys/stat.h>
#import <unistd.h>

#define MAXPAGES 64
static __unsafe_unretained id pages[MAXPAGES];  // page objects live as long as their page; dealloc removes them
static __unsafe_unretained id warm[MAXPAGES];   // pages walked before, whose frames are settled
static IMP originalInit, originalDealloc;
static NSString *directory;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static void writeAtomically(NSData *data, NSString *name) {
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSString *temporary = [path stringByAppendingString:@".tmp"];
    if ([data writeToFile:temporary atomically:NO]) rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation);
}

static id pageInit(id self, SEL selector) {
    id page = ((id (*)(id, SEL))originalInit)(self, selector);
    if (page) {
        pthread_mutex_lock(&lock);
        for (int i = 0; i < MAXPAGES; i++) if (!pages[i]) { pages[i] = page; break; }
        pthread_mutex_unlock(&lock);
    }
    return page;
}

static void pageDealloc(id self, SEL selector) {
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAXPAGES; i++) {
        if (pages[i] == self) pages[i] = nil;
        if (warm[i] == self) warm[i] = nil;
    }
    pthread_mutex_unlock(&lock);
    ((void (*)(id, SEL))originalDealloc)(self, selector);
}

// Strong copies, so a page that goes away during a walk stays valid until the walk ends.
static void snapshotPages(__strong id snapshot[MAXPAGES]) {
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAXPAGES; i++) snapshot[i] = pages[i];
    pthread_mutex_unlock(&lock);
}

static int hostPid(id page) {
    SEL s = sel_registerName("_accessibilityHostPid");
    return [page respondsToSelector:s] ? ((int (*)(id, SEL))objc_msgSend)(page, s) : 0;
}

static NSString *text(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:NSString.class]) return [value length] ? value : nil;
    if ([value isKindOfClass:NSAttributedString.class]) return [[value string] length] ? [value string] : nil;
    return nil;
}

static id ask(id object, const char *selector) {
    SEL s = sel_registerName(selector);
    return [object respondsToSelector:s] ? ((id (*)(id, SEL))objc_msgSend)(object, s) : nil;
}

static NSArray *rect(CGRect r) {
    return @[@[@(r.origin.x), @(r.origin.y)], @[@(r.size.width), @(r.size.height)]];
}

// The roles stupidsim-guest gives the same traits (its addRole), so web elements print like native ones.
static void addRole(unsigned long long traits, NSMutableDictionary *into) {
    NSString *role = @"AXGenericElement", *description = @"";
    if (traits & (1ull << 10) || traits & (1ull << 18)) { role = @"AXTextField"; description = @"text field"; }
    else if (traits & (1ull << 0)) { role = @"AXButton"; description = @"button"; }
    else if (traits & (1ull << 1)) { role = @"AXLink"; description = @"link"; }
    else if (traits & (1ull << 12)) { role = @"AXSlider"; description = @"slider"; }
    else if (traits & (1ull << 16)) { role = @"AXHeading"; description = @"heading"; }
    else if (traits & (1ull << 2)) { role = @"AXImage"; description = @"image"; }
    else if (traits & (1ull << 6)) { role = @"AXStaticText"; description = @"text"; }
    into[@"role"] = role;
    into[@"roleDescription"] = description;
}

static void emit(id element, NSMutableArray *out) {
    SEL frameSelector = sel_registerName("accessibilityFrame");
    if (![element respondsToSelector:frameSelector]) return;
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(element, frameSelector);
    if (frame.size.width <= 0 || frame.size.height <= 0) return;
    NSString *label = text(ask(element, "accessibilityLabel")), *value = text(ask(element, "accessibilityValue"));
    NSString *identifier = text(ask(element, "accessibilityIdentifier"));
    SEL traitsSelector = sel_registerName("accessibilityTraits");
    unsigned long long traits = [element respondsToSelector:traitsSelector]
        ? ((unsigned long long (*)(id, SEL))objc_msgSend)(element, traitsSelector) : 0;
    // Nothing to read and nothing to act on: layout, not an element (as agent-sim leaves them out).
    if (!label && !value && !identifier && !(traits & ((1ull << 0) | (1ull << 1) | (1ull << 10) | (1ull << 18)))) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"frame"] = rect(frame);
    if (label) d[@"label"] = label;
    if (value) d[@"value"] = value;
    if (identifier) d[@"identifier"] = identifier;
    addRole(traits, d);
    d[@"traits"] = @(traits);
    d[@"children"] = @[];
    [out addObject:d];
}

static void walk(id object, int depth, NSMutableArray *out) {
    if (!object || depth > 60 || out.count > 2000) return;
    SEL hidden = sel_registerName("accessibilityElementsHidden");
    if ([object respondsToSelector:hidden] && ((BOOL (*)(id, SEL))objc_msgSend)(object, hidden)) return;
    SEL isElement = sel_registerName("isAccessibilityElement");
    if ([object respondsToSelector:isElement] && ((BOOL (*)(id, SEL))objc_msgSend)(object, isElement)) {
        emit(object, out);
        return;
    }
    NSArray *children = ask(object, "accessibilityElements");
    if ([children isKindOfClass:NSArray.class] && children.count) {
        for (id child in children) walk(child, depth + 1, out);
        return;
    }
    SEL countSelector = sel_registerName("accessibilityElementCount");
    long count = [object respondsToSelector:countSelector] ? ((long (*)(id, SEL))objc_msgSend)(object, countSelector) : 0;
    SEL atIndex = sel_registerName("accessibilityElementAtIndex:");
    for (long i = 0; i < count && i < 100000; i++) {
        walk(((id (*)(id, SEL, long))objc_msgSend)(object, atIndex, i), depth + 1, out);
    }
}

static void answer(NSString *request) {
    id snapshot[MAXPAGES];
    snapshotPages(snapshot);
    NSMutableArray *reply = [NSMutableArray array];
    for (int i = 0; i < MAXPAGES; i++) {
        if (!snapshot[i]) continue;
        NSMutableArray *elements = [NSMutableArray array];
        walk(ask(snapshot[i], "accessibilityRootObjectWrapper"), 0, elements);
        [reply addObject:@{@"host": @(hostPid(snapshot[i])), @"elements": elements}];
    }
    NSDictionary *json = @{@"pid": @(getpid()), @"request": request ?: @"", @"pages": reply};
    writeAtomically([NSJSONSerialization dataWithJSONObject:json options:0 error:nil],
                    [NSString stringWithFormat:@"web-%d.json", getpid()]);
}

// The first walk of a page makes WebKit build its tree, and its frames lack the web view's position
// until the app side has answered, so a page seen for the first time is walked, then answered for
// half a second later (agent-sim's finding).
static void handle(NSString *request) {
    id snapshot[MAXPAGES];
    snapshotPages(snapshot);
    BOOL cold = NO;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAXPAGES; i++) {
        if (!snapshot[i]) continue;
        BOOL known = NO;
        for (int k = 0; k < MAXPAGES; k++) known |= warm[k] == snapshot[i];
        if (!known) {
            cold = YES;
            for (int k = 0; k < MAXPAGES; k++) if (!warm[k]) { warm[k] = snapshot[i]; break; }
        }
    }
    pthread_mutex_unlock(&lock);
    if (!cold) { answer(request); return; }
    for (int i = 0; i < MAXPAGES; i++) {
        if (snapshot[i]) walk(ask(snapshot[i], "accessibilityRootObjectWrapper"), 0, [NSMutableArray array]);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ answer(request); });
}

static void *watch(void *unused) {
    NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"req-%d", getpid()]];
    NSString *pagesName = [NSString stringWithFormat:@"pages-%d", getpid()];
    NSString *published = nil;
    for (unsigned tick = 0;; tick++) {
        usleep(100000);
        @autoreleasepool {
            if (tick % 10 == 0) {
                id snapshot[MAXPAGES];
                snapshotPages(snapshot);
                NSMutableString *hosts = [NSMutableString string];
                for (int i = 0; i < MAXPAGES; i++) if (snapshot[i]) [hosts appendFormat:@"%d\n", hostPid(snapshot[i])];
                if (!published || ![hosts isEqualToString:published]) {
                    writeAtomically([hosts dataUsingEncoding:NSUTF8StringEncoding], pagesName);
                    published = [hosts copy];
                }
            }
            NSString *request = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (!request) continue;
            unlink(path.fileSystemRepresentation);
            CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ handle(request); });
            CFRunLoopWakeUp(CFRunLoopGetMain());
        }
    }
    return NULL;
}

static void imageAdded(const struct mach_header *header, intptr_t slide) {
    static BOOL started;
    if (started) return;
    Class page = objc_getClass("WKAccessibilityWebPageObject");
    Method init = page ? class_getInstanceMethod(page, sel_registerName("init")) : NULL;
    Method dealloc = page ? class_getInstanceMethod(page, sel_registerName("dealloc")) : NULL;
    if (!init || !dealloc) return;
    started = YES;
    originalInit = method_setImplementation(init, (IMP)pageInit);
    originalDealloc = method_setImplementation(dealloc, (IMP)pageDealloc);
    const char *home = getenv("CFFIXED_USER_HOME");
    if (!home || !*home) home = getenv("HOME");
    if (!home) return;
    NSString *base = @(home);
    NSRange containers = [base rangeOfString:@"/Containers/"];  // a container's home is below the device's data
    if (containers.location != NSNotFound) base = [base substringToIndex:containers.location];
    directory = [base stringByAppendingPathComponent:@"tmp/stupidsim-web"];
    mkdir(directory.fileSystemRepresentation, 0755);
    pthread_t thread;
    if (pthread_create(&thread, NULL, watch, NULL) == 0) pthread_detach(thread);
}

__attribute__((constructor)) static void load(void) {
    if (!strstr(getprogname(), "WebContent")) return;
    _dyld_register_func_for_add_image(imageAdded);
}
