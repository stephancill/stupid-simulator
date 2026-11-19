// stupidsim-guest: runs inside a simulator and answers what the host cannot read from outside it.
//
// On a Mac, stupidsim reads the accessibility tree through Xcode's AXPTranslator, which talks to the
// guest over CoreSimulator. Elsewhere (x86Sim on Linux) there is no AXPTranslator, so this program is
// started inside the device (`x86sim spawn`) and reads the same tree through AXRuntime, the
// framework VoiceOver and XCTest use. Verified on the iOS 27.0 runtime (24A434) of Xcode 27 and the
// iOS 27.2 runtime (24B8117) under x86Sim 0.3.0.
//
//     stupidsim-guest tree [--springboard]    the app in front (or SpringBoard) and its elements
//     stupidsim-guest hit <x> <y>             what is drawn on top at a point, normalized 0...1
//     stupidsim-guest banner                  the notification banner on screen, if any
//     stupidsim-guest apps                    the apps the shell reports as current, to debug
//     stupidsim-guest pasteboard-get          the general pasteboard's text
//     stupidsim-guest pasteboard-set <base64> replaces it with this UTF-8 text
//     stupidsim-guest serve <socket>          stays running and answers those commands but the
//                                             pasteboard ones on a socket
//
// The answer is one JSON value between BEGIN and END marker lines, because whatever starts the
// program may write its own lines into the same output. A failure is {"error": "..."} and exit 1.
//
// Starting a program in an x86Sim device costs about as much as reading a tree (0.27 s of 0.5 s on
// a 20-core desktop, x86Sim 0.5.0, iOS 27.2), so stupidsim keeps one server per boot: each
// connection sends one line, a JSON array of the command and its arguments, and reads back the
// same JSON as above, without the marker lines, until the server closes the connection.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kBegin = @"@@stupidsim-guest-begin@@";
static NSString *const kEnd = @"@@stupidsim-guest-end@@";
static NSString *const kShortLookIdentifier = @"NotificationShortLookView";
static NSString *const kFailure = @"StupidsimGuestFailure";
// While serving, a failure answers that one request instead of ending the program.
static BOOL serving = NO;

// The parts of AXRuntime's AXElement this uses. Every selector is checked before it is sent.
@interface AXElement : NSObject
+ (NSArray *)defaultSystemShellCurrentApplications;
+ (instancetype)defaultSystemShellApplication;
+ (instancetype)elementAtCoordinate:(CGPoint)point withVisualPadding:(BOOL)padding;
- (NSArray *)explorerElements;
- (NSString *)label;
- (id)value;
- (NSString *)axIdentifier;
- (CGRect)frame;
- (unsigned long long)traits;
- (int)pid;
- (NSArray *)customActions;
- (id)uiElement;
@end

@interface AXUIElement : NSObject
- (id)objectWithAXAttribute:(long)attribute;
@end

// AXRuntime attribute numbers, read straight from the element when AXElement's own accessor answers
// something else. Found by reading every attribute of known elements on iOS 27.0 (24A434).
static const long kAXValueAttribute = 2006;

static void emit(id object, int status) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    printf("%s\n", kBegin.UTF8String);
    fwrite(json.bytes, 1, json.length, stdout);
    printf("\n%s\n", kEnd.UTF8String);
    fflush(stdout);
    exit(status);
}

static void fail(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void fail(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (serving) @throw [NSException exceptionWithName:kFailure reason:message userInfo:nil];
    emit(@{@"error": message}, 1);
}

static void require(id target, NSString *selector) {
    if (![target respondsToSelector:NSSelectorFromString(selector)]) {
        fail(@"%@ does not answer %@ on this runtime", NSStringFromClass(object_getClass(target)), selector);
    }
}

static NSString *text(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:NSString.class]) return [value length] ? value : nil;
    if ([value isKindOfClass:NSAttributedString.class]) return [[value string] length] ? [value string] : nil;
    return [value description];
}

static NSArray *rect(CGRect r) {
    return @[@[@(r.origin.x), @(r.origin.y)], @[@(r.size.width), @(r.size.height)]];
}

