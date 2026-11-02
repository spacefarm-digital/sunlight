// Real socket/session parser with fake WindowServer calls. Never changes desktop windows.
#include <CoreGraphics/CoreGraphics.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
#define SA_SOCKET_BUFF_LEN 0x1000
#define SUNBEAM_WEAK   // the transaction calls are defined right here
#define SUNBEAM_SETTLE_NOW   // native sizes at once, not a frame later: the tests read them straight back
static CGAffineTransform transforms[10];
static int levels[10], mutations[10];
int SLSMainConnectionID(void) { return 1; }
CGError SLSGetWindowOwner(int c, uint32_t w, int *o) { if (w >= 10) return kCGErrorFailure; *o = 3; return 0; }
CGError SLSGetWindowTransform(int c, uint32_t w, CGAffineTransform *t) { *t = transforms[w]; return 0; }
CGError SLSSetWindowTransform(int c, uint32_t w, CGAffineTransform t) { transforms[w] = t; mutations[w]++; return 0; }
CGError SLSGetWindowLevel(int c, uint32_t w, int *l) { *l = levels[w]; return 0; }
// Each level set numbered in the order made: a pinned window goes up before the entered one (sunlight-52).
static int level_calls, level_seq[10];
CGError SLSSetWindowLevel(int c, uint32_t w, int l) { levels[w] = l; if (w < 10) level_seq[w] = ++level_calls; return 0; }
static int orders[10];   // how often each window was given a place in the order
CGError SLSOrderWindow(int c, uint32_t w, int o, uint32_t r) { if (w < 10) orders[w]++; return 0; }
CGError SLSDisableUpdate(int c) { return 0; }
CGError SLSReenableUpdate(int c) { return 0; }
// Transactions apply as they're built here; what matters is that the payload uses them.
static int commits;
CFTypeRef SLSTransactionCreate(int c) { return CFRetain(kCFBooleanTrue); }
CGError SLSTransactionCommit(CFTypeRef t, int s) { commits++; return 0; }
CGError SLSTransactionOrderWindow(CFTypeRef t, uint32_t w, int o, uint32_t r) { if (w < 10) orders[w]++; return 0; }
// Transforms set inside a transaction, per window: a window put back must not get its native size in
// one that changes levels too (sunlight-14), where it could land over the canvas for a frame.
static int txn_transforms[10];
CGError SLSTransactionSetWindowTransform(CFTypeRef t, uint32_t w, int u, int u2, CGAffineTransform tr) { transforms[w] = tr; mutations[w]++; txn_transforms[w]++; return 0; }
CGError SLSTransactionSetWindowLevel(CFTypeRef t, uint32_t w, int l) { levels[w] = l; return 0; }
OSStatus SLSMoveWindowWithGroup(int c, uint32_t w, CGPoint *p) { transforms[w] = CGAffineTransformMakeTranslation(-p->x, -p->y); return 0; }
// The native move in a transaction (sunlight-15), which the handoff uses in place of the direct one.
static int txn_moves[10];
static CGPoint moved_to[10];
CGError SLSTransactionMoveWindowWithGroup(CFTypeRef t, uint32_t w, CGPoint p) { transforms[w] = CGAffineTransformMakeTranslation(-p.x, -p.y); if (w < 10) { txn_moves[w]++; moved_to[w] = p; } return 0; }
CGError SLSGetWindowBounds(int c, uint32_t w, CGRect *f) { *f = CGRectMake(-transforms[w].tx, -transforms[w].ty, 400, 300); return 0; }
// Shapes (sunlight-52): a region is faked as its rectangle count, and what each window was last shaped to.
static int shape_rects[10], shape_sets[10]; static CGPoint shape_at[10];
CGError CGSNewRegionWithRect(const CGRect *r, CFTypeRef *out) { int one = 1; *out = CFNumberCreate(NULL, kCFNumberIntType, &one); return 0; }
CGError CGSNewRegionWithRectList(const CGRect *r, int n, CFTypeRef *out) {
    for (int i = 0; i < n; ++i) assert(r[i].size.width > 0 && r[i].size.height > 0 && r[i].origin.x >= 0 && r[i].origin.y >= 0);
    *out = CFNumberCreate(NULL, kCFNumberIntType, &n); return 0;
}
CGError SLSSetWindowShape(int c, uint32_t w, float x, float y, CFTypeRef region) {
    if (w >= 10) return kCGErrorFailure;
    int n = 0; CFNumberGetValue(region, kCFNumberIntType, &n);
    shape_rects[w] = n; shape_sets[w]++; shape_at[w] = CGPointMake(x, y); return 0;
}
// What the window server answers about a window's shadow (the active look's density and offset), and
// the looks written to it.
static float shadow_sd[10], shadow_density[10]; static int shadow_oy[10]; static unsigned shadow_writes;
static CFDictionaryRef shadow_dicts[10];
CGError SLSGetWindowShadowAndRimParameters(int c, uint32_t w, float *sd, float *d, int *x, int *y, unsigned int *f) {
    if (w >= 10) return kCGErrorFailure;
    *sd = shadow_sd[w]; *d = shadow_density[w]; *x = 0; *y = shadow_oy[w]; *f = 0; return 0;
}
CGError SLSWindowSetShadowProperties(uint32_t w, CFDictionaryRef properties) {
    if (w >= 10) return kCGErrorFailure;
    if (shadow_dicts[w]) CFRelease(shadow_dicts[w]);
    shadow_dicts[w] = CFRetain(properties); shadow_writes++; return 0;
}
// Window alpha (sunlight-40): what the window server holds for each window, and how often it was set.
static float alphas[10] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1}; static int alpha_writes[10];
CGError SLSGetWindowAlpha(int c, uint32_t w, float *a) { if (w >= 10) return kCGErrorFailure; *a = alphas[w]; return 0; }
CGError SLSSetWindowAlpha(int c, uint32_t w, float a) { if (w >= 10) return kCGErrorFailure; alphas[w] = a; alpha_writes[w]++; return 0; }
// The window server's listing, faked: every fake window (ids under 10) is on screen unless marked
// `offscreen` (minimized, say), and asked about one window alone the list has it only while it is on
// screen, as the real one does. The other listings (below a window, everything on screen) stay empty,
// as they always were here.
static bool offscreen[10];
static CFArrayRef fake_window_list(CGWindowListOption option, CGWindowID wid) {
    if (option != kCGWindowListOptionIncludingWindow || wid >= 10 || offscreen[wid]) return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
    CFMutableDictionaryRef entry = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid); CFDictionarySetValue(entry, kCGWindowNumber, number); CFRelease(number);
    CFNumberRef layer = CFNumberCreate(NULL, kCFNumberIntType, &levels[wid]); CFDictionarySetValue(entry, kCGWindowLayer, layer); CFRelease(layer);
    CFDictionarySetValue(entry, kCGWindowIsOnscreen, kCFBooleanTrue);
    CFArrayRef list = CFArrayCreate(NULL, (const void **)&entry, 1, &kCFTypeArrayCallBacks);
    CFRelease(entry);
    return list;
}
#define sunbeam_window_list fake_window_list
#include "osax/sunbeam.h"

