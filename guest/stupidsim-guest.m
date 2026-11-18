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
//
// The answer is one JSON value between BEGIN and END marker lines, because whatever starts the
// program may write its own lines into the same output. A failure is {"error": "..."} and exit 1.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kBegin = @"@@stupidsim-guest-begin@@";
static NSString *const kEnd = @"@@stupidsim-guest-end@@";
static NSString *const kShortLookIdentifier = @"NotificationShortLookView";

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
// thread its `string` waits for itself forever (iOS 27.0, 24A434). It runs on a background queue
// while the main thread runs its run loop; emit() ends the process.
static void pasteboard(NSString *command, int argc, char **argv) {
    if (!dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW)) fail(@"UIKit did not load: %s", dlerror());
    NSString *value = nil;
    if ([command isEqualToString:@"pasteboard-set"]) {
        if (argc < 3) fail(@"pasteboard-set needs the text, base64 encoded");
        NSData *data = [[NSData alloc] initWithBase64EncodedString:@(argv[2]) options:0];
        value = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!value) fail(@"pasteboard-set takes base64 encoded UTF-8");
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id board = [NSClassFromString(@"UIPasteboard") valueForKey:@"generalPasteboard"];
        if (!board) fail(@"UIPasteboard has no general pasteboard");
        if (value) [board setValue:value forKey:@"string"];
        emit(@{@"text": text([board valueForKey:@"string"]) ?: @""}, 0);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        fail(@"the pasteboard did not answer within 15 s");
    });
    CFRunLoopRun();
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *command = argc > 1 ? @(argv[1]) : @"";
        if ([command isEqualToString:@"pasteboard-get"] || [command isEqualToString:@"pasteboard-set"]) {
            pasteboard(command, argc, argv);
        }

        Class ax = loadAXElement();
        if ([command isEqualToString:@"tree"]) {
            BOOL shell = argc > 2 && !strcmp(argv[2], "--springboard");
            emit(tree(shell ? springBoard(ax) : frontmost(ax)), 0);
        }
        if ([command isEqualToString:@"hit"]) {
            if (argc < 4) fail(@"hit needs x and y, normalized 0...1");
            require(ax, @"elementAtCoordinate:withVisualPadding:");
            CGRect screen = springBoard(ax).frame;
            CGPoint point = CGPointMake(screen.origin.x + atof(argv[2]) * screen.size.width,
                                        screen.origin.y + atof(argv[3]) * screen.size.height);
            AXElement *hit = [ax elementAtCoordinate:point withVisualPadding:NO];
            emit(@{@"element": hit ? element(hit) : [NSNull null], @"screen": rect(screen)}, 0);
        }
        if ([command isEqualToString:@"apps"]) emit(applications(ax), 0);
        if ([command isEqualToString:@"banner"]) emit(banner(ax), 0);
        fail(@"unknown command \"%@\": tree, hit, apps, banner, pasteboard-get or pasteboard-set", command);
    }
}
