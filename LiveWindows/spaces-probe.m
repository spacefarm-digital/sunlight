// Target-machine probe: what macOS lets a plain process (SIP on, no add-on) do with Spaces. Reads the
// Desktops, makes a scratch Space and removes it, and moves a window it owns (and one owned by a child
// process, standing in for another app) to the scratch Space and back, through both the plain SkyLight
// calls and the AppKit bridge operations (SLSBridged*Operation). Only ever destroys a Space it created.
// Build: clang -fobjc-arc LiveWindows/spaces-probe.m -framework Cocoa -o /tmp/sunbeam-spaces-probe
// Run:   /tmp/sunbeam-spaces-probe [read|create|move]   (no argument runs all three)
#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#include <dlfcn.h>

typedef int (*MainConnection)(void);
typedef CFArrayRef (*CopyManagedDisplaySpaces)(int);
typedef uint64_t (*GetActiveSpace)(int);
typedef CFArrayRef (*CopySpacesForWindows)(int, int, CFArrayRef);
typedef uint64_t (*SpaceCreate)(int, int, int);
typedef CGError (*SpaceDestroy)(int, uint64_t);
typedef CGError (*MoveWindowsToManagedSpace)(int, CFArrayRef, uint64_t);
typedef CGError (*AddWindowsAndRemoveFromSpaces)(int, uint64_t, CFArrayRef, int);
typedef CGError (*ShowSpaces)(int, CFArrayRef);
typedef CGError (*HideSpaces)(int, CFArrayRef);
typedef int (*SpaceGetType)(int, uint64_t);
typedef CFArrayRef (*CopySpaces)(int, int);

static void *sky;
static int cid;
#define SYM(type, name) ((type)dlsym(sky, name))