static int start(pthread_t *thread) {
    int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    assert(pthread_create(thread, NULL, sunbeam_session, (void *)(intptr_t)pair[1]) == 0);
    char magic[9]; assert(sunbeam_read(pair[0], magic, 9)); assert(memcmp(magic, SUNBEAM_MAGIC, 9) == 0);
    return pair[0];
}
static void send_frame(int fd, uint32_t wid, bool malformed) {
    char bytes[41] = {0}; int16_t length = 39; uint32_t backdrop = 1, overlay = 2; uint16_t count = 1;
    float transform[6] = {2, 0, 0, 2, -400, -200};
    if (malformed) transform[0] = NAN;
    memcpy(bytes, &length, 2); bytes[2] = SUNBEAM_FRAME;
    memcpy(bytes + 3, &backdrop, 4); memcpy(bytes + 7, &overlay, 4); memcpy(bytes + 11, &count, 2);
    memcpy(bytes + 13, &wid, 4); memcpy(bytes + 17, transform, 24);
    // Deliberately fragment every byte, including the int16 envelope.
    for (int i = 0; i < sizeof(bytes); ++i) assert(send(fd, bytes + i, 1, 0) == 1);
    uint8_t status; assert(sunbeam_read(fd, &status, 1)); assert(status == (malformed ? 1 : 0));
}
// The same frame from another canvas: its own backdrop and overlay.
static void send_canvas_frame(int fd, uint32_t wid, uint32_t backdrop, uint32_t overlay) {
    char bytes[41] = {0}; int16_t length = 39; uint16_t count = 1;
    float transform[6] = {4, 0, 0, 4, -100, -100};
    memcpy(bytes, &length, 2); bytes[2] = SUNBEAM_FRAME;
    memcpy(bytes + 3, &backdrop, 4); memcpy(bytes + 7, &overlay, 4); memcpy(bytes + 11, &count, 2);
    memcpy(bytes + 13, &wid, 4); memcpy(bytes + 17, transform, 24);
    assert(send(fd, bytes, sizeof(bytes), 0) == sizeof(bytes));
    uint8_t status; assert(sunbeam_read(fd, &status, 1)); assert(status == 0);
}
// A frame with a flags byte (sunlight-8): `count` windows, each at the same transform scaled by `scale`.
static void send_flagged(int fd, const uint32_t *wids, int count, uint8_t flags, float scale) {
    char bytes[3 + 11 + 28 * 8]; int16_t length = 1 + 11 + 28 * count; uint32_t backdrop = 1, overlay = 2; uint16_t n = count;
    memcpy(bytes, &length, 2); bytes[2] = SUNBEAM_FRAME;
    memcpy(bytes + 3, &backdrop, 4); memcpy(bytes + 7, &overlay, 4); memcpy(bytes + 11, &n, 2); bytes[13] = flags;
    for (int i = 0; i < count; ++i) {
        float transform[6] = {scale, 0, 0, scale, -400, -200};
        memcpy(bytes + 14 + i * 28, &wids[i], 4); memcpy(bytes + 18 + i * 28, transform, 24);
    }
    assert(send(fd, bytes, 2 + length, 0) == 2 + length);
    uint8_t status; assert(sunbeam_read(fd, &status, 1)); assert(status == 0);
}
// A shadow request: the inactive look set `inactive` of the way, and the active look `active` of the
// way, from the standard inactive look (8, 0.22, 0.55, 7) to the standard active one (20, 0.4, 0.6, 18).
static uint8_t send_shadow(int fd, uint32_t wid, float inactive, float active) {
    char bytes[47]; int16_t length = 45;
    float looks[8] = {8, 0.22f, 0.55f, 7, 20, 0.4f, 0.6f, 18};
    memcpy(bytes, &length, 2); bytes[2] = SUNBEAM_SHADOW;
    memcpy(bytes + 3, &wid, 4); memcpy(bytes + 7, &inactive, 4); memcpy(bytes + 11, &active, 4); memcpy(bytes + 15, looks, 32);
    assert(send(fd, bytes, sizeof(bytes), 0) == sizeof(bytes));
    uint8_t status; assert(sunbeam_read(fd, &status, 1));
    return status;
}
// An alpha request for one window.
static uint8_t send_alpha(int fd, uint32_t wid, float alpha) {
    char bytes[12]; int16_t length = 10;
    memcpy(bytes, &length, 2); bytes[2] = SUNBEAM_ALPHA; bytes[3] = 1;
    memcpy(bytes + 4, &wid, 4); memcpy(bytes + 8, &alpha, 4);
    assert(send(fd, bytes, sizeof(bytes), 0) == sizeof(bytes));
    uint8_t status; assert(sunbeam_read(fd, &status, 1));
    return status;
}
// The windows pinned to the screen (sunlight-42): a count, then their IDs. `length_count` is the count
// the length is made for, so a request whose count byte doesn't match can be sent too.
static uint8_t send_pin(int fd, const uint32_t *wids, int count, int length_count) {
    char bytes[2 + 2 + 4 * 8]; int16_t length = 2 + 4 * length_count;
    memcpy(bytes, &length, 2); bytes[2] = SUNBEAM_PIN; bytes[3] = (char)count;
    for (int i = 0; i < length_count; ++i) memcpy(bytes + 4 + i * 4, &wids[i], 4);
    assert(send(fd, bytes, 2 + length, 0) == 2 + length);
    uint8_t status; assert(sunbeam_read(fd, &status, 1));
    return status;
}
// A shape request (sunlight-52): a window and a corner radius in its own points.
static uint8_t send_shape(int fd, uint32_t wid, float radius) {
    char bytes[11]; int16_t length = 9;
    memcpy(bytes, &length, 2); bytes[2] = SUNBEAM_SHAPE;
    memcpy(bytes + 3, &wid, 4); memcpy(bytes + 7, &radius, 4);
    assert(send(fd, bytes, sizeof(bytes), 0) == sizeof(bytes));
    uint8_t status; assert(sunbeam_read(fd, &status, 1));
    return status;
}
// An empty full frame naming the app in front (sunlight-11): every window released, the canvas staying up.
static void send_above(int fd, int pid) {
    char above[2 + 16]; int16_t above_size = 16; uint32_t bd = 1, ov = 2; uint16_t none = 0;
    memcpy(above, &above_size, 2); above[2] = SUNBEAM_FRAME;
    memcpy(above + 3, &bd, 4); memcpy(above + 7, &ov, 4); memcpy(above + 11, &none, 2); above[13] = SUNBEAM_FRAME_FULL;
    memcpy(above + 14, &pid, 4);
    assert(send(fd, above, sizeof(above), 0) == sizeof(above));
    uint8_t ack; assert(sunbeam_read(fd, &ack, 1) && ack == 0);
}
static double shadow_value(uint32_t w, const char *key) {
    CFStringRef string = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFNumberRef number = shadow_dicts[w] ? CFDictionaryGetValue(shadow_dicts[w], string) : NULL;
    CFRelease(string);
    assert(number);
    double value = 0; assert(CFNumberGetValue(number, kCFNumberDoubleType, &value));
    return value;
}
// One look's radius, density and offset as last written for a window.
static void check_look(uint32_t w, const char *suffix, double radius, double density, int offset) {
    char key[96];
    snprintf(key, sizeof(key), "com.apple.WindowShadowRadius%s", suffix); assert(shadow_value(w, key) == radius);
    snprintf(key, sizeof(key), "com.apple.WindowShadowDensity%s", suffix); assert(fabs(shadow_value(w, key) - density) < 1e-6);
    snprintf(key, sizeof(key), "com.apple.WindowShadowVerticalOffset%s", suffix); assert(shadow_value(w, key) == offset);
}
int main(void) {
    CGAffineTransform original = CGAffineTransformMakeTranslation(-20, -30);
    transforms[4] = original; levels[4] = -10;
    pthread_t thread; int fd = start(&thread);
    send_frame(fd, 4, false);
    assert(transforms[4].a == 2 && levels[4] == SUNBEAM_LEVEL);
    assert(levels[1] == SUNBEAM_LEVEL && levels[2] == SUNBEAM_LEVEL);   // the canvas is lifted with its windows (sunlight-11)
    int released_in_txn = txn_transforms[4];
    close(fd); pthread_join(thread, NULL);
    assert(CGAffineTransformEqualToTransform(transforms[4], original) && levels[4] == -10);
    assert(txn_transforms[4] == released_in_txn);   // native size directly, after the commit
    assert(levels[1] == 0 && levels[2] == 0);   // and comes down as they go back
    assert(mutations[5] == 0); // unmanaged window untouched

    fd = start(&thread); send_frame(fd, 4, false); send_frame(fd, 4, true);
    close(fd); pthread_join(thread, NULL);
    assert(CGAffineTransformEqualToTransform(transforms[4], original));

    fd = start(&thread); send_frame(fd, 4, false);
    char handoff[15]; int16_t size = 13; uint32_t wid = 4; float x = 120, y = 80;
    memcpy(handoff, &size, 2); handoff[2] = SUNBEAM_HANDOFF;
    memcpy(handoff + 3, &wid, 4); memcpy(handoff + 7, &x, 4); memcpy(handoff + 11, &y, 4);
    assert(send(fd, handoff, 15, 0) == 15);
    uint8_t status; assert(sunbeam_read(fd, &status, 1) && status == 0);
    // The handoff keeps the canvas up and lifts the entered window above it (sunlight-27), even the
    // 13-byte form that names no canvas.
    assert(levels[4] == SUNBEAM_FRONT && levels[1] == SUNBEAM_LEVEL && levels[2] == SUNBEAM_LEVEL);
    close(fd); pthread_join(thread, NULL);
    assert(transforms[4].a == 1 && transforms[4].tx == -120 && transforms[4].ty == -80);
    assert(commits >= 1); // the handoff went through a transaction

    // A handoff on a lease that never framed the window: taken from where it is (sunlight-5).
    fd = start(&thread);
    x = 30; y = 40; memcpy(handoff + 7, &x, 4); memcpy(handoff + 11, &y, 4);
    assert(send(fd, handoff, 15, 0) == 15);
    assert(sunbeam_read(fd, &status, 1) && status == 0);
    close(fd); pthread_join(thread, NULL);
    assert(transforms[4].a == 1 && transforms[4].tx == -30 && transforms[4].ty == -40);
    // A window that doesn't exist can't be handed off.
    fd = start(&thread);
    uint32_t missing = 11; memcpy(handoff + 3, &missing, 4);
    assert(send(fd, handoff, 15, 0) == 15);
    assert(sunbeam_read(fd, &status, 1) && status == 7);
    pthread_join(thread, NULL); close(fd);
    memcpy(handoff + 3, &wid, 4);
    x = 120; y = 80; memcpy(handoff + 7, &x, 4); memcpy(handoff + 11, &y, 4);
    fd = start(&thread); send_frame(fd, 4, false);
    assert(send(fd, handoff, 15, 0) == 15);
    assert(sunbeam_read(fd, &status, 1) && status == 0);
    close(fd); pthread_join(thread, NULL);

    // Shadows (sunlight-7): over a flight in, the inactive look is eased towards the active one; the window
    // server answers the active look's density and offset for a titled window.
    shadow_sd[4] = 32.9412f; shadow_density[4] = 0.4f; shadow_oy[4] = 18;
    fd = start(&thread); send_frame(fd, 4, false);
    assert(send_shadow(fd, 4, 0, 1) == 0);
    check_look(4, "Inactive", 8, 0.22, 7); check_look(4, "Active", 20, 0.4, 18);
    assert(CFDictionaryGetCount(shadow_dicts[4]) == 22);   // the whole dictionary AppKit writes
    assert(shadow_value(4, "com.apple.WindowShadowContentAwareInctive") == 1 && shadow_value(4, "com.apple.WindowShadowRimRadiusActive") == 3);
    assert(fabs(shadow_value(4, "com.apple.WindowShadowRimDensityInactive") - 0.55) < 1e-6);
    assert(send_shadow(fd, 4, 0.5f, 1) == 0);
    check_look(4, "Inactive", 14, 0.31, 13); check_look(4, "Active", 20, 0.4, 18);   // 12.5 rounds up
    assert(fabs(shadow_value(4, "com.apple.WindowShadowRimDensityInactive") - 0.575) < 1e-6);
    assert(send_shadow(fd, 4, 1, 1) == 0);
    check_look(4, "Inactive", 20, 0.4, 18); check_look(4, "Active", 20, 0.4, 18);
    assert(send(fd, handoff, 15, 0) == 15);
    assert(sunbeam_read(fd, &status, 1) && status == 0);
    close(fd); pthread_join(thread, NULL);
    check_look(4, "Inactive", 20, 0.4, 18);   // the entered window keeps both looks active: the switch to key changes nothing
    // Back to the canvas: on a new lease, with no frame, the active look (the one shown while key) is
    // eased back to the inactive one; then, once the canvas is in front, the standard pair again.
    fd = start(&thread);
    assert(send_shadow(fd, 4, 0, 0.5f) == 0); check_look(4, "Active", 14, 0.31, 13); check_look(4, "Inactive", 8, 0.22, 7);
    assert(send_shadow(fd, 4, 0, 0) == 0); check_look(4, "Active", 8, 0.22, 7);
    assert(send_shadow(fd, 4, 0, 1) == 0); check_look(4, "Active", 20, 0.4, 18); check_look(4, "Inactive", 8, 0.22, 7);
    // A window that is gone, a request that makes no sense, a window with another kind of shadow (a
    // panel's density and offset): answered, nothing written, and the lease goes on.
    unsigned writes = shadow_writes;
    assert(send_shadow(fd, 11, 0, 1) == 8);
    assert(send_shadow(fd, 0, 0, 1) == 1);
    assert(send_shadow(fd, 4, 1.5f, 1) == 1);
    shadow_sd[7] = 10; shadow_density[7] = 0.3f; shadow_oy[7] = 4;
    assert(send_shadow(fd, 7, 1, 1) == 9);
    assert(shadow_writes == writes && !shadow_dicts[7]);
    send_frame(fd, 4, false);
    close(fd); pthread_join(thread, NULL);
    assert(shadow_writes == writes);   // a window with its standard looks is left alone when put back
    // A flight cut short: the lease ends with other looks in force, and the window gets its standard ones
    // back as it is put back under the canvas.
    fd = start(&thread); send_frame(fd, 4, false);
    assert(send_shadow(fd, 4, 0.5f, 1) == 0); check_look(4, "Inactive", 14, 0.31, 13);
    close(fd); pthread_join(thread, NULL);
    check_look(4, "Inactive", 8, 0.22, 7); check_look(4, "Active", 20, 0.4, 18);

    // Flagged frames (sunlight-8). A partial frame on a fresh lease takes its windows in full; a partial
    // one after that moves only the transforms in it, through a transaction, and leaves a window it
    // doesn't name leased where it was; an empty partial frame is a keepalive; a full frame without a
    // window puts that one back.
    transforms[4] = original; transforms[5] = CGAffineTransformMakeTranslation(-50, -60); levels[4] = -10; levels[5] = -10;
    uint32_t both[2] = {4, 5}, just4[1] = {4};
    fd = start(&thread);
    send_flagged(fd, both, 2, 0, 2);
    assert(transforms[4].a == 2 && transforms[5].a == 2 && levels[4] == SUNBEAM_LEVEL && levels[5] == SUNBEAM_LEVEL);
    int before = commits, moves4 = mutations[4], moves5 = mutations[5];
    send_flagged(fd, just4, 1, 0, 3);
    assert(transforms[4].a == 3 && transforms[5].a == 2);
    assert(commits == before + 1 && mutations[4] == moves4 + 1 && mutations[5] == moves5);
    send_flagged(fd, just4, 1, 0, 3);   // unchanged: no call at all
    assert(commits == before + 1 && mutations[4] == moves4 + 1);
    send_flagged(fd, NULL, 0, 0, 1);    // keepalive: nothing released
    assert(transforms[5].a == 2);
    send_flagged(fd, just4, 1, SUNBEAM_FRAME_FULL, 2);
    assert(transforms[4].a == 2 && transforms[5].tx == -50 && levels[5] == -10);   // 5 put back
    close(fd); pthread_join(thread, NULL);
    assert(CGAffineTransformEqualToTransform(transforms[4], original) && levels[4] == -10);
    // A full empty frame still releases everything.
    fd = start(&thread);
    send_flagged(fd, both, 2, SUNBEAM_FRAME_FULL, 2);
    send_flagged(fd, NULL, 0, SUNBEAM_FRAME_FULL, 1);
    assert(CGAffineTransformEqualToTransform(transforms[4], original) && transforms[5].tx == -50);
    assert(levels[1] == 0 && levels[2] == 0);
    close(fd); pthread_join(thread, NULL);
    // An empty frame naming the app in front (sunlight-11, 15 bytes): taken, everything released, the
    // canvas staying up above it all (sunlight-27; the app has no windows here to lift above it).
    fd = start(&thread);
    send_flagged(fd, both, 2, SUNBEAM_FRAME_FULL, 2);
    assert(levels[1] == SUNBEAM_LEVEL && levels[4] == SUNBEAM_LEVEL);
    {
        char above[2 + 16]; int16_t above_size = 16; uint32_t bd = 1, ov = 2; uint16_t none = 0; int pid = getpid();
        memcpy(above, &above_size, 2); above[2] = SUNBEAM_FRAME;
        memcpy(above + 3, &bd, 4); memcpy(above + 7, &ov, 4); memcpy(above + 11, &none, 2); above[13] = SUNBEAM_FRAME_FULL;
        memcpy(above + 14, &pid, 4);
        assert(send(fd, above, sizeof(above), 0) == sizeof(above));
        uint8_t ack; assert(sunbeam_read(fd, &ack, 1) && ack == 0);
    }
    assert(CGAffineTransformEqualToTransform(transforms[4], original) && levels[4] == -10 && levels[1] == SUNBEAM_LEVEL && levels[2] == SUNBEAM_LEVEL);
    close(fd); pthread_join(thread, NULL);

    // A handoff that keeps windows on show (sunlight-10): 5 goes to its point at its own level and stays,
    // 6 (not asked for) is put back, 7 (asked for but never leased) and a repeat of 5 change nothing.
    transforms[4] = original; transforms[5] = CGAffineTransformMakeTranslation(-50, -60);
    transforms[6] = CGAffineTransformMakeTranslation(-70, -80); levels[5] = -10; levels[6] = -10;
    uint32_t three[3] = {4, 5, 6};
    fd = start(&thread);
    send_flagged(fd, three, 3, SUNBEAM_FRAME_FULL, 2);
    assert(levels[5] == SUNBEAM_LEVEL && levels[6] == SUNBEAM_LEVEL);
    int moves7 = mutations[7], put_back_in_txn = txn_transforms[6];
    {
        char keep[2 + 22 + 3 * 12]; int16_t keep_size = 22 + 3 * 12; uint32_t keep_wid = 4, ov = 2, bd = 1; float kx = 120, ky = 80;
        memcpy(keep, &keep_size, 2); keep[2] = SUNBEAM_HANDOFF;
        memcpy(keep + 3, &keep_wid, 4); memcpy(keep + 7, &kx, 4); memcpy(keep + 11, &ky, 4);
        memcpy(keep + 15, &ov, 4); memcpy(keep + 19, &bd, 4); keep[23] = 3;
        uint32_t kept[3] = {7, 5, 5}; float points[3][2] = {{0, 0}, {300, 50}, {300, 50}};
        for (int k = 0; k < 3; ++k) {
            memcpy(keep + 24 + k * 12, &kept[k], 4); memcpy(keep + 28 + k * 12, &points[k][0], 4); memcpy(keep + 32 + k * 12, &points[k][1], 4);
        }
        assert(send(fd, keep, sizeof(keep), 0) == sizeof(keep));
        assert(sunbeam_read(fd, &status, 1) && status == 0);
        assert(transforms[4].a == 1 && transforms[4].tx == -120 && transforms[4].ty == -80);
        assert(transforms[5].a == 1 && transforms[5].tx == -300 && transforms[5].ty == -50 && levels[5] == SUNBEAM_FRONT);
        assert(transforms[6].a == 1 && transforms[6].tx == -70 && transforms[6].ty == -80 && levels[6] == -10);
        assert(txn_transforms[6] == put_back_in_txn);   // put back at native size outside the transaction
        assert(mutations[7] == moves7);
        assert(txn_moves[4] >= 1 && txn_moves[5] >= 1);   // moved natively in the transaction (sunlight-15)
        // A count that doesn't match the length, or a kept window that is the entered one: refused.
        keep[23] = 2;
        assert(send(fd, keep, sizeof(keep), 0) == sizeof(keep));
        uint8_t refused = 0; ssize_t got = recv(fd, &refused, 1, 0); assert(got == 0 || (got == 1 && refused != 0));
    }
    close(fd); pthread_join(thread, NULL);
    // Nothing leased any more: the kept window stays where the handoff left it.
    assert(transforms[5].tx == -300 && transforms[5].ty == -50);

    // With the visible top (sunlight-28): a point above it is drawn there, but the native move stops at
    // the top (AppKit would push a window with its title bar above the menu bar back down), for the
    // entered window and the kept ones alike.
    transforms[4] = original; transforms[5] = CGAffineTransformMakeTranslation(-60, -70); levels[4] = -10; levels[5] = -10;
    fd = start(&thread);
    send_flagged(fd, three, 3, SUNBEAM_FRAME_FULL, 2);
    {
        char keep[2 + 22 + 12 + 4]; int16_t keep_size = 22 + 12 + 4; uint32_t keep_wid = 4, ov = 2, bd = 1; float kx = 120, ky = -10, top = 30;
        memcpy(keep, &keep_size, 2); keep[2] = SUNBEAM_HANDOFF;
        memcpy(keep + 3, &keep_wid, 4); memcpy(keep + 7, &kx, 4); memcpy(keep + 11, &ky, 4);
        memcpy(keep + 15, &ov, 4); memcpy(keep + 19, &bd, 4); keep[23] = 1;
        uint32_t kept = 5; float px = 300, py = -50;
        memcpy(keep + 24, &kept, 4); memcpy(keep + 28, &px, 4); memcpy(keep + 32, &py, 4);
        memcpy(keep + 36, &top, 4);
        assert(send(fd, keep, sizeof(keep), 0) == sizeof(keep));
        assert(sunbeam_read(fd, &status, 1) && status == 0);
        assert(moved_to[4].x == 120 && moved_to[4].y == 30 && transforms[4].a == 1 && transforms[4].tx == -120 && transforms[4].ty == 10);
        assert(moved_to[5].x == 300 && moved_to[5].y == 30 && transforms[5].a == 1 && transforms[5].tx == -300 && transforms[5].ty == 50);
        assert(levels[5] == SUNBEAM_FRONT);
        // Keeping nothing, with the top: a count of zero, then the top (26 bytes).
        char none[2 + 26]; int16_t none_size = 26; float nx = 200, ny = -40;
        memcpy(none, &none_size, 2); none[2] = SUNBEAM_HANDOFF;
        memcpy(none + 3, &keep_wid, 4); memcpy(none + 7, &nx, 4); memcpy(none + 11, &ny, 4);
        memcpy(none + 15, &ov, 4); memcpy(none + 19, &bd, 4); none[23] = 0; memcpy(none + 24, &top, 4);
        assert(send(fd, none, sizeof(none), 0) == sizeof(none));
        assert(sunbeam_read(fd, &status, 1) && status == 0);
        assert(moved_to[4].x == 200 && moved_to[4].y == 30 && transforms[4].tx == -200 && transforms[4].ty == 40);
    }
    close(fd); pthread_join(thread, NULL);

    // A window minimized while leased (sunlight-12): off screen, it is scaled and lifted with the
    // rest but never given a place in the order, which from the Dock's connection would bring it back
    // on screen; released, it gets its level and transform back, again without an order.
    transforms[8] = CGAffineTransformMakeTranslation(-80, -90); transforms[9] = CGAffineTransformMakeTranslation(-90, -100);
    levels[8] = 0; levels[9] = 0; offscreen[9] = true;
    uint32_t pair89[2] = {8, 9};
    fd = start(&thread);
    send_flagged(fd, pair89, 2, SUNBEAM_FRAME_FULL, 2);
    assert(transforms[9].a == 2 && levels[9] == SUNBEAM_LEVEL);
    assert(orders[8] > 0 && orders[9] == 0);
    close(fd); pthread_join(thread, NULL);
    assert(transforms[9].a == 1 && transforms[9].tx == -90 && levels[9] == 0 && orders[9] == 0);
    assert(transforms[8].a == 1 && transforms[8].tx == -80 && levels[8] == 0);
    offscreen[9] = false;

    // A lease per canvas (sunlight-13): two canvases of one app, on two displays, at once. Each lifts its
    // own window and its own backdrop and overlay, and each going puts back only what it took.
    transforms[4] = original; levels[4] = -10;   // the handoff above left 4 at its point
    CGAffineTransform other = CGAffineTransformMakeTranslation(-1700, -40);
    transforms[3] = other; levels[3] = 0; levels[6] = 0; levels[7] = 0;
    pthread_t second; int fd2;
    fd = start(&thread); fd2 = start(&second);
    send_frame(fd, 4, false);
    send_canvas_frame(fd2, 3, 6, 7);
    assert(transforms[4].a == 2 && transforms[3].a == 4);
    assert(levels[4] == SUNBEAM_LEVEL && levels[3] == SUNBEAM_LEVEL && levels[6] == SUNBEAM_LEVEL && levels[7] == SUNBEAM_LEVEL);
    close(fd2); pthread_join(second, NULL);
    assert(CGAffineTransformEqualToTransform(transforms[3], other) && levels[3] == 0 && levels[6] == 0 && levels[7] == 0);
    assert(transforms[4].a == 2 && levels[4] == SUNBEAM_LEVEL && levels[1] == SUNBEAM_LEVEL);   // the first lease's untouched
    send_frame(fd, 4, false);   // and it goes on
    close(fd); pthread_join(thread, NULL);
    assert(CGAffineTransformEqualToTransform(transforms[4], original) && levels[4] == -10);

    // Two canvases (sunlight-41): a window one canvas left on show at a handoff is put back only by that
    // canvas's next frame, not by the other display's canvas framing its own windows.
    transforms[3] = other; levels[3] = 0; levels[6] = 0; levels[7] = 0; levels[4] = -10;
    fd = start(&thread); fd2 = start(&second);
    send_frame(fd, 4, false);
    send_canvas_frame(fd2, 3, 6, 7);
    {
        char h[2 + 21]; int16_t h_size = 21; uint32_t hw = 3, hov = 7, hbd = 6; float hx = 1700, hy = 40;
        memcpy(h, &h_size, 2); h[2] = SUNBEAM_HANDOFF;
        memcpy(h + 3, &hw, 4); memcpy(h + 7, &hx, 4); memcpy(h + 11, &hy, 4); memcpy(h + 15, &hov, 4); memcpy(h + 19, &hbd, 4);
        assert(send(fd2, h, sizeof(h), 0) == sizeof(h));
        assert(sunbeam_read(fd2, &status, 1) && status == 0);
    }
    assert(levels[3] == SUNBEAM_FRONT);
    send_frame(fd, 4, false);
    assert(levels[3] == SUNBEAM_FRONT);   // the other canvas's frame leaves it on show
    send_canvas_frame(fd2, 5, 6, 7);
    assert(levels[3] == 0);               // its own canvas's frame without it puts it back to its own level
    close(fd2); pthread_join(second, NULL);
    close(fd); pthread_join(thread, NULL);
    levels[4] = -10; levels[5] = 0; transforms[4] = original;

    // Alpha (sunlight-40): set on leased windows only, relative to the window's own, and the window's own
    // back when the lease ends, when a full frame leaves it out, and when it is handed off.
    alphas[4] = 0.9f;
    fd = start(&thread); send_frame(fd, 4, false);
    assert(send_alpha(fd, 4, 0.5f) == 0 && fabsf(alphas[4] - 0.45f) < 1e-6);
    assert(send_alpha(fd, 4, 0) == 0 && alphas[4] == 0);
    assert(send_alpha(fd, 5, 0.2f) == 0 && alpha_writes[5] == 0);   // not this lease's: passed over
    assert(send_alpha(fd, 4, 2) == 1 && alphas[4] == 0);              // out of range: refused, nothing set
    assert(send_alpha(fd, 4, NAN) == 1);
    send_frame(fd, 4, false);   // the lease goes on after a refusal
    close(fd); pthread_join(thread, NULL);
    assert(fabsf(alphas[4] - 0.9f) < 1e-6);
    fd = start(&thread); send_frame(fd, 4, false);
    assert(send_alpha(fd, 4, 0.25f) == 0 && fabsf(alphas[4] - 0.225f) < 1e-6);
    assert(send(fd, handoff, 15, 0) == 15);
    assert(sunbeam_read(fd, &status, 1) && status == 0);
    assert(fabsf(alphas[4] - 0.9f) < 1e-6);   // the entered window is never left see-through
    int alpha_before = alpha_writes[4];
    close(fd); pthread_join(thread, NULL);
    assert(alpha_writes[4] == alpha_before);   // and nothing more to put back
    uint32_t solo4[1] = {4}, solo3[1] = {3};
    levels[3] = 0; alphas[3] = 1;
    fd = start(&thread);
    uint32_t pair34[2] = {3, 4};
    send_flagged(fd, pair34, 2, SUNBEAM_FRAME_FULL, 2);
    assert(send_alpha(fd, 3, 0.5f) == 0 && alphas[3] == 0.5f);
    send_flagged(fd, solo4, 1, SUNBEAM_FRAME_FULL, 2);   // 3 left out: back to its own
    assert(alphas[3] == 1);
    assert(send_alpha(fd, 3, 0.5f) == 0 && alphas[3] == 1);   // and no longer this lease's to change
    (void)solo3;
    close(fd); pthread_join(thread, NULL);
    alphas[4] = 1;
    transforms[4] = original; levels[4] = -10;

    // Pinned windows (sunlight-42): 5 pinned, 4 entered through a handoff. 5 stays as it is, at its
    // transform, at the pinned level above the entered window: neither moved, nor settled, nor put back;
    // 6 is put back as before. A request whose count doesn't match its length is refused, the lease goes on.
    transforms[4] = original; transforms[5] = CGAffineTransformMakeTranslation(-50, -60);
    transforms[6] = CGAffineTransformMakeTranslation(-70, -80); levels[4] = -10; levels[5] = 0; levels[6] = 0;
    fd = start(&thread);
    send_flagged(fd, three, 3, SUNBEAM_FRAME_FULL, 2);
    {
        uint32_t pin5[1] = {5};
        assert(send_pin(fd, pin5, 2, 1) == 1);
        assert(send_pin(fd, pin5, 1, 1) == 0);
        int moves5 = mutations[5], txmoves5 = txn_moves[5], orders5 = orders[5];
        char h[2 + 21]; int16_t h_size = 21; uint32_t hw = 4, hov = 2, hbd = 1; float hx = 120, hy = 80;
        memcpy(h, &h_size, 2); h[2] = SUNBEAM_HANDOFF;
        memcpy(h + 3, &hw, 4); memcpy(h + 7, &hx, 4); memcpy(h + 11, &hy, 4); memcpy(h + 15, &hov, 4); memcpy(h + 19, &hbd, 4);
        assert(send(fd, h, sizeof(h), 0) == sizeof(h));
        assert(sunbeam_read(fd, &status, 1) && status == 0);
        assert(levels[5] == SUNBEAM_PINNED && transforms[5].a == 2 && transforms[5].tx == -400 && transforms[5].ty == -200);
        assert(mutations[5] == moves5 && txn_moves[5] == txmoves5 && orders[5] == orders5);
        assert(level_seq[5] < level_seq[4]);   // the tile went up before the entered window came up under it
        assert(levels[4] == SUNBEAM_FRONT && transforms[4].a == 1 && transforms[4].tx == -120);
        assert(levels[6] == 0 && transforms[6].a == 1 && transforms[6].tx == -70);
        assert(levels[1] == SUNBEAM_LEVEL && levels[2] == SUNBEAM_LEVEL);
    }
    close(fd); pthread_join(thread, NULL);
    assert(levels[5] == SUNBEAM_PINNED && transforms[5].a == 2);   // on show, like the entered window, once the lease is gone
    // The canvas back: a frame takes the pinned window as any window (its native place read off its
    // bounds), and a frame without it puts it back to its own level, not the pinned one.
    fd = start(&thread);
    {
        uint32_t just5[1] = {5};
        send_flagged(fd, just5, 1, SUNBEAM_FRAME_FULL, 3);
        assert(levels[5] == SUNBEAM_LEVEL && transforms[5].a == 3);
        send_flagged(fd, just4, 1, SUNBEAM_FRAME_FULL, 2);
        assert(levels[5] == 0 && transforms[5].a == 1 && transforms[5].tx == -400 && transforms[5].ty == -200);
    }
    close(fd); pthread_join(thread, NULL);
    // A release for an app that took the front: the pinned window stays on show at the pinned level, as
    // it is, and the lease forgets it; the rest go back and the canvas stays up.
    transforms[4] = original; transforms[5] = CGAffineTransformMakeTranslation(-50, -60); levels[4] = -10; levels[5] = 0;
    fd = start(&thread);
    send_flagged(fd, both, 2, SUNBEAM_FRAME_FULL, 2);
    {
        uint32_t pin5[1] = {5};
        assert(send_pin(fd, pin5, 1, 1) == 0);
        int moves5 = mutations[5];
        // Its corners rounded (sunlight-52): 2 * 12 + 1 rectangles, at the window's native place; a
        // radius of 0 is one rectangle; a nonsense radius or an unknown window is refused.
        assert(send_shape(fd, 5, 12) == 0 && shape_rects[5] == 25 && shape_at[5].x == 400 && shape_at[5].y == 200);
        assert(send_shape(fd, 5, -1) == 1 && send_shape(fd, 5, NAN) == 1 && send_shape(fd, 12, 12) == 12);
        assert(send_shape(fd, 6, 0) == 0 && shape_sets[6] == 0);   // never rounded: nothing to put back
        send_above(fd, getpid());
        assert(levels[5] == SUNBEAM_PINNED && transforms[5].a == 2 && mutations[5] == moves5);
        assert(shape_rects[5] == 25);   // on show as a tile, its corners stay
        assert(CGAffineTransformEqualToTransform(transforms[4], original) && levels[4] == -10);
        assert(levels[1] == SUNBEAM_LEVEL && levels[2] == SUNBEAM_LEVEL);
    }
    close(fd); pthread_join(thread, NULL);
    assert(levels[5] == SUNBEAM_PINNED && transforms[5].a == 2 && shape_rects[5] == 25);
    // A radius of 0 puts the full shape back, on a lease that holds nothing.
    fd = start(&thread);
    assert(send_shape(fd, 5, 0) == 0 && shape_rects[5] == 1);
    close(fd); pthread_join(thread, NULL);
    // With no app in front (the lease's end, the canvas going dormant) a pinned window goes back with the rest,
    // its full shape with it.
    transforms[5] = CGAffineTransformMakeTranslation(-50, -60); levels[5] = 0;
    fd = start(&thread);
    send_flagged(fd, both, 2, SUNBEAM_FRAME_FULL, 2);
    {
        uint32_t pin5[1] = {5};
        assert(send_pin(fd, pin5, 1, 1) == 0);
        assert(send_shape(fd, 5, 8) == 0 && shape_rects[5] == 17);
    }
    close(fd); pthread_join(thread, NULL);
    assert(levels[5] == 0 && transforms[5].a == 1 && transforms[5].tx == -50 && transforms[5].ty == -60);
    assert(shape_rects[5] == 1 && shape_at[5].x == 50 && shape_at[5].y == 60);
    assert(CGAffineTransformEqualToTransform(transforms[4], original) && levels[4] == -10);

    fd = start(&thread); send_frame(fd, 4, false);
    // No heartbeat: Dock restores on the three-second lease timeout even if the client hangs.
    pthread_join(thread, NULL); close(fd);
    assert(CGAffineTransformEqualToTransform(transforms[4], original) && levels[4] == -10);
    puts("PASS: fragmented frames, windows put back at native size only after the commit, disconnect, invalid transform, two leases at once, window alpha (leased only, relative, back on release, handoff and a full frame leaving it out), handoff (leased, unleased, missing, keeping windows on show, native places stopped at the menu bar), shadows (eased both ways, refused, cut short), flagged frames (partial, keepalive, full, app in front), the canvas lifted and lowered, a window minimized while leased never ordered, lease expiry, pinned windows (on show through a handoff and a release for an app in front, raised before the windows that come up under them, taken back by a frame, put back at the lease's end), shapes (rounded corners as rows at the native place, refused, put back on request and at the lease's end), unmanaged isolation");
}