// UIAccessibilityTraits bits mapped to the roles AXPTranslator reports on a Mac for the same
// elements, so `ui-tree` prints the same lines on both. Checked against Xcode 27's translator
// (27A266a) on a SwiftUI test app's feed and settings, the Settings app and the home screen: buttons,
// text, images, headings and text fields. Bit 10 is the search field, 18 text entry and 22 a home
// screen icon, which the Mac calls a button.
static void addRole(unsigned long long traits, NSMutableDictionary *into) {
    NSString *role = @"AXGenericElement", *description = @"";
    if (traits & (1ull << 10) || traits & (1ull << 18)) { role = @"AXTextField"; description = @"text field"; }
    else if (traits & (1ull << 0) || traits & (1ull << 22)) { role = @"AXButton"; description = @"button"; }
    else if (traits & (1ull << 1)) { role = @"AXLink"; description = @"link"; }
    else if (traits & (1ull << 12)) { role = @"AXSlider"; description = @"slider"; }
    else if (traits & (1ull << 16)) { role = @"AXHeading"; description = @"heading"; }
    else if (traits & (1ull << 2)) { role = @"AXImage"; description = @"image"; }
    else if (traits & (1ull << 6)) { role = @"AXStaticText"; description = @"text"; }
    into[@"role"] = role;
    into[@"roleDescription"] = description;
}

static NSMutableDictionary *element(AXElement *e) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"frame"] = rect(e.frame);
    if (text(e.label)) d[@"label"] = text(e.label);
    // -value answers nil where the element has one ("2 apps" on a home screen folder); the
    // attribute itself does not.
    id uiElement = [e respondsToSelector:@selector(uiElement)] ? e.uiElement : nil;
    id value = [uiElement respondsToSelector:@selector(objectWithAXAttribute:)]
        ? [uiElement objectWithAXAttribute:kAXValueAttribute] : e.value;
    if (text(value)) d[@"value"] = text(value);
    // -identifier answers "0" for every element; the accessibility identifier is axIdentifier.
    if (text(e.axIdentifier)) d[@"identifier"] = text(e.axIdentifier);
    unsigned long long traits = e.traits;
    addRole(traits, d);
    d[@"traits"] = @(traits);
    d[@"children"] = @[];
    return d;
}

// AXElement needs app accessibility and automation on before apps answer; on stays on, as it does
// after AXPTranslator has read a device on a Mac.
static Class loadAXElement(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW)) {
        fail(@"AXRuntime did not load: %s", dlerror());
    }
    void (*setApplicationAccessibility)(int) = dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
    void (*setAutomation)(int) = dlsym(RTLD_DEFAULT, "_AXSSetAutomationEnabled");
    if (!setApplicationAccessibility || !setAutomation) {
        fail(@"libAccessibility has no _AXSApplicationAccessibilitySetEnabled or _AXSSetAutomationEnabled");
    }
    setApplicationAccessibility(1);
    setAutomation(1);
    Class ax = NSClassFromString(@"AXElement");
    if (!ax) fail(@"AXRuntime has no AXElement");
    return ax;
}

// The system shell answers which app is in front. Asked through the system-wide element instead,
// AXRuntime logs that it must be the shell and answers nothing (iOS 27.0, 24A434).
static AXElement *frontmost(Class ax) {
    require(ax, @"defaultSystemShellCurrentApplications");
    NSArray *apps = nil;
    // An app that just launched registers with the shell a moment later.
    for (int attempt = 0; attempt < 12 && apps.count == 0; attempt++) {
        apps = [ax defaultSystemShellCurrentApplications];
        if (apps.count == 0) usleep(250000);
    }
    if (apps.count == 0) fail(@"no app is in front, or none answered accessibility");
    return apps.firstObject;
}

// What the shell reports as current, for working out which app a tree reads.
static NSDictionary *applications(Class ax) {
    NSMutableArray *current = [NSMutableArray array];
    for (AXElement *app in [ax defaultSystemShellCurrentApplications] ?: @[]) {
        [current addObject:@{@"pid": @(app.pid), @"label": text(app.label) ?: @"", @"frame": rect(app.frame),
                             @"elements": @(app.explorerElements.count)}];
    }
    return @{@"current": current};
}

static AXElement *springBoard(Class ax) {
    require(ax, @"defaultSystemShellApplication");
    AXElement *shell = [ax defaultSystemShellApplication];
    if (!shell) fail(@"SpringBoard did not answer accessibility");
    return shell;
}