static void run(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

static NSArray *spacesFor(uint32_t wid) {
    CFArrayRef r = SYM(CopySpacesForWindows, "SLSCopySpacesForWindows")(cid, 0x7, (__bridge CFArrayRef)@[@(wid)]);
    return r ? CFBridgingRelease(r) : @[];
}

// Every Space the window server knows, managed or not: the way to tell a Space exists.
static BOOL exists(uint64_t sid) {
    NSArray *all = CFBridgingRelease(SYM(CopySpaces, "SLSCopySpaces")(cid, 7));
    return [all containsObject:@(sid)];
}

static NSArray *readDesktops(BOOL print) {
    NSArray *displays = CFBridgingRelease(SYM(CopyManagedDisplaySpaces, "SLSCopyManagedDisplaySpaces")(cid));
    NSMutableArray *all = [NSMutableArray array];
    for (NSDictionary *d in displays) {
        if (print) printf("display %s current=%s\n", [d[@"Display Identifier"] UTF8String], [[d[@"Current Space"][@"id64"] description] UTF8String]);
        for (NSDictionary *s in d[@"Spaces"]) {
            [all addObject:s[@"id64"]];
            if (print) printf("  space id64=%-6s type=%-2s uuid=%s%s\n", [[s[@"id64"] description] UTF8String], [[s[@"type"] description] UTF8String],
                              [[s[@"uuid"] description] UTF8String], s[@"TileLayoutManager"] ? " (full-screen tiles)" : "");
        }
    }
    return all;
}

static void doRead(void) {
    printf("--- read\nSLSCopySpaces(cid, 7)=%s\n", [[CFBridgingRelease(SYM(CopySpaces, "SLSCopySpaces")(cid, 7)) componentsJoinedByString:@","] UTF8String]);
    printf("cid=%d active=%llu\n", cid, SYM(GetActiveSpace, "SLSGetActiveSpace")(cid));
    readDesktops(YES);
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    int shown = 0;
    for (NSDictionary *w in windows) {
        if ([w[(id)kCGWindowLayer] intValue] != 0 || shown >= 12) continue;
        uint32_t wid = [w[(id)kCGWindowNumber] unsignedIntValue];
        NSArray *s = spacesFor(wid);
        if (!s.count) continue;
        printf("  window %u %-20.20s spaces=%s\n", wid, [w[(id)kCGWindowOwnerName] UTF8String], [[s componentsJoinedByString:@","] UTF8String]);
        shown++;
    }
}

// The bridge: an AppKit process can hand window-management operations to the WindowServer's WM bridge.
static id bridge(NSString *name, id (^make)(id allocated)) {
    Class c = NSClassFromString(name);
    if (!c) { printf("  %s: class missing\n", name.UTF8String); return nil; }
    id op = make([c alloc]);
    @try {
        id result = ((id (*)(id, SEL))objc_msgSend)(op, sel_registerName("performWithWMBridgeDelegate"));
        return result ?: @"(void)";
    } @catch (NSException *e) { printf("  %s threw %s: %s\n", name.UTF8String, e.name.UTF8String, e.reason.UTF8String); return nil; }
}

static uint64_t createPlain(void) {
    uint64_t sid = SYM(SpaceCreate, "SLSSpaceCreate")(cid, 1, 0);
    printf("SLSSpaceCreate(cid, 1, 0) -> %llu, exists=%d type=%d, in managed list=%s\n", sid, exists(sid),
           sid ? SYM(SpaceGetType, "SLSSpaceGetType")(cid, sid) : -1, [readDesktops(NO) containsObject:@(sid)] ? "yes" : "no");
    return sid;
}

static void destroyPlain(uint64_t sid) {
    if (!sid) return;
    CGError e = SYM(SpaceDestroy, "SLSSpaceDestroy")(cid, sid); run(0.3);
    printf("SLSSpaceDestroy(%llu) -> %d, exists afterwards=%d\n", sid, e, exists(sid));
}

static uint64_t createBridge(void) {
    id r = bridge(@"SLSBridgedSpaceCreateOperation", ^id(id a) {
        return ((id (*)(id, SEL, unsigned, id))objc_msgSend)(a, sel_registerName("initWithOptions:values:"), 1, @{});
    });
    uint64_t sid = 0;
    if ([r respondsToSelector:sel_registerName("spaceID")]) sid = ((uint64_t (*)(id, SEL))objc_msgSend)(r, sel_registerName("spaceID"));
    printf("bridge SpaceCreate -> %s spaceID=%llu exists=%d in managed list=%s\n", [[r description] UTF8String], sid, exists(sid),
           [readDesktops(NO) containsObject:@(sid)] ? "yes" : "no");
    return sid;
}

static void destroyBridge(uint64_t sid) {
    if (!sid) return;
    bridge(@"SLSBridgedSpaceDestroyOperation", ^id(id a) {
        return ((id (*)(id, SEL, uint64_t))objc_msgSend)(a, sel_registerName("initWithSpaceID:"), sid);
    });
    run(0.3);
    printf("bridge SpaceDestroy(%llu), exists afterwards=%d\n", sid, exists(sid));
}

static void doCreate(void) {
    printf("--- create\n");
    destroyPlain(createPlain());
    destroyBridge(createBridge());
}

static NSWindow *window(NSString *title) {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 320, 200)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed = NO; w.title = title; [w orderFront:nil];
    return w;
}

