// Target-machine probe: does the window server hit-test a window through its SkyLight transform?
// The probe draws its own titled window at half size somewhere other than its native frame (its own
// connection sets the transform; no add-on, no Sunlight), puts a "catcher" window of its own under it so
// no synthetic click can land on anything else, then posts real HID clicks and scrolls and prints which
// window got each one and where the app thinks it landed.
//   1. click/scroll at the drawn spot            -> does hit-testing follow the transform?
//   2. click at the native spot                  -> does the untransformed frame still catch events?
//   3. native frame re-anchored under the pointer, transform keeps the picture still -> the fallback route.
// Build: clang -fobjc-arc LiveWindows/hittest-probe.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o /tmp/sunlight-hittest-probe
// Run:   /tmp/sunlight-hittest-probe            (posts events; the terminal needs Accessibility; moves the pointer for ~10 s)
//        /tmp/sunlight-hittest-probe query      (posts nothing: asks the window server which window is under each spot)
//        /tmp/sunlight-hittest-probe manual     (posts nothing: click the red cross yourself, ⌃C to stop)
#import <Cocoa/Cocoa.h>

extern int SLSMainConnectionID(void);
extern CGError SLSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform t);
extern CGError SLSGetWindowTransform(int cid, uint32_t wid, CGAffineTransform *t);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSMoveWindow(int cid, uint32_t wid, CGPoint *origin);
extern CGError SLSDisableUpdate(int cid);
// The window server's own point lookup (what yabai uses to find the window under the pointer).
extern CGError SLSFindWindowAndOwner(int cid, int zero, int one, int zero2, CGPoint *screen, CGPoint *local, uint32_t *wid, int *owner);
extern CGError SLSReenableUpdate(int cid);

static const CGFloat Scale = 0.5;
static const CGPoint Local = {300, 200};          // the spot we aim at, in the window's own top-left points
static NSString *lastHit; static int hits; static BOOL queryOnly; static uint32_t targetWid, catcherWid;

@interface Probe : NSView @property (copy) NSString *name; @property NSColor *fill; @end
@implementation Probe
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r {
    [self.fill setFill]; NSRectFill(self.bounds);
    if ([self.name isEqual:@"target"]) {
        NSRect c = [self convertRect:self.bounds toView:nil];  // content is below the title bar; mark Local in window coords
        CGFloat titleBar = self.window.frame.size.height - c.size.height;
        CGPoint m = {Local.x, Local.y - titleBar};
        [NSColor.systemRedColor setFill];
        NSRectFill(NSMakeRect(m.x - 20, m.y - 2, 40, 4)); NSRectFill(NSMakeRect(m.x - 2, m.y - 20, 4, 40));
    }
}
- (void)report:(NSEvent *)e kind:(NSString *)kind {
    NSPoint w = e.locationInWindow;                       // AppKit's window coords, bottom-up
    CGFloat h = self.window.frame.size.height;
    CGPoint cg = CGEventGetLocation(e.CGEvent);
    lastHit = [NSString stringWithFormat:@"%@ %@ got it: window-local (top-left) %.1f,%.1f | event screen %.1f,%.1f | event window %ld",
               kind, self.name, w.x, h - w.y, cg.x, cg.y, (long)e.windowNumber];
    hits++;
    printf("    %s\n", lastHit.UTF8String); fflush(stdout);
}
- (void)mouseDown:(NSEvent *)e { [self report:e kind:@"click "]; }
- (void)scrollWheel:(NSEvent *)e { if (e.phase == NSEventPhaseBegan || e.phase == NSEventPhaseNone) [self report:e kind:@"scroll"]; }
@end