// The elements VoiceOver visits, flat, which is what the Mac translator presents as the app's
// children.
static NSDictionary *tree(AXElement *app) {
    require(app, @"explorerElements");
    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    root[@"frame"] = rect(app.frame);
    root[@"role"] = @"AXApplication";
    root[@"roleDescription"] = @"application";
    if (text(app.label)) root[@"label"] = text(app.label);
    root[@"pid"] = @(app.pid);
    NSMutableArray *children = [NSMutableArray array];
    for (AXElement *child in app.explorerElements ?: @[]) [children addObject:element(child)];
    root[@"children"] = children;
    return root;
}

static NSString *actionName(id action) {
    for (NSString *selector in @[@"name", @"localizedName", @"title"]) {
        if ([action respondsToSelector:NSSelectorFromString(selector)]) {
            NSString *name = text([action valueForKey:selector]);
            if (name) return name;
        }
    }
    if ([action isKindOfClass:NSDictionary.class]) {
        for (id key in action) {
            if ([[key description] localizedCaseInsensitiveContainsString:@"name"]) return text(action[key]);
        }
    }
    return text(action);
}

static AXElement *shortLook(Class ax) {
    AXElement *shell = springBoard(ax);
    for (AXElement *candidate in shell.explorerElements ?: @[]) {
        if ([text(candidate.axIdentifier) isEqualToString:kShortLookIdentifier]) return candidate;
    }
    return nil;
}

static NSDictionary *banner(Class ax) {
    AXElement *view = shortLook(ax);
    if (!view) return @{@"banner": [NSNull null]};
    NSMutableArray *actions = [NSMutableArray array];
    if ([view respondsToSelector:@selector(customActions)]) {
        for (id action in view.customActions ?: @[]) {
            NSString *name = actionName(action);
            if (name) [actions addObject:name];
        }
    }
    return @{@"banner": @{
        @"label": text(view.label) ?: @"",
        @"frame": rect(view.frame),
        @"screen": rect(springBoard(ax).frame),
        @"actions": actions,
    }};
}

// UIPasteboard reads an item through work it queues on the main thread, so called from the main
// thread its `string` waits for itself forever (iOS 27.0, 24A434). So this runs on another thread
// while the main thread runs its run loop.
static NSDictionary *pasteboardAnswer(NSArray<NSString *> *args) {
    if (!dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW)) fail(@"UIKit did not load: %s", dlerror());
    NSString *value = nil;
    if ([args.firstObject isEqualToString:@"pasteboard-set"]) {
        if (args.count < 2) fail(@"pasteboard-set needs the text, base64 encoded");
        NSData *data = [[NSData alloc] initWithBase64EncodedString:args[1] options:0];
        value = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!value) fail(@"pasteboard-set takes base64 encoded UTF-8");
    }
    id board = [NSClassFromString(@"UIPasteboard") valueForKey:@"generalPasteboard"];
    if (!board) fail(@"UIPasteboard has no general pasteboard");
    if (value) [board setValue:value forKey:@"string"];
    return @{@"text": text([board valueForKey:@"string"]) ?: @""};
}

static void pasteboard(NSArray<NSString *> *args) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        emit(pasteboardAnswer(args), 0);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        fail(@"the pasteboard did not answer within 15 s");
    });
    CFRunLoopRun();
}

static BOOL isPasteboard(NSString *command) {
    return [command isEqualToString:@"pasteboard-get"] || [command isEqualToString:@"pasteboard-set"];
}

// The answer to one accessibility command; on the main thread, as AXRuntime is used elsewhere.
static id axAnswer(NSArray<NSString *> *args, Class ax) {
    NSString *command = args.firstObject ?: @"";
    if ([command isEqualToString:@"tree"]) {
        BOOL shell = args.count > 1 && [args[1] isEqualToString:@"--springboard"];
        return tree(shell ? springBoard(ax) : frontmost(ax));
    }
    if ([command isEqualToString:@"hit"]) {
        if (args.count < 3) fail(@"hit needs x and y, normalized 0...1");
        require(ax, @"elementAtCoordinate:withVisualPadding:");
        CGRect screen = springBoard(ax).frame;
        CGPoint point = CGPointMake(screen.origin.x + args[1].doubleValue * screen.size.width,
                                    screen.origin.y + args[2].doubleValue * screen.size.height);
        AXElement *hit = [ax elementAtCoordinate:point withVisualPadding:NO];
        return @{@"element": hit ? element(hit) : [NSNull null], @"screen": rect(screen)};
    }
    if ([command isEqualToString:@"apps"]) return applications(ax);
    if ([command isEqualToString:@"banner"]) return banner(ax);
    fail(@"unknown command \"%@\": tree, hit, apps, banner, pasteboard-get, pasteboard-set or serve", command);
    return nil;
}