static void tryMove(const char *who, uint32_t wid, uint64_t home, uint64_t scratch) {
    NSArray *ws = @[@(wid)];
    printf(" %s window %u on %s\n", who, wid, [[spacesFor(wid) componentsJoinedByString:@","] UTF8String]);
    CGError e = SYM(MoveWindowsToManagedSpace, "SLSMoveWindowsToManagedSpace")(cid, (__bridge CFArrayRef)ws, scratch); run(0.3);
    printf("  SLSMoveWindowsToManagedSpace -> %d, now %s\n", e, [[spacesFor(wid) componentsJoinedByString:@","] UTF8String]);
    e = SYM(MoveWindowsToManagedSpace, "SLSMoveWindowsToManagedSpace")(cid, (__bridge CFArrayRef)ws, home); run(0.3);
    printf("  ...and back -> %d, now %s\n", e, [[spacesFor(wid) componentsJoinedByString:@","] UTF8String]);
    e = SYM(AddWindowsAndRemoveFromSpaces, "SLSSpaceAddWindowsAndRemoveFromSpaces")(cid, scratch, (__bridge CFArrayRef)ws, 7); run(0.3);
    printf("  SLSSpaceAddWindowsAndRemoveFromSpaces -> %d, now %s\n", e, [[spacesFor(wid) componentsJoinedByString:@","] UTF8String]);
    e = SYM(AddWindowsAndRemoveFromSpaces, "SLSSpaceAddWindowsAndRemoveFromSpaces")(cid, home, (__bridge CFArrayRef)ws, 7); run(0.3);
    printf("  ...and back -> %d, now %s\n", e, [[spacesFor(wid) componentsJoinedByString:@","] UTF8String]);
    bridge(@"SLSBridgedMoveWindowsToManagedSpaceOperation", ^id(id a) {
        return ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(a, sel_registerName("initWithWindows:spaceID:"), ws, scratch);
    }); run(0.3);
    printf("  bridge MoveWindowsToManagedSpace -> now %s\n", [[spacesFor(wid) componentsJoinedByString:@","] UTF8String]);
    bridge(@"SLSBridgedMoveWindowsToManagedSpaceOperation", ^id(id a) {
        return ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(a, sel_registerName("initWithWindows:spaceID:"), ws, home);
    }); run(0.3);
    printf("  ...and back -> now %s\n", [[spacesFor(wid) componentsJoinedByString:@","] UTF8String]);
}

static void doMove(const char *self) {
    printf("--- move\n");
    uint64_t home = SYM(GetActiveSpace, "SLSGetActiveSpace")(cid);
    uint64_t scratch = createPlain();
    BOOL bridged = NO;
    if (!scratch) { scratch = createBridge(); bridged = YES; }
    if (!scratch) { printf("no scratch Space; skipping moves\n"); return; }
    NSWindow *own = window(@"spaces-probe own");
    run(0.5);
    tryMove("own", (uint32_t)own.windowNumber, home, scratch);

    // Another process's window: a child copy of this probe that only shows a window and prints its number.
    NSPipe *pipe = [NSPipe pipe];
    NSTask *child = [[NSTask alloc] init];
    child.executableURL = [NSURL fileURLWithPath:@(self)]; child.arguments = @[@"child"]; child.standardOutput = pipe;
    [child launchAndReturnError:nil];
    NSData *line = [pipe.fileHandleForReading availableData];
    uint32_t other = (uint32_t)[[[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] intValue];
    if (other) tryMove("child-process", other, home, scratch); else printf("child window missing\n");
    [child terminate]; [own close];
    // Other user Desktops already there: move our own window to the next one and back (nothing destroyed).
    for (NSNumber *sid in readDesktops(NO)) {
        if (sid.unsignedLongLongValue == home || SYM(SpaceGetType, "SLSSpaceGetType")(cid, sid.unsignedLongLongValue) != 0) continue;
        NSWindow *probe = window(@"spaces-probe other desktop"); run(0.4);
        tryMove("own→existing desktop", (uint32_t)probe.windowNumber, home, sid.unsignedLongLongValue);
        [probe close];
        break;
    }
    if (bridged) destroyBridge(scratch); else destroyPlain(scratch);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
        if (!sky) { fprintf(stderr, "no SkyLight\n"); return 2; }
        cid = SYM(MainConnection, "SLSMainConnectionID")();
        const char *what = argc > 1 ? argv[1] : "all";
        if (!strcmp(what, "child")) {
            NSWindow *w = window(@"spaces-probe child");
            printf("%ld\n", (long)w.windowNumber); fflush(stdout);
            run(30);
            return 0;
        }
        if (!strcmp(what, "read") || !strcmp(what, "all")) doRead();
        if (!strcmp(what, "create") || !strcmp(what, "all")) doCreate();
        if (!strcmp(what, "move") || !strcmp(what, "all")) doMove(argv[0]);
    }
    return 0;
}