static CGFloat primaryHeight(void) { return NSScreen.screens.firstObject.frame.size.height; }
static NSWindow *window(CGRect topLeft, NSString *name, NSColor *fill, BOOL titled, NSWindowLevel level) {
    NSRect r = NSMakeRect(topLeft.origin.x, primaryHeight() - topLeft.origin.y - topLeft.size.height, topLeft.size.width, topLeft.size.height);
    NSWindowStyleMask style = titled ? NSWindowStyleMaskTitled : NSWindowStyleMaskBorderless;
    NSWindow *w = [[NSWindow alloc] initWithContentRect:[NSWindow contentRectForFrameRect:r styleMask:style] styleMask:style backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed = NO; w.title = name; w.level = level; w.opaque = NO; w.backgroundColor = NSColor.clearColor;
    Probe *v = [[Probe alloc] initWithFrame:NSZeroRect]; v.name = name; v.fill = fill; w.contentView = v;
    [w orderFrontRegardless]; return w;
}
static void run(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    // Pump AppKit's event queue too: a bare run loop never hands events to the windows.
    while (until.timeIntervalSinceNow > 0) {
        NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.005] inMode:NSDefaultRunLoopMode dequeue:YES];
        if (e) [NSApp sendEvent:e];
    }
}
static CGRect nativeFrame(uint32_t wid) { CGRect b = CGRectZero; SLSGetWindowBounds(SLSMainConnectionID(), wid, &b); return b; }
// Draw the window with its top-left at `drawn`, scaled by Scale. WindowServer's inverse mapping: screen -> window.
static CGError draw(uint32_t wid, CGPoint drawn) {
    CGAffineTransform t = {1 / Scale, 0, 0, 1 / Scale, -drawn.x / Scale, -drawn.y / Scale};
    return SLSSetWindowTransform(SLSMainConnectionID(), wid, t);
}
static void post(CGEventType type, CGPoint p) {
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, p, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, e); CFRelease(e);
}
static NSString *probe(NSString *label, CGPoint p, BOOL scroll) {
    printf("  %s at screen %.0f,%.0f\n", label.UTF8String, p.x, p.y); fflush(stdout);
    CGPoint screenPoint = p, local = CGPointZero; uint32_t found = 0; int owner = 0;
    CGError ferr = SLSFindWindowAndOwner(SLSMainConnectionID(), 0, 1, 0, &screenPoint, &local, &found, &owner);
    NSString *who = found == targetWid ? @"target" : found == catcherWid ? @"catcher" : [NSString stringWithFormat:@"other window %u", found];
    NSString *answer = [NSString stringWithFormat:@"window server lookup -> %@ (err %d), window-local %.1f,%.1f", who, ferr, local.x, local.y];
    printf("    %s\n", answer.UTF8String); fflush(stdout);
    if (queryOnly) return answer;
    int before = hits; lastHit = nil;
    post(kCGEventMouseMoved, p); run(0.25);
    if (scroll) {
        CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, -2);
        CGEventSetLocation(e, p); CGEventPost(kCGHIDEventTap, e); CFRelease(e);
    } else { post(kCGEventLeftMouseDown, p); run(0.05); post(kCGEventLeftMouseUp, p); }
    run(0.5);
    if (hits == before) { printf("    nobody in this probe got it (landed on something else, or posting isn't allowed)\n"); return @"none"; }
    return lastHit;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL manual = argc > 1 && !strcmp(argv[1], "manual");
        queryOnly = argc > 1 && !strcmp(argv[1], "query");
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; [NSApp finishLaunching];
        CGRect screen = CGDisplayBounds(CGMainDisplayID());
        CGPoint savedPointer = CGEventGetLocation(CGEventCreate(NULL));
        // Above Sunlight's canvas (level 1) and ordinary windows, under menus.
        NSWindow *catcher = window(screen, @"catcher", [NSColor colorWithWhite:0 alpha:0.25], NO, NSStatusWindowLevel);
        NSWindow *target = window(CGRectMake(120, 140, 600, 400), @"target", NSColor.systemTealColor, YES, NSStatusWindowLevel + 1);
        [NSApp activateIgnoringOtherApps:YES];
        run(0.4);
        uint32_t wid = (uint32_t)target.windowNumber; targetWid = wid; catcherWid = (uint32_t)catcher.windowNumber;
        CGRect native = nativeFrame(wid);
        CGPoint drawn = {screen.origin.x + screen.size.width - 600 * Scale - 160, native.origin.y + 260};
        CGError err = draw(wid, drawn); run(0.3);
        CGAffineTransform t; SLSGetWindowTransform(SLSMainConnectionID(), wid, &t);
        printf("macOS %s\nconnection %d window %u native frame %.0f,%.0f %.0fx%.0f\n", NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String,
               SLSMainConnectionID(), wid, native.origin.x, native.origin.y, native.size.width, native.size.height);
        printf("own-connection SLSSetWindowTransform -> %d; transform now a=%.3f tx=%.1f ty=%.1f (drawn at %.0f,%.0f, scale %.2f)\n",
               err, t.a, t.tx, t.ty, drawn.x, drawn.y, Scale);
        if (err || fabs(t.a - 1 / Scale) > 1e-3) { printf("RESULT: can't transform own window this way; the probe needs the add-on route instead\n"); return 2; }
        CGPoint atDrawn = {drawn.x + Local.x * Scale, drawn.y + Local.y * Scale};
        CGPoint atNative = {native.origin.x + Local.x, native.origin.y + Local.y};
        printf("aiming at window-local %.0f,%.0f (the red cross)\n", Local.x, Local.y);

        if (manual) {
            printf("manual: click the red cross on the small window (screen %.0f,%.0f), then scroll on it; ⌃C to stop\n", atDrawn.x, atDrawn.y);
            fflush(stdout);
            [NSApp run];
        }
        printf("\n1. drawn spot\n");
        NSString *a = probe(@"click", atDrawn, NO);
        NSString *b = probe(@"scroll", atDrawn, YES);
        printf("\n2. native spot (where the window really is, under the picture's old place)\n");
        NSString *c = probe(@"click", atNative, NO);

        printf("\n3. re-anchor: native frame moved so window-local %.0f,%.0f sits under the pointer, transform keeps the picture still\n", Local.x, Local.y);
        CGPoint anchored = {atDrawn.x - Local.x, atDrawn.y - Local.y};
        int cid = SLSMainConnectionID();
        SLSDisableUpdate(cid);
        CGError moveErr = SLSMoveWindow(cid, wid, &anchored);
        CGError redrawErr = draw(wid, drawn);
        SLSReenableUpdate(cid);
        run(0.3);
        CGRect after = nativeFrame(wid); SLSGetWindowTransform(cid, wid, &t);
        printf("  move -> %d, transform -> %d; native now %.0f,%.0f, transform a=%.3f tx=%.1f ty=%.1f, AppKit frame origin %.0f,%.0f\n",
               moveErr, redrawErr, after.origin.x, after.origin.y, t.a, t.tx, t.ty, target.frame.origin.x, primaryHeight() - NSMaxY(target.frame));
        NSString *d = probe(@"click", atDrawn, NO);
        NSString *e = probe(@"scroll", atDrawn, YES);
        CGPoint nearEdge = {drawn.x + 590 * Scale, drawn.y + 390 * Scale};   // inside the picture, far from the anchor
        NSString *f = probe(@"click far from anchor", nearEdge, NO);
        CGPoint outside = {drawn.x - 40, atDrawn.y};                          // outside the picture, inside the 1x native frame
        NSString *g = probe(@"click outside the picture", outside, NO);

        CGWarpMouseCursorPosition(savedPointer);
        printf("\nSUMMARY\n 1 drawn click: %s\n 1 drawn scroll: %s\n 2 native click: %s\n 3 anchored click: %s\n 3 anchored scroll: %s\n 3 far click: %s\n 3 outside click: %s\n",
               a.UTF8String, b.UTF8String, c.UTF8String, d.UTF8String, e.UTF8String, f.UTF8String, g.UTF8String);
        [catcher close]; [target close];
    }
    return 0;
}