static BOOL writeAll(int fd, NSData *data) {
    const char *bytes = data.bytes;
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t written = write(fd, bytes + offset, data.length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        offset += (size_t)written;
    }
    return YES;
}

// One request: a line holding a JSON array of strings, at most 64 KB.
static NSArray<NSString *> *readRequest(int fd) {
    NSMutableData *line = [NSMutableData data];
    char buffer[4096];
    while (line.length < 65536) {
        ssize_t got = read(fd, buffer, sizeof buffer);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        char *newline = memchr(buffer, '\n', (size_t)got);
        [line appendBytes:buffer length:newline ? (size_t)(newline - buffer) : (size_t)got];
        if (newline) break;
    }
    id args = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    if (![args isKindOfClass:NSArray.class] || [args count] == 0) fail(@"a request is one line holding a JSON array of strings");
    for (id arg in args) {
        if (![arg isKindOfClass:NSString.class]) fail(@"a request is one line holding a JSON array of strings");
    }
    return args;
}

// Accepts connections on a background thread and answers them one at a time, while the main thread
// runs its run loop: AXRuntime is called there through dispatch_sync, and the pasteboard, which
// needs that run loop free, is read on the accepting thread.
static void serve(NSString *path) {
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (path.length == 0 || strlen(path.fileSystemRepresentation) >= sizeof address.sun_path) {
        fail(@"serve needs a socket path shorter than %zu bytes", sizeof address.sun_path);
    }
    strcpy(address.sun_path, path.fileSystemRepresentation);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) fail(@"socket: %s", strerror(errno));
    unlink(address.sun_path);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0) fail(@"bind %@: %s", path, strerror(errno));
    chmod(address.sun_path, 0600);
    if (listen(listener, 8) != 0) fail(@"listen: %s", strerror(errno));
    Class ax = loadAXElement();
    serving = YES;
    printf("serving on %s\n", address.sun_path);
    fflush(stdout);
    dispatch_async(dispatch_queue_create("stupidsim-guest.serve", DISPATCH_QUEUE_SERIAL), ^{
        for (;;) {
            int connection = accept(listener, NULL, NULL);
            if (connection < 0) {
                if (errno == EINTR) continue;
                // The socket is gone (the device is shutting down): nothing more will connect.
                exit(1);
            }
            @autoreleasepool {
                __block id answer = nil;
                @try {
                    NSArray<NSString *> *args = readRequest(connection);
                    if (isPasteboard(args.firstObject)) {
                        // Read back empty here after AXRuntime was loaded (x86Sim 0.5.0, iOS 27.2);
                        // stupidsim starts a program of its own for the pasteboard instead.
                        fail(@"the pasteboard is read by a program of its own, not the server");
                    } else if ([args.firstObject isEqualToString:@"ping"]) {
                        answer = @{@"pid": @(getpid())};
                    } else {
                        __block NSString *failure = nil;
                        dispatch_sync(dispatch_get_main_queue(), ^{
                            @try {
                                answer = axAnswer(args, ax);
                            } @catch (NSException *exception) {
                                failure = exception.reason ?: exception.name;
                            }
                        });
                        if (failure) answer = @{@"error": failure};
                    }
                } @catch (NSException *exception) {
                    answer = @{@"error": exception.reason ?: exception.name};
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:answer options:NSJSONWritingSortedKeys error:nil];
                writeAll(connection, json ?: [@"{\"error\": \"the answer could not be written as JSON\"}" dataUsingEncoding:NSUTF8StringEncoding]);
                close(connection);
            }
        }
    });
    CFRunLoopRun();
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [args addObject:@(argv[i])];
        NSString *command = args.firstObject ?: @"";
        if ([command isEqualToString:@"serve"]) serve(args.count > 1 ? args[1] : @"");
        if (isPasteboard(command)) pasteboard(args);
        emit(axAnswer(args, loadAXElement()), 0);
    }
}
