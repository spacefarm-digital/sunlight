// Sunlight's live-window protocol (Sunbeam protocol v1), Sunlight's own code. Included by payload.m
// after the SkyLight declarations.
// No existing opcode or thumbnail-toggle semantics are changed.
#include <math.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <sys/time.h>
#include <sys/un.h>     // LOCAL_PEERPID

#define SUNBEAM_CAPABILITY 0x70
#define SUNBEAM_SESSION    0x71
#define SUNBEAM_FRAME      0x72
#define SUNBEAM_HANDOFF    0x73
#define SUNBEAM_SHADOW     0x74
#define SUNBEAM_ALPHA      0x75
#define SUNBEAM_PIN        0x76
#define SUNBEAM_SHAPE      0x77
#define SUNBEAM_ANCHOR     0x79
#define SUNBEAM_LIMIT      128
#define SUNBEAM_MAGIC      "SUNBEAM1\n"
// A frame's flags byte (since sunlight-8; a frame without one is taken the old way). Full: level and
// stacking are asserted for every window in it, and a leased window absent from it is put back. Without
// it the frame is partial: only transforms, only for the windows in it, and the rest stay as they are.
#define SUNBEAM_FRAME_FULL 0x01

extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);
extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
extern CGError SLSDisableUpdate(int cid);
extern CGError SLSReenableUpdate(int cid);
// A window-server transaction lands every ordering and transform change in it at once, so no frame
// can show a half-done handoff. (The screen-update freeze above doesn't promise that: a recording
// caught the entered window missing for one frame, between its restore and its raise, on two
// entries in seven.) The prototypes are yabai's. Weak, so the add-on still loads where SkyLight
// lacks them; the calls then go one by one, in an order whose in-between states look like the
// state before or the state after.
#ifndef SUNBEAM_WEAK
#define SUNBEAM_WEAK __attribute__((weak_import))   // the test harness defines its own and leaves this empty
#endif
extern CFTypeRef SLSTransactionCreate(int cid) SUNBEAM_WEAK;
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous) SUNBEAM_WEAK;
extern CGError SLSTransactionOrderWindow(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid) SUNBEAM_WEAK;
extern CGError SLSTransactionSetWindowTransform(CFTypeRef transaction, uint32_t wid, int unknown, int unknown2, CGAffineTransform t) SUNBEAM_WEAK;
extern CGError SLSTransactionSetWindowLevel(CFTypeRef transaction, uint32_t wid, int level) SUNBEAM_WEAK;
extern CGError SLSTransactionMoveWindowWithGroup(CFTypeRef transaction, uint32_t wid, CGPoint point) SUNBEAM_WEAK;

// MARK: The canvas's level
//
// A window the user's app opens is ordered in at the front of its level, and the normal level (0) is
// where every app window lives. With the canvas at that level too, a new window was born on top of
// the canvas, full size, and stayed there until the canvas had listed it and a frame had scaled it:
// a frame or two at 1x, however fast the canvas reacted. So while the canvas presents live windows,
// it, its backdrop and the windows it has taken sit one level up (sunlight-11): a new window is born
// behind the backdrop, out of sight, and first shows once a frame has scaled it and lifted it in.
// The handoff and the release put everything back at the normal level, so an entered window's own new
// windows (sheets, documents) come up in front of it as they always did, and the desktop is stock
// whenever the canvas isn't up.
#define SUNBEAM_LEVEL 1
// The level of the windows on show while the canvas is away (sunlight-27): the entered window and the
// ones kept beside it, or the windows of an app that took the front. The canvas stays at SUNBEAM_LEVEL
// above every other window, which is hidden by level alone: a window an app opens or raises on its own
// is born under the backdrop and shows only once the canvas has placed and lifted it. No order, timing
// or announcement latency can show it first. Nothing of AppKit's sits at 2.
#define SUNBEAM_FRONT 2
// The level of a window pinned to the screen (sunlight-42, `SUNBEAM_PIN`): a small picture of itself
// the canvas keeps at one spot on the screen, which stays on show while the canvas is away, over the
// entered window and the front app's, at the canvas's transform. Nothing of AppKit's sits at 3 either.
#define SUNBEAM_PINNED 3

// MARK: Shadows
//
// macOS keeps two shadow looks per window, which AppKit sets once as the window is made
// (`SLSTransactionSetWindowShadowProperties`: for a titled window radius 8, density 0.22, offset 7 when
// inactive; 20, 0.4, 18 when key), and the window server switches between them as the window becomes
// or stops being key (`SLSTransactionSetWindowActiveShadowLegacy`, from AppKit), in one frame. At the
// seam, right after the entered window has stopped growing, that was the shadow blink. The canvas has
// the two looks rewritten instead: the inactive one eased towards the active over the flight in, so the
// switch as the window becomes key changes nothing, and the active one eased back towards the inactive
// before the canvas takes the screen back, so the switch the other way changes nothing either; then
// the window's standard looks again, which is invisible, the other look being the one shown.
// The prototypes are yabai's and the CGS one with the SLS prefix; weak, as the transaction calls are.
extern CGError SLSWindowSetShadowProperties(uint32_t wid, CFDictionaryRef properties) SUNBEAM_WEAK;
extern CGError SLSGetWindowShadowAndRimParameters(int cid, uint32_t wid, float *deviation, float *density, int *offset_x, int *offset_y, unsigned int *flags) SUNBEAM_WEAK;
#define SUNBEAM_SHADOWS 16

// A leased window's alpha (sunlight-40): the canvas fades a window in as it opens and out as it closes.
// The prototypes are yabai's (its opacity operation, dropped from this add-on until now); weak, as above.
// Whatever alpha the canvas set goes back to the window's own whenever the window is given back — put
// back under the canvas, handed off, or the lease ending — so a window can't be left see-through.
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha) SUNBEAM_WEAK;
extern CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha) SUNBEAM_WEAK;

// A window's shape (sunlight-52, `SUNBEAM_SHAPE`): a window in Picture in Picture is drawn as a tile with
// rounded corners, as a video's is. The window server clips a window to a region (a list of rectangles,
// in the window's own points), so the rounded rectangle is built as rows, one point each at the corners,
// which the tile's transform scales down to a fraction of a pixel. The shape's offsets are the window's
// native place, read off its bounds, so the window stays where it is. The region calls are CoreGraphics's
// CGS ones (SkyLight exports no SLS twins of them, CI's linker says); the shape call is SkyLight's, the
// CGS one with the SLS prefix, as yabai uses for its own windows. Weak, as above. The shapes the
// canvas set are kept across leases, like the pinned windows: the canvas puts a window's full shape back
// when it leaves Picture in Picture, and a release that puts the window back does the same.
extern CGError CGSNewRegionWithRect(const CGRect *rect, CFTypeRef *region) SUNBEAM_WEAK;
extern CGError CGSNewRegionWithRectList(const CGRect *rects, int count, CFTypeRef *region) SUNBEAM_WEAK;
extern CGError SLSSetWindowShape(int cid, uint32_t wid, float x_offset, float y_offset, CFTypeRef region) SUNBEAM_WEAK;
#define SUNBEAM_SHAPES 32
#define SUNBEAM_SHAPE_RADIUS 256

/// A shadow look as AppKit's dictionary has it: the blur radius and vertical offset (whole points),
/// the shadow's density and the rim's.
struct sunbeam_look { float radius, density, rim_density, offset; };

/// A window whose looks the canvas has rewritten: the standard pair the request carried, to go back to,
/// and whether something else is in force. Kept across leases: a window is leased for the flight in,
/// but not when the canvas comes back for it.
struct sunbeam_shadow {
    uint32_t wid;
    int owner;
    struct sunbeam_look inactive, active;
    bool altered;
};
static struct sunbeam_shadow sunbeam_shadows[SUNBEAM_SHADOWS];
static int sunbeam_shadow_next;

struct sunbeam_saved {
    uint32_t wid;
    int owner, level;
    uint32_t below;
    CGAffineTransform transform;
    // What this session last set, so a frame that repeats it costs nothing (`sunbeam_frame`).
    CGAffineTransform applied;
    bool has_applied;
    // The window's own alpha, read the first time the canvas changed it, and whether another is in force.
    float alpha;
    bool alpha_altered;
};
// For a frame without a flags byte (an app older than sunlight-8): level and stacking are asserted for
// every window when the order changes and at most this often otherwise. A frame with flags says itself
// whether it is full; the canvas sends one when its window set or order changes, when the window
// server's listing shows an order it didn't ask for, and once the camera has been still for a second.
#define SUNBEAM_REASSERT_SECONDS 1.0
struct sunbeam_session_state {
    uint32_t order[SUNBEAM_LIMIT];
    int order_count;
    uint32_t backdrop, overlay;
    double asserted_at;
    // The top of the display's visible part (under the menu bar), global, from the canvas's last
    // handoff (sunlight-28); NAN until one says. See `sunbeam_native_at`.
    double top;
    // The windows pinned to the screen (sunlight-42, `SUNBEAM_PIN`): at a handoff, or a release for an
    // app that took the front, a leased one among them stays on show as it is, at `SUNBEAM_PINNED`.
    uint32_t pinned[SUNBEAM_LIMIT];
    int pinned_count;
};

/// Whether the canvas has `wid` pinned to the screen.
static bool sunbeam_is_pinned(const struct sunbeam_session_state *state, uint32_t wid)
{
    for (int i = 0; state && i < state->pinned_count; ++i) if (state->pinned[i] == wid) return true;
    return false;
}

/// Where a window drawn at `drawn` at native size sits natively (sunlight-28): no higher than `top`.
/// AppKit keeps a window's title bar under the menu bar: a window moved natively above it (one kept on
/// show with its top out of view, or put back at a canvas place up there) was pushed down to the menu
/// bar by its app some 70 ms later, into view over the entered window, and off the place the canvas
/// has it. So the native place stops at the top, and the transform draws the window where the canvas
/// has it from there: a translation that puts the window at `drawn` whatever its native origin.
static CGPoint sunbeam_native_at(CGPoint drawn, double top)
{
    if (isfinite(top) && drawn.y < top) drawn.y = top;
    return drawn;
}

static double sunbeam_now(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}
struct sunbeam_record { uint32_t wid; float matrix[6]; };
// Every request, from whichever lease, is applied under this lock, one at a time; it also guards the
// count below. `sunbeam_status` identifies the failed stage in an acknowledgment.
static pthread_mutex_t sunbeam_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t sunbeam_status = 1;

// A lease per canvas (sunlight-13): the app has a canvas on every display, each with its own windows,
// backdrop and overlay, and each holds a lease of its own. Up to this many at once, all from one
// process (the first lease's): another app, or another copy of Sunlight, is turned away while they last,
// as a second lease was before.
#define SUNBEAM_SESSIONS 8
static int sunbeam_sessions;
static pid_t sunbeam_sessions_pid;

static bool sunbeam_read(int fd, void *bytes, size_t length)
{
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = recv(fd, (char *)bytes + offset, length - offset, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        offset += count;
    }
    return true;
}

static bool sunbeam_owner_matches(struct sunbeam_saved *saved)
{
    if (!saved->wid) return false;
    int owner = 0;
    return SLSGetWindowOwner(SLSMainConnectionID(), saved->wid, &owner) == kCGErrorSuccess && owner == saved->owner;
}

/// The window server's listing; the test harness supplies its own.
#ifndef sunbeam_window_list
#define sunbeam_window_list CGWindowListCopyWindowInfo
#endif

/// Whether a window is on screen on the current Space; `level` gets its window level if so. A
/// minimized window is not (the Dock holds it), nor a hidden app's, nor one on another Space.
static bool sunbeam_on_screen(uint32_t wid, int *level)
{
    if (!wid) return false;
    bool result = false;
    CFArrayRef list = sunbeam_window_list(kCGWindowListOptionIncludingWindow, wid);
    if (list && CFArrayGetCount(list)) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(list, 0);
        CFBooleanRef on_screen = CFDictionaryGetValue(entry, kCGWindowIsOnscreen);
        result = on_screen && CFBooleanGetValue(on_screen);
        CFNumberRef layer = CFDictionaryGetValue(entry, kCGWindowLayer);
        if (result && level && layer) CFNumberGetValue(layer, kCFNumberIntType, level);
    }
    if (list) CFRelease(list);
    return result;
}

// MARK: Transactions

/// A transaction when SkyLight has them, else NULL: the ordering and transform calls below then go
/// to the window server one by one.
static CFTypeRef sunbeam_transaction_begin(int cid)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"   // real checks in the add-on, where the symbols are weak
    if (!SLSTransactionCreate || !SLSTransactionCommit || !SLSTransactionOrderWindow || !SLSTransactionSetWindowTransform) return NULL;
#pragma clang diagnostic pop
    return SLSTransactionCreate(cid);
}

/// Commits and releases; false if the window server refused the commit, in which case nothing in
/// it landed and the caller does the same steps without one.
static bool sunbeam_transaction_end(CFTypeRef transaction)
{
    if (!transaction) return true;
    // Synchronous (sunlight-17; 0.1 ms measured): the direct calls that follow a commit, the orders
    // redone and the windows put back settled, then come after everything in it for certain.
    // The commit's code is not the verdict (sunlight-26): on 27.2 it is never kCGErrorSuccess,
    // synchronous or not, while the transaction lands all the same (measured on a window of this
    // process: the move and transform in it were in force, the code was a large negative number).
    // Taken for a refusal, every transaction was followed by the one-call-at-a-time fallback on top
    // of it: the windows put back got their native size at once, where the window server still had
    // them above the backdrop, and the moves made directly under a transform in force shifted the
    // windows on screen. A commit that truly failed leaves the direct calls after it (the orders
    // redone, the settles) to put things right.
    SLSTransactionCommit(transaction, 1);
    CFRelease(transaction);
    return true;
}

static CGError sunbeam_order(CFTypeRef transaction, int cid, uint32_t wid, int order, uint32_t rel_wid)
{
    return transaction ? SLSTransactionOrderWindow(transaction, wid, order, rel_wid) : SLSOrderWindow(cid, wid, order, rel_wid);
}

static CGError sunbeam_transform(CFTypeRef transaction, int cid, uint32_t wid, CGAffineTransform t)
{
    return transaction ? SLSTransactionSetWindowTransform(transaction, wid, 0, 0, t) : SLSSetWindowTransform(cid, wid, t);
}

/// The window's level, in the transaction when there is one and SkyLight can; a window already at the
/// level is left alone (a level set puts the window at the front of that level, even its own). Ordering
/// relative to a window at another level does nothing, so a level change comes before any order that
/// depends on it. `changed` is set when something was asked for.
static CGError sunbeam_level(CFTypeRef transaction, int cid, uint32_t wid, int level, bool *changed)
{
    int current = level;
    if (SLSGetWindowLevel(cid, wid, &current) == kCGErrorSuccess && current == level) return kCGErrorSuccess;
    if (changed) *changed = true;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"   // weak symbol: a real check in the add-on
    if (transaction && SLSTransactionSetWindowLevel) return SLSTransactionSetWindowLevel(transaction, wid, level);
#pragma clang diagnostic pop
    return SLSSetWindowLevel(cid, wid, level);
}

// MARK: Shadow requests

static bool sunbeam_shadow_available(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"   // real checks in the add-on, where the symbols are weak
    return SLSWindowSetShadowProperties && SLSGetWindowShadowAndRimParameters;
#pragma clang diagnostic pop
}

static struct sunbeam_shadow *sunbeam_shadow_find(uint32_t wid, int owner)
{
    for (int i = 0; i < SUNBEAM_SHADOWS; ++i) {
        if (sunbeam_shadows[i].wid == wid && sunbeam_shadows[i].owner == owner) return &sunbeam_shadows[i];
    }
    return NULL;
}

static bool sunbeam_look_sane(struct sunbeam_look look)
{
    return isfinite(look.radius) && look.radius >= 0 && look.radius <= 200
        && isfinite(look.density) && look.density >= 0 && look.density <= 1
        && isfinite(look.rim_density) && look.rim_density >= 0 && look.rim_density <= 1
        && isfinite(look.offset) && fabsf(look.offset) <= 200;
}

static struct sunbeam_look sunbeam_look_mix(struct sunbeam_look from, struct sunbeam_look to, float weight)
{
    struct sunbeam_look mixed = {
        from.radius + (to.radius - from.radius) * weight,
        from.density + (to.density - from.density) * weight,
        from.rim_density + (to.rim_density - from.rim_density) * weight,
        from.offset + (to.offset - from.offset) * weight,
    };
    return mixed;
}

static void sunbeam_shadow_number(CFMutableDictionaryRef dict, const char *name, const char *suffix, bool whole, double value)
{
    char key[96];
    snprintf(key, sizeof(key), "com.apple.WindowShadow%s%s", name, suffix);
    CFStringRef string = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    int rounded = (int)lround(value);
    CFNumberRef number = whole ? CFNumberCreate(NULL, kCFNumberIntType, &rounded) : CFNumberCreate(NULL, kCFNumberDoubleType, &value);
    CFDictionarySetValue(dict, string, number);
    CFRelease(number);
    CFRelease(string);
}

/// One look's keys, with the rim as AppKit sets it for a titled window. `suffix` is "Active" or "Inactive".
static void sunbeam_shadow_slot(CFMutableDictionaryRef dict, const char *suffix, struct sunbeam_look look)
{
    sunbeam_shadow_number(dict, "Radius", suffix, true, look.radius);
    sunbeam_shadow_number(dict, "Density", suffix, false, look.density);
    sunbeam_shadow_number(dict, "VerticalOffset", suffix, true, look.offset);
    sunbeam_shadow_number(dict, "RimDensity", suffix, false, look.rim_density);
    sunbeam_shadow_number(dict, "RimRadius", suffix, true, 3);
    sunbeam_shadow_number(dict, "RimStyleHard", suffix, true, 0);
    sunbeam_shadow_number(dict, "RimStyleWhite", suffix, true, 0);
    sunbeam_shadow_number(dict, "InnerRimDensity", suffix, false, 0.1);
    sunbeam_shadow_number(dict, "InnerRimRadius", suffix, true, 2);
    sunbeam_shadow_number(dict, "InnerRimStyleWhite", suffix, true, 1);
}

/// Writes a window's two looks: the whole dictionary AppKit writes, as the window server may take a
/// partial one for the whole.
static CGError sunbeam_shadow_write(uint32_t wid, struct sunbeam_look inactive, struct sunbeam_look active)
{
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    sunbeam_shadow_slot(dict, "Inactive", inactive);
    sunbeam_shadow_slot(dict, "Active", active);
    sunbeam_shadow_number(dict, "ContentAware", "Active", true, 1);
    sunbeam_shadow_number(dict, "ContentAware", "Inctive", true, 1);   // AppKit's own spelling of the key
    CGError error = SLSWindowSetShadowProperties(wid, dict);
    CFRelease(dict);
    return error;
}

/// Whether a window has the standard looks the request describes, as far as the window server tells:
/// its shadow parameters as read (`SLSGetWindowShadowAndRimParameters` answers with the active look's
/// density and offset) fall between the two looks. A window with another kind of shadow — a panel's, none —
/// is left alone, rather than given a titled window's.
static bool sunbeam_shadow_standard(int cid, uint32_t wid, struct sunbeam_look inactive, struct sunbeam_look active)
{
    float deviation = 0, density = 0;
    int offset_x = 0, offset_y = 0;
    unsigned int flags = 0;
    if (SLSGetWindowShadowAndRimParameters(cid, wid, &deviation, &density, &offset_x, &offset_y, &flags) != kCGErrorSuccess) return false;
    float low = fminf(inactive.density, active.density) - 0.02f, high = fmaxf(inactive.density, active.density) + 0.02f;
    int near = (int)lroundf(fminf(inactive.offset, active.offset)) - 1, far = (int)lroundf(fmaxf(inactive.offset, active.offset)) + 1;
    return deviation > 0 && density >= low && density <= high && offset_y >= near && offset_y <= far;
}

/// The request (44 bytes after the opcode): the window; two weights, for the inactive look and the
/// active one; then the window's standard inactive and active looks (radius, density, rim density,
/// offset, as floats). Each look is set the given way from the standard inactive look to the standard
/// active one: 0 and 1 are the window's own; 1 and 1 both the active look, which the switch to it then
/// doesn't change; 0 and 0 both the inactive. Status 1 for a request that makes no sense, 8 when the
/// window is gone or the window server won't, 9 for a window whose shadow isn't the standard one.
static uint8_t sunbeam_shadow_set(const char *bytes)
{
    uint32_t wid;
    float weights[2], values[8];
    memcpy(&wid, bytes, 4); memcpy(weights, bytes + 4, 8); memcpy(values, bytes + 12, 32);
    struct sunbeam_look inactive = { values[0], values[1], values[2], values[3] };
    struct sunbeam_look active = { values[4], values[5], values[6], values[7] };
    for (int i = 0; i < 2; ++i) if (!isfinite(weights[i]) || weights[i] < 0 || weights[i] > 1) return 1;
    if (!wid || !sunbeam_look_sane(inactive) || !sunbeam_look_sane(active)) return 1;
    if (!sunbeam_shadow_available()) return 8;
    int cid = SLSMainConnectionID(), owner = 0;
    if (SLSGetWindowOwner(cid, wid, &owner) != kCGErrorSuccess) return 8;
    struct sunbeam_shadow *shadow = sunbeam_shadow_find(wid, owner);
    if (!shadow) {
        if (!sunbeam_shadow_standard(cid, wid, inactive, active)) return 9;
        for (int i = 0; i < SUNBEAM_SHADOWS && !shadow; ++i) if (!sunbeam_shadows[i].wid) shadow = &sunbeam_shadows[i];
        if (!shadow) {
            shadow = &sunbeam_shadows[sunbeam_shadow_next];
            sunbeam_shadow_next = (sunbeam_shadow_next + 1) % SUNBEAM_SHADOWS;
        }
        struct sunbeam_shadow seen = { .wid = wid, .owner = owner };
        *shadow = seen;
    }
    shadow->inactive = inactive;
    shadow->active = active;
    if (sunbeam_shadow_write(wid, sunbeam_look_mix(inactive, active, weights[0]),
                             sunbeam_look_mix(inactive, active, weights[1])) != kCGErrorSuccess) return 8;
    shadow->altered = weights[0] != 0 || weights[1] != 1;
    return 0;
}

/// A window put back under the canvas with other looks in force (a flight cut short) gets its standard
/// ones back, where that shows nothing. An entered window isn't put back, and keeps both looks active
/// until the canvas, with the window key, asks for its standard ones.
static void sunbeam_shadow_reset(uint32_t wid, int owner)
{
    struct sunbeam_shadow *shadow = sunbeam_shadow_find(wid, owner);
    if (!shadow || !shadow->altered || !sunbeam_shadow_available()) return;
    if (sunbeam_shadow_write(wid, shadow->inactive, shadow->active) == kCGErrorSuccess) shadow->altered = false;
}

// MARK: Alpha requests

static bool sunbeam_alpha_available(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"   // real checks in the add-on, where the symbols are weak
    return SLSSetWindowAlpha;
#pragma clang diagnostic pop
}

/// The window's own alpha back, if the canvas changed it.
static void sunbeam_alpha_reset(struct sunbeam_saved *saved)
{
    if (!saved->alpha_altered || !sunbeam_alpha_available()) return;
    if (sunbeam_owner_matches(saved)) SLSSetWindowAlpha(SLSMainConnectionID(), saved->wid, saved->alpha);
    saved->alpha_altered = false;
}

/// The request: a count, then that many windows, each its ID and an alpha from 0 to 1 (8 bytes).
/// Only windows this lease holds are changed; others are passed over (one closed or released since
/// the canvas asked). Status 1 for a request that makes no sense, 10 when SkyLight has no alpha call.
static uint8_t sunbeam_alpha_set(const char *bytes, int length, struct sunbeam_saved *saved, int count)
{
    int n = (uint8_t)bytes[0];
    if (length != 1 + n * 8 || n > SUNBEAM_LIMIT) return 1;
    for (int k = 0; k < n; ++k) {
        float alpha;
        memcpy(&alpha, bytes + 5 + k * 8, 4);
        if (!isfinite(alpha) || alpha < 0 || alpha > 1) return 1;
    }
    if (!sunbeam_alpha_available()) return 10;
    int cid = SLSMainConnectionID();
    for (int k = 0; k < n; ++k) {
        uint32_t wid; float alpha;
        memcpy(&wid, bytes + 1 + k * 8, 4); memcpy(&alpha, bytes + 5 + k * 8, 4);
        struct sunbeam_saved *entry = NULL;
        for (int i = 0; i < count && !entry; ++i) if (saved[i].wid == wid) entry = &saved[i];
        if (!entry || !sunbeam_owner_matches(entry)) continue;
        if (!entry->alpha_altered) {
            float own = 1;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"
            if (!SLSGetWindowAlpha || SLSGetWindowAlpha(cid, wid, &own) != kCGErrorSuccess || !isfinite(own)) own = 1;
#pragma clang diagnostic pop
            entry->alpha = own;
        }
        if (SLSSetWindowAlpha(cid, wid, alpha * entry->alpha) == kCGErrorSuccess) {
            entry->alpha_altered = alpha != 1;
        }
    }
    return 0;
}

// MARK: Shapes

/// A window the canvas gave rounded corners: put back to its full shape when it is released with the
/// rest (the lease's end) or the canvas asks for a radius of 0.
struct sunbeam_shaped { uint32_t wid; int owner; };
static struct sunbeam_shaped sunbeam_shapes[SUNBEAM_SHAPES];

static bool sunbeam_shape_available(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"   // real checks in the add-on, where the symbols are weak
    return CGSNewRegionWithRect && CGSNewRegionWithRectList && SLSSetWindowShape;
#pragma clang diagnostic pop
}

/// The rectangles of a `width` by `height` rounded rectangle with corners of `radius` (whole points, no
/// more than half the shorter side), rows one point tall at the corners and one rectangle between:
/// `2 * radius + 1` of them, into `rects`, which holds `2 * SUNBEAM_SHAPE_RADIUS + 1`. Returns how many.
static int sunbeam_rounded_rects(double width, double height, int radius, CGRect *rects)
{
    if (radius > SUNBEAM_SHAPE_RADIUS) radius = SUNBEAM_SHAPE_RADIUS;
    if (radius * 2 > (int)fmin(width, height)) radius = (int)fmin(width, height) / 2;
    if (radius <= 0) { rects[0] = CGRectMake(0, 0, width, height); return 1; }
    int n = 0;
    for (int y = 0; y < radius; ++y) {
        // The row's middle, measured from the corner circle's centre: how far in the circle's edge is there.
        double d = radius - (y + 0.5);
        double inset = radius - sqrt((double)radius * radius - d * d);
        rects[n++] = CGRectMake(inset, y, width - 2 * inset, 1);
    }
    rects[n++] = CGRectMake(0, radius, width, height - 2 * radius);
    for (int y = radius - 1; y >= 0; --y) {
        double d = radius - (y + 0.5);
        double inset = radius - sqrt((double)radius * radius - d * d);
        rects[n++] = CGRectMake(inset, height - 1 - y, width - 2 * inset, 1);
    }
    return n;
}

/// Sets `wid`'s shape to its bounds with corners of `radius` points (0: its full bounds again), at the
/// native place it has. False when the window server refused or won't describe the window.
static bool sunbeam_shape_apply(uint32_t wid, int radius)
{
    int cid = SLSMainConnectionID();
    CGRect bounds;
    if (SLSGetWindowBounds(cid, wid, &bounds) != kCGErrorSuccess) return false;
    double width = floor(bounds.size.width), height = floor(bounds.size.height);
    if (width < 1 || height < 1) return false;
    CGRect rects[2 * SUNBEAM_SHAPE_RADIUS + 1];
    int n = sunbeam_rounded_rects(width, height, radius, rects);
    CFTypeRef region = NULL;
    CGError made = n == 1 ? CGSNewRegionWithRect(&rects[0], &region) : CGSNewRegionWithRectList(rects, n, &region);
    if (made != kCGErrorSuccess || !region) return false;
    CGError set = SLSSetWindowShape(cid, wid, (float)bounds.origin.x, (float)bounds.origin.y, region);
    CFRelease(region);
    return set == kCGErrorSuccess;
}

static struct sunbeam_shaped *sunbeam_shape_find(uint32_t wid)
{
    for (int i = 0; i < SUNBEAM_SHAPES; ++i) if (sunbeam_shapes[i].wid == wid) return &sunbeam_shapes[i];
    return NULL;
}

/// The window's full shape back, if the canvas rounded it and the window is still the one it was.
static void sunbeam_shape_reset(uint32_t wid)
{
    struct sunbeam_shaped *shaped = sunbeam_shape_find(wid);
    if (!shaped) return;
    int owner = 0;
    if (sunbeam_shape_available() && SLSGetWindowOwner(SLSMainConnectionID(), wid, &owner) == kCGErrorSuccess && owner == shaped->owner) {
        sunbeam_shape_apply(wid, 0);
    }
    shaped->wid = 0;
}

/// The request: a window and a corner radius in its own points (8 bytes). The window needn't be leased:
/// a tile stays on show while the canvas is away, when nothing is. Status 1 for a request that makes no
/// sense, 11 when SkyLight has no shape calls here, 12 when the window won't be described or the window
/// server refused the shape. A radius over `SUNBEAM_SHAPE_RADIUS`, or over half the shorter side, is
/// taken as that.
static uint8_t sunbeam_shape_set(const char *bytes, int length)
{
    if (length != 8) return 1;
    uint32_t wid; float radius;
    memcpy(&wid, bytes, 4); memcpy(&radius, bytes + 4, 4);
    if (!wid || !isfinite(radius) || radius < 0) return 1;
    if (!sunbeam_shape_available()) return 11;
    int owner = 0;
    if (SLSGetWindowOwner(SLSMainConnectionID(), wid, &owner) != kCGErrorSuccess) return 12;
    int whole = (int)lround(radius);
    if (whole == 0) { sunbeam_shape_reset(wid); return 0; }
    if (!sunbeam_shape_apply(wid, whole)) return 12;
    struct sunbeam_shaped *shaped = sunbeam_shape_find(wid);
    if (!shaped) shaped = sunbeam_shape_find(0);
    if (!shaped) shaped = &sunbeam_shapes[0];   // the oldest slot is reused: nothing is lost but a reset
    shaped->wid = wid;
    shaped->owner = owner;
    return 0;
}

// MARK: Release

/// Puts a window back as the add-on found it: its place in the stacking order, its transform, and
/// its level. The place is above the window that was under it when it was taken, as long as that
/// one is still on screen at the same level and is neither the canvas (a window taken from between
/// the backdrop and the canvas, the one just left, goes under the backdrop with the rest) nor one of
/// `skip`, the window being entered and the ones kept with it, which are above the canvas by now
/// (ordered next to one of them, a window would be on show too). Otherwise it goes under
/// `*anchor`: the backdrop, or the window put there just before, so a run of them keeps its order.
/// Ordering against a window that is gone, on another Space, at another level or the canvas itself
/// left the window on top of everything, in front of the one being entered.
///
/// The place comes before the transform: under the backdrop (or next to a window that is), the
/// jump back to native size shows nothing. Without a transaction the two are separate updates, and
/// a window that first jumped and then went under flashed full-size over the canvas.
///
/// Its own level comes first of all: a leased window sits at the canvas's level, its neighbours at
/// its own, and an order against a window at another level does nothing. Set directly (no transaction)
/// the window lands at the front of its level, which is under the backdrop as long as the backdrop is
/// still at the canvas's level — so, one by one, the windows go back before the canvas comes down.
///
/// A window that isn't on screen — minimized while it was leased (the canvas keeps it on show through
/// the Dock's animation and hands it back once it has gone), or its app hidden — gets its level and
/// transform back but no place in the order (sunlight-12): from the Dock's connection, ordering a
/// minimized window brings it back on screen behind its app's back, and the canvas saw it come back
/// half a second after every minimize. Its level and transform are kept by the Dock through the
/// minimize and the restore, so it comes back as a window of its own level, at native size.
///
/// `settle` false leaves the transform (and shadow) for `sunbeam_settle` after the commit (sunlight-14):
/// in a transaction that also changes levels the window server may take a window's level change after
/// its order, which lands it at the front of the normal level, over the canvas, for a frame before the
/// orders are put right. At the canvas's transform it shows there only where the canvas already drew
/// it (a window off to the side, nowhere); at native size it flashed full-size over the canvas, under
/// the window being entered, on quick ⌘Tab switches.
static void sunbeam_restore(CFTypeRef transaction, struct sunbeam_saved *saved, uint32_t backdrop, uint32_t overlay,
                            uint32_t *anchor, const uint32_t *skip, int skip_count, bool settle)
{
    if (!sunbeam_owner_matches(saved)) return; // a closed window ID must not target a different app
    int cid = SLSMainConnectionID();
    sunbeam_level(transaction, cid, saved->wid, saved->level, NULL);
    if (sunbeam_on_screen(saved->wid, NULL)) {
        int below_level = 0;
        bool skipped = false;
        for (int i = 0; i < skip_count; ++i) if (saved->below == skip[i]) skipped = true;
        if (saved->below && saved->below != backdrop && saved->below != overlay && !skipped
            && sunbeam_on_screen(saved->below, &below_level) && below_level == saved->level) {
            sunbeam_order(transaction, cid, saved->wid, 1, saved->below);
        } else if (anchor && *anchor && sunbeam_on_screen(*anchor, NULL)) {
            if (sunbeam_order(transaction, cid, saved->wid, -1, *anchor) == kCGErrorSuccess) *anchor = saved->wid;
        }
    }
    if (settle) {
        sunbeam_transform(transaction, cid, saved->wid, saved->transform);
        sunbeam_shadow_reset(saved->wid, saved->owner);
        sunbeam_alpha_reset(saved);
    }
}

/// Whether `wid` is on screen above `backdrop` (the list is front to back).
static bool sunbeam_is_above(uint32_t wid, uint32_t backdrop)
{
    bool above = false, seen = false;
    CFArrayRef list = sunbeam_window_list(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list) && !seen; ++i) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(list, i);
        CFNumberRef number = CFDictionaryGetValue(entry, kCGWindowNumber);
        uint32_t candidate = 0;
        if (number) CFNumberGetValue(number, kCFNumberSInt32Type, &candidate);
        if (candidate == wid) { above = true; seen = true; }
        else if (candidate == backdrop) seen = true;
    }
    if (list) CFRelease(list);
    return above;
}

/// The rest of `sunbeam_restore` for a window put back without its transform: directly, once its level
/// and place are final, so the jump to native size happens under the backdrop. `backdrop`: checked first
/// (sunlight-20): a window the window server left above it after the transaction and the orders redone
/// (seen on 27.2 for a window put back at a handoff, whatever the order of levels and orders asked for)
/// is ordered under it once more, and read back; one that stays above is left at the canvas's transform
/// (a small picture of itself, as it was) rather than shown full-size over the entered window.
static bool sunbeam_moves_in_transaction(void);
static void sunbeam_settle(struct sunbeam_saved *saved, uint32_t backdrop, double top)
{
    if (!sunbeam_owner_matches(saved)) return;
    int cid = SLSMainConnectionID();
    if (backdrop && sunbeam_on_screen(saved->wid, NULL) && sunbeam_is_above(saved->wid, backdrop)) SLSOrderWindow(cid, saved->wid, -1, backdrop);
#ifndef SUNBEAM_SETTLE_NOW
    // Native size where the canvas draws it (sunlight-25), in one transaction with the native move
    // there: a window put back at a 1:1 seam is one the canvas had out of view (every window in view
    // is kept on show), so it is off the screen there, and no order the window server has or hasn't
    // taken yet can show it full-size. Its native place was wherever it was last used, which the
    // canvas never reads back for a window it owns the place of; raised by name it goes over to its
    // canvas place. The harness keeps the old transform, which its checks read back.
    CGAffineTransform t;
    // Only for a window drawn 1:1 (a seam's put-back): one released while the canvas is zoomed out
    // (the lease's end, the canvas going dormant) goes back where the add-on found it, not to the
    // top-left of its thumbnail at full size.
    if (sunbeam_moves_in_transaction() && SLSGetWindowTransform(cid, saved->wid, &t) == kCGErrorSuccess
        && fabs(t.a - 1) < 1e-3 && fabs(t.d - 1) < 1e-3) {
        CGPoint drawn = CGPointMake(-t.tx / t.a, -t.ty / t.a);
        CFTypeRef transaction = sunbeam_transaction_begin(cid);
        if (transaction) {
            SLSTransactionMoveWindowWithGroup(transaction, saved->wid, sunbeam_native_at(drawn, top));
            sunbeam_transform(transaction, cid, saved->wid, CGAffineTransformMakeTranslation(-drawn.x, -drawn.y));
            if (sunbeam_transaction_end(transaction)) {
                sunbeam_shadow_reset(saved->wid, saved->owner);
                sunbeam_alpha_reset(saved);
                return;
            }
        }
    }
#endif
    sunbeam_transform(NULL, cid, saved->wid, saved->transform);
    sunbeam_shadow_reset(saved->wid, saved->owner);
    sunbeam_alpha_reset(saved);
}

/// Native sizes a frame later (sunlight-23). The window server takes an order a cycle after a
/// transform made right behind it: a window put back got its native size while the window server
/// still had it above the backdrop, whatever the order calls before it, and showed there full-size
/// for one frame (sunlight-20's read-back saw the order as taken and settled all the same). Its
/// native size now comes `SUNBEAM_SETTLE_DELAY` after the orders, from the settle queue, when the
/// order is in force. A lease taking the window before then restores the pending native transform
/// itself, so a return within the delay leaves nothing half done. The harness settles at once
/// (`SUNBEAM_SETTLE_NOW`).
struct sunbeam_pending {
    uint32_t wid;
    int owner;
    CGAffineTransform transform;
    uint32_t backdrop;
    double due, top;
};
#define SUNBEAM_SETTLE_DELAY 0.03
static struct sunbeam_pending sunbeam_pending_list[SUNBEAM_LIMIT * SUNBEAM_SESSIONS];
static int sunbeam_pending_count;
static dispatch_queue_t sunbeam_settle_queue;

/// The pending settles that are due, under the lock.
static void sunbeam_place_due(void);
static void sunbeam_settle_due(void)
{
    pthread_mutex_lock(&sunbeam_lock);
    sunbeam_place_due();
    double now = sunbeam_now();
    for (int i = 0; i < sunbeam_pending_count;) {
        struct sunbeam_pending *p = &sunbeam_pending_list[i];
        if (p->due > now + 0.001) { ++i; continue; }
        struct sunbeam_saved saved = { .wid = p->wid, .owner = p->owner, .transform = p->transform };
        sunbeam_settle(&saved, p->backdrop, p->top);
        memmove(p, p + 1, (sunbeam_pending_count - i - 1) * sizeof(*p));
        --sunbeam_pending_count;
    }
    pthread_mutex_unlock(&sunbeam_lock);
}

/// Queues the window's native size for `SUNBEAM_SETTLE_DELAY` from now. Under the lock.
static void sunbeam_settle_later(struct sunbeam_saved *saved, uint32_t backdrop, double top)
{
#ifdef SUNBEAM_SETTLE_NOW
    sunbeam_settle(saved, backdrop, top);
#else
    if (!sunbeam_owner_matches(saved)) return;
    int index = -1;
    for (int i = 0; i < sunbeam_pending_count; ++i) if (sunbeam_pending_list[i].wid == saved->wid) index = i;
    if (index < 0) {
        if (sunbeam_pending_count >= (int)(sizeof(sunbeam_pending_list) / sizeof(*sunbeam_pending_list))) { sunbeam_settle(saved, backdrop, top); return; }
        index = sunbeam_pending_count++;
    }
    sunbeam_pending_list[index] = (struct sunbeam_pending){ saved->wid, saved->owner, saved->transform, backdrop, sunbeam_now() + SUNBEAM_SETTLE_DELAY, top };
    if (!sunbeam_settle_queue) sunbeam_settle_queue = dispatch_queue_create("com.spacefarm.sunlight.settle", NULL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SUNBEAM_SETTLE_DELAY * NSEC_PER_SEC) + 2 * NSEC_PER_MSEC),
                   sunbeam_settle_queue, ^{ sunbeam_settle_due(); });
#endif
}

/// A window moved natively in a handoff's transaction, checked a frame later: one not at its point
/// (the move not taken, or clamped by the app) is moved there again with its transform in one
/// transaction, so the window is drawn where the canvas drew it and sits there natively too. A window
/// leased again meanwhile (its transform the canvas's, not 1:1) is the canvas's to place.
struct sunbeam_place { uint32_t wid; int owner; CGPoint point, drawn; double due; };
static struct sunbeam_place sunbeam_place_list[SUNBEAM_LIMIT * SUNBEAM_SESSIONS];
static int sunbeam_place_count;

static bool sunbeam_moves_in_transaction(void);
static void sunbeam_place_due(void)
{
    int cid = SLSMainConnectionID();
    double now = sunbeam_now();
    for (int i = 0; i < sunbeam_place_count;) {
        struct sunbeam_place *p = &sunbeam_place_list[i];
        if (p->due > now + 0.001) { ++i; continue; }
        int owner = 0;
        CGRect bounds;
        CGAffineTransform t;
        if (SLSGetWindowOwner(cid, p->wid, &owner) == kCGErrorSuccess && owner == p->owner
            && SLSGetWindowBounds(cid, p->wid, &bounds) == kCGErrorSuccess
            && SLSGetWindowTransform(cid, p->wid, &t) == kCGErrorSuccess
            && fabs(t.a - 1) < 1e-3 && fabs(t.d - 1) < 1e-3
            && (fabs(bounds.origin.x - p->point.x) > 0.5 || fabs(bounds.origin.y - p->point.y) > 0.5)) {
            CFTypeRef transaction = sunbeam_moves_in_transaction() ? sunbeam_transaction_begin(cid) : NULL;
            if (transaction) {
                SLSTransactionMoveWindowWithGroup(transaction, p->wid, p->point);
                sunbeam_transform(transaction, cid, p->wid, CGAffineTransformMakeTranslation(-p->drawn.x, -p->drawn.y));
                sunbeam_transaction_end(transaction);
            }
        }
        memmove(p, p + 1, (sunbeam_place_count - i - 1) * sizeof(*p));
        --sunbeam_place_count;
    }
}

/// Queues the check above for `SUNBEAM_SETTLE_DELAY` from now. Under the lock.
static void sunbeam_place_later(uint32_t wid, int owner, CGPoint point, CGPoint drawn)
{
#ifdef SUNBEAM_SETTLE_NOW
    (void)wid; (void)owner; (void)point; (void)drawn;
#else
    int index = -1;
    for (int i = 0; i < sunbeam_place_count; ++i) if (sunbeam_place_list[i].wid == wid) index = i;
    if (index < 0) {
        if (sunbeam_place_count >= (int)(sizeof(sunbeam_place_list) / sizeof(*sunbeam_place_list))) return;
        index = sunbeam_place_count++;
    }
    sunbeam_place_list[index] = (struct sunbeam_place){ wid, owner, point, drawn, sunbeam_now() + SUNBEAM_SETTLE_DELAY };
    if (!sunbeam_settle_queue) sunbeam_settle_queue = dispatch_queue_create("com.spacefarm.sunlight.settle", NULL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SUNBEAM_SETTLE_DELAY * NSEC_PER_SEC) + 2 * NSEC_PER_MSEC),
                   sunbeam_settle_queue, ^{ sunbeam_settle_due(); });
#endif
}

static void sunbeam_place_drop(uint32_t wid)
{
    for (int i = 0; i < sunbeam_place_count;) {
        if (sunbeam_place_list[i].wid != wid) { ++i; continue; }
        memmove(&sunbeam_place_list[i], &sunbeam_place_list[i + 1], (sunbeam_place_count - i - 1) * sizeof(*sunbeam_place_list));
        --sunbeam_place_count;
    }
}

/// The windows a canvas lifted to the front level (sunlight-41): its entered and kept windows at a
/// handoff, the front app's windows at a release. Each remembers its own level and which canvas lifted
/// it (by the canvas's overlay), so only that canvas's next frame puts back the ones it doesn't take:
/// another display's canvas, on its own lease, leaves them alone, and nothing has to list every window
/// on screen to find them. Under the lock.
struct sunbeam_lifted { uint32_t wid; int owner, level; uint32_t canvas; };
static struct sunbeam_lifted sunbeam_lifted_list[SUNBEAM_LIMIT * SUNBEAM_SESSIONS];
static int sunbeam_lifted_count;

static void sunbeam_lifted_add(uint32_t wid, int level, uint32_t canvas)
{
    int cid = SLSMainConnectionID(), owner = 0;
    if (!wid || SLSGetWindowOwner(cid, wid, &owner) != kCGErrorSuccess) return;
    for (int i = 0; i < sunbeam_lifted_count; ++i) {
        if (sunbeam_lifted_list[i].wid != wid) continue;
        // Lifted again: its own level stays the first one seen, the canvas is the latest.
        if (sunbeam_lifted_list[i].owner != owner) sunbeam_lifted_list[i].level = level;
        sunbeam_lifted_list[i].owner = owner;
        sunbeam_lifted_list[i].canvas = canvas;
        return;
    }
    if (sunbeam_lifted_count >= (int)(sizeof(sunbeam_lifted_list) / sizeof(*sunbeam_lifted_list))) return;
    if (level == SUNBEAM_LEVEL || level == SUNBEAM_FRONT || level == SUNBEAM_PINNED) level = 0;
    sunbeam_lifted_list[sunbeam_lifted_count++] = (struct sunbeam_lifted){ wid, owner, level, canvas };
}

/// A window a lease takes: its own level, if a canvas lifted it, and it is off the list. -1 otherwise.
static int sunbeam_lifted_take(uint32_t wid)
{
    for (int i = 0; i < sunbeam_lifted_count; ++i) {
        if (sunbeam_lifted_list[i].wid != wid) continue;
        int level = sunbeam_lifted_list[i].level;
        memmove(&sunbeam_lifted_list[i], &sunbeam_lifted_list[i + 1], (sunbeam_lifted_count - i - 1) * sizeof(*sunbeam_lifted_list));
        --sunbeam_lifted_count;
        return level;
    }
    return -1;
}

/// A queued placement check (`sunbeam_place_later`) dropped: the window is leased again, and where it
/// goes is the canvas's to say. Defined with the checks.
static void sunbeam_place_drop(uint32_t wid);

/// A lease taking a window with a settle pending takes over its native transform (the one the settle
/// would have given it) and drops the settle. Under the lock. (See also `sunbeam_place_drop`.)
static bool sunbeam_pending_take(uint32_t wid, CGAffineTransform *transform)
{
    for (int i = 0; i < sunbeam_pending_count; ++i) {
        if (sunbeam_pending_list[i].wid != wid) continue;
        *transform = sunbeam_pending_list[i].transform;
        memmove(&sunbeam_pending_list[i], &sunbeam_pending_list[i + 1], (sunbeam_pending_count - i - 1) * sizeof(*sunbeam_pending_list));
        --sunbeam_pending_count;
        return true;
    }
    return false;
}

/// Where a window goes back when released: the nearest window under it at its own level, skipping
/// the canvas's own windows. 0 when there is none; `sunbeam_restore` then uses the backdrop.
static uint32_t sunbeam_below(uint32_t wid, int level, uint32_t backdrop, uint32_t overlay)
{
    uint32_t result = 0;
    CFArrayRef list = sunbeam_window_list(kCGWindowListOptionOnScreenBelowWindow, wid);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list) && !result; ++i) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(list, i);
        CFNumberRef number = CFDictionaryGetValue(entry, kCGWindowNumber);
        CFNumberRef layer = CFDictionaryGetValue(entry, kCGWindowLayer);
        uint32_t candidate = 0;
        int candidate_level = 0;
        if (number) CFNumberGetValue(number, kCFNumberSInt32Type, &candidate);
        if (layer) CFNumberGetValue(layer, kCFNumberIntType, &candidate_level);
        if (candidate && candidate != backdrop && candidate != overlay && candidate_level == level) result = candidate;
    }
    if (list) CFRelease(list);
    return result;
}

/// The lowest window on screen at the normal level owned by `pid`, skipping the canvas's own and the
/// leased ones: where the canvas goes back under when an app took the front while it was up (the
/// app's windows were raised to the front of the level, and the canvas, coming down to it, would land
/// above them). 0 when there is none.
static uint32_t sunbeam_lowest_of(int pid, uint32_t backdrop, uint32_t overlay, const struct sunbeam_saved *saved, int count)
{
    uint32_t result = 0;
    if (!pid) return 0;
    CFArrayRef list = sunbeam_window_list(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); ++i) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(list, i);
        CFNumberRef number = CFDictionaryGetValue(entry, kCGWindowNumber);
        CFNumberRef layer = CFDictionaryGetValue(entry, kCGWindowLayer);
        CFNumberRef owner = CFDictionaryGetValue(entry, kCGWindowOwnerPID);
        uint32_t candidate = 0;
        int candidate_level = -1, candidate_pid = 0;
        if (number) CFNumberGetValue(number, kCFNumberSInt32Type, &candidate);
        if (layer) CFNumberGetValue(layer, kCFNumberIntType, &candidate_level);
        if (owner) CFNumberGetValue(owner, kCFNumberIntType, &candidate_pid);
        if (!candidate || candidate_pid != pid || candidate_level != 0 || candidate == backdrop || candidate == overlay) continue;
        bool leased = false;
        for (int j = 0; j < count; ++j) if (saved[j].wid == candidate) leased = true;
        if (!leased) result = candidate;   // the list is front to back: the last match is the lowest
    }
    if (list) CFRelease(list);
    return result;
}

/// The canvas's two windows down to the normal level, backdrop first (so it lands under the overlay,
/// each set putting the window at the front).
static void sunbeam_canvas_down(CFTypeRef transaction, int cid, uint32_t backdrop, uint32_t overlay, bool *changed)
{
    if (backdrop) sunbeam_level(transaction, cid, backdrop, 0, changed);
    if (overlay) sunbeam_level(transaction, cid, overlay, 0, changed);
}

/// With the canvas down at the normal level: if an app has the front (`above_pid`), the canvas goes
/// under that app's windows, where it would have been had it never been lifted.
static void sunbeam_canvas_tuck(CFTypeRef transaction, int cid, uint32_t backdrop, uint32_t overlay, int above_pid,
                                const struct sunbeam_saved *saved, int count)
{
    uint32_t lowest = backdrop && overlay ? sunbeam_lowest_of(above_pid, backdrop, overlay, saved, count) : 0;
    if (!lowest) return;
    sunbeam_order(transaction, cid, backdrop, -1, lowest);
    sunbeam_order(transaction, cid, overlay, 1, backdrop);
}

/// Every leased window back where it was, the backdrop first up under the canvas when both are
/// known, so they go back out of sight: a lease that ended with the canvas still up (a stall, a
/// bad frame) is replaced by a new one within moments, and the windows would otherwise sit
/// full-size over the canvas until then.
///
/// Then the canvas itself comes down to the normal level (sunlight-11). In a transaction the levels go
/// first, since an order against a window at another level does nothing, and everything lands at once.
/// One call at a time, the windows go back first: each lands at the front of the normal level, which is
/// under the backdrop only while the backdrop is still up at the canvas's. `above_pid`: the app that
/// has the front, if one took it (the canvas deactivating for it); the canvas goes under its windows.
/// Which of the leased windows are the front app's (`above_pid`) and on screen: on a release for an app
/// that took the front (sunlight-15, see `sunbeam_release_all`) they go above the canvas, not under it.
static void sunbeam_front_windows(int pid, const struct sunbeam_saved *saved, int count, bool *front)
{
    for (int i = 0; i < count; ++i) front[i] = false;
    if (!pid) return;
    CFArrayRef list = sunbeam_window_list(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); ++i) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(list, i);
        CFNumberRef number = CFDictionaryGetValue(entry, kCGWindowNumber);
        CFNumberRef owner = CFDictionaryGetValue(entry, kCGWindowOwnerPID);
        uint32_t candidate = 0;
        int candidate_pid = 0;
        if (number) CFNumberGetValue(number, kCFNumberSInt32Type, &candidate);
        if (owner) CFNumberGetValue(owner, kCFNumberIntType, &candidate_pid);
        if (!candidate || candidate_pid != pid) continue;
        for (int j = 0; j < count; ++j) if (saved[j].wid == candidate) front[j] = true;
    }
    if (list) CFRelease(list);
}

/// A leased window of the app that took the front, put back: its level, and its place straight above
/// the overlay (top first, so the canvas's order holds among them), where the app's windows are once
/// the canvas has stepped aside. Put back under the backdrop with the rest and then uncovered by the
/// tuck, it was under the backdrop for a frame when the window server took the transaction's orders
/// before its levels: the window the user had just clicked gone for a frame, the wallpaper in its place.
static void sunbeam_restore_in_front(CFTypeRef transaction, struct sunbeam_saved *saved, uint32_t overlay)
{
    if (!sunbeam_owner_matches(saved)) return;
    int cid = SLSMainConnectionID();
    sunbeam_lifted_add(saved->wid, saved->level, overlay);
    sunbeam_level(transaction, cid, saved->wid, SUNBEAM_FRONT, NULL);
    if (sunbeam_on_screen(saved->wid, NULL)) sunbeam_order(transaction, cid, saved->wid, 1, overlay);
}

/// Every on-screen window of `pid` at the normal level that isn't leased, to the front level (sunlight-27):
/// an app that took the front shows all of its windows, the ones the canvas never took included.
static void sunbeam_lift_others_of(int pid, uint32_t backdrop, uint32_t overlay, const struct sunbeam_saved *saved, int count)
{
    if (!pid) return;
    int cid = SLSMainConnectionID();
    CFArrayRef list = sunbeam_window_list(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); ++i) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(list, i);
        CFNumberRef number = CFDictionaryGetValue(entry, kCGWindowNumber);
        CFNumberRef layer = CFDictionaryGetValue(entry, kCGWindowLayer);
        CFNumberRef owner = CFDictionaryGetValue(entry, kCGWindowOwnerPID);
        uint32_t candidate = 0;
        int candidate_level = -1, candidate_pid = 0;
        if (number) CFNumberGetValue(number, kCFNumberSInt32Type, &candidate);
        if (layer) CFNumberGetValue(layer, kCFNumberIntType, &candidate_level);
        if (owner) CFNumberGetValue(owner, kCFNumberIntType, &candidate_pid);
        if (!candidate || candidate_pid != pid || candidate_level != 0 || candidate == backdrop || candidate == overlay) continue;
        bool leased = false;
        for (int j = 0; j < count; ++j) if (saved[j].wid == candidate) leased = true;
        if (leased) continue;
        sunbeam_lifted_add(candidate, 0, overlay);
        SLSSetWindowLevel(cid, candidate, SUNBEAM_FRONT);
    }
    if (list) CFRelease(list);
}

/// `state`: the lease's, for the windows pinned to the screen (sunlight-42): with an app in front they
/// stay on show as they are, at `SUNBEAM_PINNED` above that app's windows, the way the entered and kept
/// windows stay through a handoff; with none (the lease's end, the canvas going dormant) they go back
/// with the rest.
static void sunbeam_release_all(struct sunbeam_saved *saved, int count, uint32_t backdrop, uint32_t overlay, int above_pid, double top,
                                const struct sunbeam_session_state *state)
{
    int cid = SLSMainConnectionID();
    bool canvas = backdrop && overlay && backdrop != overlay;
    bool changed = false, transacted = false;
    bool front[SUNBEAM_LIMIT], pinned[SUNBEAM_LIMIT];
    sunbeam_front_windows(canvas ? above_pid : 0, saved, count, front);
    for (int i = 0; i < count; ++i) {
        pinned[i] = canvas && above_pid && sunbeam_is_pinned(state, saved[i].wid) && sunbeam_owner_matches(&saved[i]);
        if (pinned[i]) front[i] = false;
    }
    for (int attempt = 0; attempt < 2; ++attempt) {
        CFTypeRef transaction = attempt == 0 ? sunbeam_transaction_begin(cid) : NULL;
        uint32_t anchor = backdrop;
        if (transaction) {
            // The levels directly first, bottom up in the order wanted (see `sunbeam_handoff_apply`): the
            // windows put back, the canvas, then the front app's windows above it. The transaction then
            // orders among windows whose levels are final. With an app in front the canvas stays up
            // (sunlight-27) and that app's windows, leased or not, go above it; with none (the lease's
            // end, the canvas going dormant) the canvas comes down.
            for (int i = 0; i < count; ++i) if (!front[i] && !pinned[i] && sunbeam_owner_matches(&saved[i])) sunbeam_level(NULL, cid, saved[i].wid, saved[i].level, &changed);
            if (canvas && !above_pid) sunbeam_canvas_down(NULL, cid, backdrop, overlay, &changed);
            if (canvas && above_pid) { sunbeam_level(NULL, cid, backdrop, SUNBEAM_LEVEL, &changed); sunbeam_level(NULL, cid, overlay, SUNBEAM_LEVEL, &changed); }
            // The pinned ones before the front app's (sunlight-52, see `sunbeam_handoff_apply`): over all
            // from the first call, as they are, their transform and alpha kept.
            for (int i = 0; i < count; ++i) if (pinned[i]) { sunbeam_lifted_add(saved[i].wid, saved[i].level, overlay); sunbeam_level(NULL, cid, saved[i].wid, SUNBEAM_PINNED, &changed); }
            for (int i = 0; i < count; ++i) if (front[i] && sunbeam_owner_matches(&saved[i])) sunbeam_level(NULL, cid, saved[i].wid, above_pid ? SUNBEAM_FRONT : saved[i].level, &changed);
            if (canvas && above_pid) sunbeam_lift_others_of(above_pid, backdrop, overlay, saved, count);
            if (canvas) sunbeam_order(transaction, cid, backdrop, -1, overlay);
            for (int i = count - 1; i >= 0; --i) {
                if (pinned[i]) continue;
                if (front[i]) sunbeam_restore_in_front(transaction, &saved[i], overlay);
                else sunbeam_restore(transaction, &saved[i], backdrop, overlay, &anchor, NULL, 0, false);
            }
        } else {
            for (int i = 0; i < count; ++i) if (pinned[i]) { sunbeam_lifted_add(saved[i].wid, saved[i].level, overlay); sunbeam_level(NULL, cid, saved[i].wid, SUNBEAM_PINNED, &changed); }
            if (canvas) sunbeam_order(NULL, cid, backdrop, -1, overlay);
            for (int i = count - 1; i >= 0; --i) {
                if (pinned[i]) continue;
                if (front[i]) sunbeam_restore_in_front(NULL, &saved[i], overlay);
                else sunbeam_restore(NULL, &saved[i], backdrop, overlay, &anchor, NULL, 0, true);
            }
            if (canvas) sunbeam_canvas_down(NULL, cid, backdrop, overlay, &changed);
        }
        if (canvas) sunbeam_canvas_tuck(transaction, cid, backdrop, overlay, above_pid, saved, count);
        transacted = transaction != NULL;
        if (sunbeam_transaction_end(transaction)) break;
    }
    // A transaction's level changes and its orders should land together, in order. Should the window
    // server have taken the orders first (against windows then at another level, so for nothing), the
    // canvas is on top of the windows it put back: the same orders directly, now that every level is
    // final, cost nothing when the transaction was right and put it right a frame later when it wasn't.
    if (changed && canvas) {
        uint32_t anchor = backdrop;
        sunbeam_order(NULL, cid, backdrop, -1, overlay);
        for (int i = count - 1; i >= 0; --i) {
            if (pinned[i]) continue;
            if (front[i]) sunbeam_restore_in_front(NULL, &saved[i], overlay);
            else sunbeam_restore(NULL, &saved[i], backdrop, overlay, &anchor, NULL, 0, false);
        }
        sunbeam_canvas_tuck(NULL, cid, backdrop, overlay, above_pid, saved, count);
    }
    // Back at native size only now, where they are out of sight (see `sunbeam_restore`); the front app's
    // are on show at the canvas's 1:1 transform, which drew them where they are natively. A pinned
    // window stays a picture of itself, at the transform the canvas drew it at.
    if (transacted) for (int i = count - 1; i >= 0; --i) if (!pinned[i]) sunbeam_settle_later(&saved[i], front[i] ? 0 : (canvas ? backdrop : 0), top);
    // Every window's own alpha back (sunlight-40), now that each is under the backdrop or the front app's
    // and on show as itself: the settle queue's copies don't carry what the canvas changed. Its full
    // shape too (sunlight-52) unless it stays on show as a tile.
    for (int i = 0; i < count; ++i) {
        sunbeam_alpha_reset(&saved[i]);
        if (!pinned[i]) sunbeam_shape_reset(saved[i].wid);
    }
}

// MARK: Frames

// Lengths are checked before any field is decoded. Read into memcpy-packed fields, not C structs.
// Since sunlight-8 a frame may carry a flags byte after the count (`SUNBEAM_FRAME_FULL`); its length
// says whether it does. A partial frame changes transforms only, in one window-server transaction when
// SkyLight has them, so every window moves in the same screen update; a full frame asserts level and
// stacking too, under the Dock's update freeze, as every frame once did.
static bool sunbeam_frame(char *bytes, int length, struct sunbeam_saved *saved, int *saved_count,
                          struct sunbeam_session_state *state)
{
    sunbeam_status = 1;
    if (length < 10) return false;
    uint32_t backdrop, overlay;
    uint16_t count;
    memcpy(&backdrop, bytes, 4); memcpy(&overlay, bytes + 4, 4); memcpy(&count, bytes + 8, 2);
    if (count > SUNBEAM_LIMIT) return false;
    // An empty frame may carry, after its flags byte, the pid of the app that has the front (sunlight-11).
    bool has_above = count == 0 && length == 15;
    bool has_flags = has_above || length == 11 + count * 28;
    if (!has_flags && length != 10 + count * 28) return false;
    uint8_t flags = has_flags ? (uint8_t)bytes[10] : 0;
    int above_pid = 0;
    if (has_above) memcpy(&above_pid, bytes + 11, 4);
    int base = has_flags ? 11 : 10;
    if (count && (!backdrop || !overlay || backdrop == overlay)) return false;
    struct sunbeam_record records[SUNBEAM_LIMIT];
    for (int i = 0; i < count; ++i) {
        memcpy(&records[i].wid, bytes + base + i * 28, 4);
        memcpy(records[i].matrix, bytes + base + 4 + i * 28, 24);
        if (!records[i].wid || records[i].wid == backdrop || records[i].wid == overlay) return false;
        for (int j = 0; j < i; ++j) if (records[j].wid == records[i].wid) return false;
        float *m = records[i].matrix;
        for (int j = 0; j < 6; ++j) if (!isfinite(m[j])) return false;
        // This extension deliberately exposes only positive scale + translation, the canvas's needs.
        if (m[0] < 0.01f || m[0] > 100.0f || m[3] < 0.01f || m[3] > 100.0f || m[1] || m[2]) return false;
    }
    double now = sunbeam_now();
    bool full;
    if (has_flags) {
        // The canvas says. A partial frame on a session that knows nothing yet, or one naming a window
        // this session hasn't taken, is done in full for what it carries: the canvas sends a full frame
        // whenever its set changes, so that is a fresh lease, with nothing to put back.
        full = (flags & SUNBEAM_FRAME_FULL) || backdrop != state->backdrop || overlay != state->overlay;
        if (!full && count && state->order_count < 0) full = true;
        for (int i = 0; !full && i < count; ++i) {
            bool known = false;
            for (int j = 0; j < *saved_count; ++j) if (saved[j].wid == records[i].wid && saved[j].has_applied) known = true;
            full = !known;
        }
    } else {
        // A frame with the same windows in the same order, inside the interval, only moves transforms
        // that changed; anything else asserts everything, as every frame used to.
        full = count != state->order_count || backdrop != state->backdrop || overlay != state->overlay
            || now - state->asserted_at >= SUNBEAM_REASSERT_SECONDS || now < state->asserted_at;
        for (int i = 0; !full && i < count; ++i) full = records[i].wid != state->order[i];
        for (int i = 0; !full && i < count; ++i) {
            bool known = false;
            for (int j = 0; j < *saved_count; ++j) if (saved[j].wid == records[i].wid && saved[j].has_applied) known = true;
            full = !known;
        }
    }
    if (!full) {
        // Only transforms, only the ones that changed, all in one transaction when there is one.
        int changed[SUNBEAM_LIMIT], changed_count = 0;
        for (int i = 0; i < count; ++i) {
            for (int j = 0; j < *saved_count; ++j) {
                if (saved[j].wid != records[i].wid) continue;
                float *m = records[i].matrix;
                CGAffineTransform t = CGAffineTransformMake(m[0], m[1], m[2], m[3], m[4], m[5]);
                if (!CGAffineTransformEqualToTransform(t, saved[j].applied)) changed[changed_count++] = i;
            }
        }
        if (!changed_count) return true;   // nothing to do: no update freeze, no window-server calls
        // In a transaction first; one by one, under the update freeze, if the window server won't take
        // that. A transaction's transform call is not the verdict (the handoff's never was: SkyLight
        // answers it with a code that isn't success while the commit goes through all the same);
        // taking it for one rejected a frame or two of every flight and every return (sunlight-8),
        // and a rejected frame ends the lease, which puts every window back at full size for a
        // moment: a blink on every window change and zoom. Only the direct calls are checked.
        int cid = SLSMainConnectionID();
        for (int attempt = 0; attempt < 2; ++attempt) {
            CFTypeRef transaction = attempt == 0 ? sunbeam_transaction_begin(cid) : NULL;
            if (!transaction && attempt == 0) continue;
            if (!transaction) SLSDisableUpdate(cid);
            bool ok = true;
            for (int k = 0; ok && k < changed_count; ++k) {
                int i = changed[k], index = -1;
                for (int j = 0; j < *saved_count; ++j) if (saved[j].wid == records[i].wid) index = j;
                if (index < 0 || !sunbeam_owner_matches(&saved[index])) continue;
                float *m = records[i].matrix;
                CGAffineTransform t = CGAffineTransformMake(m[0], m[1], m[2], m[3], m[4], m[5]);
                CGError error = sunbeam_transform(transaction, cid, records[i].wid, t);
                if (!transaction && error != kCGErrorSuccess) { sunbeam_status = 3; ok = false; }
                else saved[index].applied = t;
            }
            if (!transaction) { SLSReenableUpdate(cid); return ok; }
            if (sunbeam_transaction_end(transaction)) return true;
            // The commit was refused: nothing in it landed; the same moves go one by one.
        }
        return true;
    }
    // An empty frame releases every window; with the canvas's IDs (since sunlight-3) it is the
    // canvas going dormant with its live look kept (deactivating, say). Then the backdrop goes
    // straight under the canvas first, and the windows are put back out of sight under it — a
    // released window that was first taken over the backdrop (one entered before) would otherwise
    // show through the canvas's live look, and any of them could flash full-size for a frame.
    if (!count && backdrop && overlay && backdrop != overlay) {
        sunbeam_release_all(saved, *saved_count, backdrop, overlay, above_pid, state->top, state);
        *saved_count = 0;
        state->order_count = 0;
        state->backdrop = backdrop;
        state->overlay = overlay;
        state->asserted_at = now;
        return true;
    }
    int cid = SLSMainConnectionID();
    bool ok = true;
    uint32_t anchor = backdrop;
    // Windows the frame leaves out go back first, while the backdrop is still up at the canvas's level
    // (a window set to its own level lands at the front of it: under the backdrop, out of sight).
    SLSDisableUpdate(cid);
    for (int i = *saved_count - 1; i >= 0; --i) {
        bool keep = false;
        for (int j = 0; j < count; ++j) if (records[j].wid == saved[i].wid) keep = true;
        if (!keep) {
            sunbeam_restore(NULL, &saved[i], backdrop, overlay, &anchor, NULL, 0, true);
            memmove(&saved[i], &saved[i + 1], (*saved_count - i - 1) * sizeof(*saved));
            --*saved_count;
        }
    }
    SLSReenableUpdate(cid);
    // What each window is to be: taken (saved) now, so a window that closed mid-frame is skipped. One
    // that has left the screen since the canvas listed it (minimized as the frame was made) is scaled
    // and lifted but given no place in the order (sunlight-12; see `sunbeam_restore`).
    bool take[SUNBEAM_LIMIT], place[SUNBEAM_LIMIT];
    for (int i = 0; i < count; ++i) {
        uint32_t wid = records[i].wid;
        int index = -1;
        for (int j = 0; j < *saved_count; ++j) if (saved[j].wid == wid) index = j;
        if (index < 0) {
            struct sunbeam_saved entry = { .wid = wid };
            if (SLSGetWindowOwner(cid, wid, &entry.owner) != kCGErrorSuccess) { take[i] = place[i] = false; continue; } // closed mid-frame
            // Closed between that read and these (the canvas listed it a moment ago), or a window the
            // server won't describe: left out of this frame like one whose owner read failed, and the
            // canvas lists it gone and leaves it out of the next (sunlight-43). Failing the frame here
            // ended the lease, and every window on the canvas went back to full size for a moment.
            if (SLSGetWindowTransform(cid, wid, &entry.transform) != kCGErrorSuccess ||
                SLSGetWindowLevel(cid, wid, &entry.level) != kCGErrorSuccess) { take[i] = place[i] = false; continue; }
            // A window found at a level of the canvas's (left on show by a handoff or a release, sunlight-27)
            // goes back to its own level when put back (sunlight-41, `sunbeam_lifted`), not to that; the
            // normal level when nothing says.
            int own = sunbeam_lifted_take(wid);
            if (entry.level == SUNBEAM_LEVEL || entry.level == SUNBEAM_FRONT || entry.level == SUNBEAM_PINNED) entry.level = own >= 0 ? own : 0;
            sunbeam_place_drop(wid);
            // A settle still pending for it (sunlight-23): its native transform is the one the settle
            // would have given it. Else a window found scaled (one left at the canvas's transform by a
            // settle that couldn't put it under the backdrop, sunlight-20) is taken as native at its
            // bounds, so that is what it goes back to, not the picture of itself.
            if (!sunbeam_pending_take(wid, &entry.transform) && (fabs(entry.transform.a - 1) > 1e-3 || fabs(entry.transform.d - 1) > 1e-3)) {
                CGRect bounds;
                if (SLSGetWindowBounds(cid, wid, &bounds) == kCGErrorSuccess)
                    entry.transform = CGAffineTransformMakeTranslation(-bounds.origin.x, -bounds.origin.y);
            }
            entry.below = sunbeam_below(wid, entry.level, backdrop, overlay);
            index = (*saved_count)++;
            saved[index] = entry;
        }
        take[i] = sunbeam_owner_matches(&saved[index]);
        place[i] = take[i] && sunbeam_on_screen(wid, NULL);
    }
    if (!ok) {
        state->order_count = -1;
        state->backdrop = backdrop;
        state->overlay = overlay;
        state->asserted_at = now;
        return false;
    }
    // Everything at the canvas's level, in the canvas's order, the backdrop under and the overlay over:
    // in one transaction, levels first (an order against a window at another level does nothing), so a
    // frame that lifts the canvas (its first after a return) shows the before or the after and nothing
    // between. One call at a time under the update freeze when there is none, or the commit was refused:
    // each window scaled and then lifted (it lands at the front: a miniature over the canvas, where it is
    // about to be), the overlay lifted, the backdrop lifted (over everything for the moment, which the
    // freeze is to hide) and the order asserted from the backdrop up.
    bool changed = false;
    for (int attempt = 0; attempt < 2 && ok; ++attempt) {
        CFTypeRef transaction = attempt == 0 ? sunbeam_transaction_begin(cid) : NULL;
        if (!transaction && attempt == 0) continue;
        if (!transaction) SLSDisableUpdate(cid);
        if (transaction) {
            sunbeam_level(transaction, cid, backdrop, SUNBEAM_LEVEL, &changed);
            for (int i = 0; i < count; ++i) if (take[i]) sunbeam_level(transaction, cid, records[i].wid, SUNBEAM_LEVEL, &changed);
            sunbeam_level(transaction, cid, overlay, SUNBEAM_LEVEL, &changed);
        }
        uint32_t previous = backdrop;
        for (int i = 0; i < count && ok; ++i) {
            if (!take[i]) continue;
            uint32_t wid = records[i].wid;
            int index = -1;
            for (int j = 0; j < *saved_count; ++j) if (saved[j].wid == wid) index = j;
            if (index < 0) continue;
            float *m = records[i].matrix;
            CGAffineTransform t = CGAffineTransformMake(m[0], m[1], m[2], m[3], m[4], m[5]);
            if (sunbeam_transform(transaction, cid, wid, t) != kCGErrorSuccess && !transaction) { sunbeam_status = 3; ok = false; break; }
            saved[index].applied = t;
            saved[index].has_applied = true;
            if (!transaction && sunbeam_level(NULL, cid, wid, SUNBEAM_LEVEL, &changed) != kCGErrorSuccess) { sunbeam_status = 4; ok = false; break; }
            if (!place[i]) continue;
            if (transaction) sunbeam_order(transaction, cid, wid, 1, previous);
            previous = wid;
        }
        if (!transaction && ok) {
            if (count && sunbeam_level(NULL, cid, overlay, SUNBEAM_LEVEL, &changed) != kCGErrorSuccess) { sunbeam_status = 6; ok = false; }
            if (ok && count && sunbeam_level(NULL, cid, backdrop, SUNBEAM_LEVEL, &changed) != kCGErrorSuccess) { sunbeam_status = 6; ok = false; }
            previous = backdrop;
            for (int i = 0; i < count && ok; ++i) {
                if (!place[i]) continue;
                if (SLSOrderWindow(cid, records[i].wid, 1, previous) != kCGErrorSuccess) { sunbeam_status = 5; ok = false; break; }
                previous = records[i].wid;
            }
        }
        if (ok && count && sunbeam_order(transaction, cid, overlay, 1, previous) != kCGErrorSuccess && !transaction) { sunbeam_status = 6; ok = false; }
        if (!transaction) { SLSReenableUpdate(cid); break; }
        if (sunbeam_transaction_end(transaction)) break;
        // The commit was refused: nothing in it landed; the same goes one call at a time.
    }
    // Levels changed in a transaction: the orders once more, directly, in case the window server took
    // them before the levels (see `sunbeam_release_all`). A no-op when it didn't.
    if (ok && changed && count) {
        uint32_t previous = backdrop;
        for (int i = 0; i < count; ++i) {
            if (!place[i]) continue;
            SLSOrderWindow(cid, records[i].wid, 1, previous);
            previous = records[i].wid;
        }
        SLSOrderWindow(cid, overlay, 1, previous);
    }
    // A window this canvas lifted to the front level (an entered or kept one, or one of the front app's
    // the canvas never took, sunlight-27) that this frame doesn't take goes back to its own level, under
    // the backdrop. Only this canvas's (sunlight-41): another display's canvas keeps its windows on show.
    if (ok) {
        for (int i = 0; i < sunbeam_lifted_count;) {
            struct sunbeam_lifted *l = &sunbeam_lifted_list[i];
            if (l->canvas != overlay) { ++i; continue; }
            bool taken = false;
            for (int j = 0; j < count; ++j) if (records[j].wid == l->wid) taken = true;
            int owner = 0, level = -1;
            if (!taken && SLSGetWindowOwner(cid, l->wid, &owner) == kCGErrorSuccess && owner == l->owner
                && SLSGetWindowLevel(cid, l->wid, &level) == kCGErrorSuccess && (level == SUNBEAM_FRONT || level == SUNBEAM_PINNED))
                SLSSetWindowLevel(cid, l->wid, l->level);
            if (taken) { ++i; continue; }   // its own level is read off the list as the lease takes it
            memmove(l, l + 1, (sunbeam_lifted_count - i - 1) * sizeof(*l));
            --sunbeam_lifted_count;
        }
    }
    // Only a frame that went through asserts the order; a failed one is asserted in full next time.
    state->order_count = ok ? count : -1;
    for (int i = 0; ok && i < count; ++i) state->order[i] = records[i].wid;
    state->backdrop = backdrop;
    state->overlay = overlay;
    state->asserted_at = now;
    return ok;
}

// MARK: Handoff

/// A window kept on show through a handoff (sunlight-10): one the canvas had in view around the entered
/// one. It goes to its place natively, as the entered window does, and stays in front of the canvas,
/// just under the entered window, to be used as it is.
struct sunbeam_kept {
    int index;                    // in the lease's saved windows
    CGPoint point;                // where it goes natively (no higher than the visible top, sunlight-28)
    CGPoint drawn;                // where the canvas draws it, which `settled` puts it at from `point`
    CGAffineTransform settled;
};

/// Whether a native move can go in a transaction (sunlight-15). The window server keeps a window's
/// transform relative to its native origin: moved while a transform is in force, the window shifts on
/// screen by as much as the move until its transform is set again (measured on 27.2: a window drawn
/// 700 pt right of its native place, moved natively by 700 pt, was drawn 1400 pt right). The handoff
/// made its move directly, before its transaction, so the entered window, natively wherever it was
/// last used, a screen or more from where the canvas draws it, sat off the screen for the few
/// milliseconds until the commit; on a frame boundary that was a blink of the wallpaper, caught on a
/// screen recording of one switch in four. In the transaction nothing shows in between, as long as
/// the move goes before the transform: a transform set first is taken against the native origin the
/// window still had.
static bool sunbeam_moves_in_transaction(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"   // weak symbols: a real check in the add-on
    return SLSTransactionMoveWindowWithGroup && SLSTransactionCreate && SLSTransactionCommit && SLSTransactionSetWindowTransform;
#pragma clang diagnostic pop
}

/// A window's native move: in the transaction when the handoff has one, else now.
static void sunbeam_move(CFTypeRef transaction, int cid, uint32_t wid, CGPoint point)
{
    if (transaction) SLSTransactionMoveWindowWithGroup(transaction, wid, point);
    else SLSMoveWindowWithGroup(cid, wid, &point);
}

/// The visible part of a handoff, in an order whose in-between states look like the state before
/// or the state after, in case it isn't one transaction:
/// 1. the entered window above the canvas — it looks no different there, the canvas is almost clear;
/// 2. its settled transform, which draws it exactly where the camera left it (its native position
///    was moved just before, which the transform in force hid);
/// 3. the windows kept with it, top first, each under the one before, with their settled transforms:
///    each is drawn where it was, now in front of the canvas;
/// 4. the backdrop up under the canvas: the moment every other window leaves;
/// 5. the others put back, out of sight under the backdrop.
///
/// Since sunlight-11 the canvas and its windows sit a level up while the canvas is up, and a handoff
/// brings everything on show down to the normal level, where the entered window's own new windows come
/// up in front of it. In a transaction the levels go first, since an order against a window at another
/// level does nothing, and all of it lands at once. One call at a time (no transaction, or the commit
/// refused) the others go back first, while the backdrop is still up at the canvas's level, so each lands
/// out of sight under it; then the backdrop, the overlay, the kept windows and the entered one come down
/// in that order, each landing at the front of the normal level — which is the order wanted — and the
/// orders are asserted once more for good measure.
///
/// `overlay` is the handoff's own (0 for the 13-byte form, which raises nothing); `canvas_overlay` and
/// `backdrop` are the canvas's windows as the session knows them, which come down either way.
/// `move`: the native moves of the entered window (to `point`) and the kept ones are this function's,
/// made in the transaction, each just before its settled transform (`sunbeam_moves_in_transaction`);
/// without a transaction they are made directly, just before it all the same.
/// `pinned`: per leased window, whether it is pinned to the screen (sunlight-42): it stays on show as it
/// is, at its transform, at `SUNBEAM_PINNED` above the entered window; no move, no order, no settle.
static void sunbeam_handoff_apply(CFTypeRef transaction, uint32_t wid, CGPoint point, bool move,
                                  CGAffineTransform settled, uint32_t overlay,
                                  uint32_t canvas_overlay, uint32_t backdrop, struct sunbeam_saved *saved, int count, int entered,
                                  const struct sunbeam_kept *kept, int kept_count, const bool *pinned, uint32_t anchor, bool *changed)
{
    int cid = SLSMainConnectionID();
    uint32_t skip[2 * SUNBEAM_LIMIT + 1] = { wid };
    int skip_count = 1;
    for (int k = 0; k < kept_count; ++k) skip[skip_count++] = saved[kept[k].index].wid;
    for (int i = 0; i < count; ++i) if (pinned[i]) skip[skip_count++] = saved[i].wid;
    if (transaction) {
        // The levels directly, before the transaction, bottom up in the order wanted (sunlight-19): in
        // a transaction an order against a window whose level changes in it can do nothing, and which
        // level lands where isn't to be relied on either; the window just left came out over the one
        // entered for a frame, whatever the order inside. Directly, a level set puts the window at the
        // front of its new level, so this sequence passes through no state that looks any different from
        // the end: the windows put back go down first, under the backdrop still up at the canvas's level;
        // then the backdrop, the overlay, the kept windows and the entered one, each landing on top of
        // what came down before it and under what is still up. The transaction then moves, orders and
        // transforms among windows whose levels are final.
        for (int i = 0; i < count; ++i) {
            bool on_show = i == entered || pinned[i];
            for (int k = 0; k < kept_count; ++k) if (kept[k].index == i) on_show = true;
            if (!on_show && sunbeam_owner_matches(&saved[i])) sunbeam_level(NULL, cid, saved[i].wid, saved[i].level, changed);
        }
        // The canvas stays up (sunlight-27); the windows on show go above it, the pinned ones over all.
        // The pinned ones first (sunlight-52): raised after the entered window, a tile under the spot that
        // window takes was covered by it for the frame between the two calls, and blinked on every
        // switch; raised before it, it is over everything from the first call, which is where it ends up.
        if (backdrop) sunbeam_level(NULL, cid, backdrop, SUNBEAM_LEVEL, changed);
        if (canvas_overlay) sunbeam_level(NULL, cid, canvas_overlay, SUNBEAM_LEVEL, changed);
        for (int i = 0; i < count; ++i) if (pinned[i]) sunbeam_level(NULL, cid, saved[i].wid, SUNBEAM_PINNED, changed);
        for (int k = 0; k < kept_count; ++k) sunbeam_level(NULL, cid, saved[kept[k].index].wid, SUNBEAM_FRONT, changed);
        sunbeam_level(NULL, cid, wid, SUNBEAM_FRONT, changed);
        // The windows put back, their places (their levels are final; `sunbeam_restore` sets no level twice).
        for (int i = count - 1; i >= 0; --i) {
            bool on_show = i == entered || pinned[i];
            for (int k = 0; k < kept_count; ++k) if (kept[k].index == i) on_show = true;
            if (!on_show) sunbeam_restore(transaction, &saved[i], backdrop, overlay, &anchor, skip, skip_count, false);
        }
        // The moves before any order (sunlight-17): a kept window moved after its order came out above
        // the entered window, full-size over it for the frames until the app's activation put it under
        // (a move with group seems to bring the window forward in its level). Before the transforms
        // too, as the transform is taken against the native origin as it is then (`sunbeam_move`).
        if (move) {
            sunbeam_move(transaction, cid, wid, point);
            for (int k = 0; k < kept_count; ++k) sunbeam_move(transaction, cid, saved[kept[k].index].wid, kept[k].point);
        }
    } else {
        for (int i = count - 1; i >= 0; --i) {
            bool on_show = i == entered || pinned[i];
            for (int k = 0; k < kept_count; ++k) if (kept[k].index == i) on_show = true;
            if (!on_show) sunbeam_restore(NULL, &saved[i], backdrop, overlay, &anchor, skip, skip_count, true);
        }
        if (move) sunbeam_move(NULL, cid, wid, point);
        sunbeam_transform(NULL, cid, wid, settled);
        for (int k = 0; k < kept_count; ++k) {
            if (move) sunbeam_move(NULL, cid, saved[kept[k].index].wid, kept[k].point);
            sunbeam_transform(NULL, cid, saved[kept[k].index].wid, kept[k].settled);
        }
        if (backdrop) sunbeam_level(NULL, cid, backdrop, SUNBEAM_LEVEL, changed);
        if (canvas_overlay) sunbeam_level(NULL, cid, canvas_overlay, SUNBEAM_LEVEL, changed);
        for (int i = 0; i < count; ++i) if (pinned[i]) sunbeam_level(NULL, cid, saved[i].wid, SUNBEAM_PINNED, changed);   // first, as above
        for (int k = 0; k < kept_count; ++k) sunbeam_level(NULL, cid, saved[kept[k].index].wid, SUNBEAM_FRONT, changed);
        sunbeam_level(NULL, cid, wid, SUNBEAM_FRONT, changed);
    }
    if (overlay) sunbeam_order(transaction, cid, wid, 1, overlay);
    if (transaction) sunbeam_transform(transaction, cid, wid, settled);
    uint32_t above = wid;
    for (int k = kept_count - 1; k >= 0; --k) {
        uint32_t kid = saved[kept[k].index].wid;
        if (overlay) sunbeam_order(transaction, cid, kid, -1, above);
        if (transaction) sunbeam_transform(transaction, cid, kid, kept[k].settled);
        above = kid;
    }
    if (overlay && backdrop) sunbeam_order(transaction, cid, backdrop, -1, overlay);
}

/// The entered window goes to `point` at its native size, in front of the canvas, and every other
/// window of the lease back where the add-on found it, except the ones in `keep` (wid, x, y each,
/// bottom to top; sunlight-10): those go to their points too and stay in front of the canvas under
/// it. The window needn't be leased (no frame has gone out on this lease, say): it is taken to its
/// place from wherever it is. A window to keep must be leased, and is put back with the rest if it
/// isn't, is gone, or won't move. False only when the entered window is gone or won't move.
static bool sunbeam_handoff(uint32_t wid, CGPoint point, uint32_t overlay, uint32_t backdrop,
                            const char *keep, int keep_count,
                            struct sunbeam_saved *saved, int count, const struct sunbeam_session_state *state)
{
    double top = state->top;
    int cid = SLSMainConnectionID();
    int entered = -1;
    for (int i = 0; i < count; ++i) if (saved[i].wid == wid) entered = i;
    // A leased entry whose owner changed is a reused ID: not this window any more. The one asked
    // for is taken as found, and the stale entry is left alone.
    if (entered >= 0 && !sunbeam_owner_matches(&saved[entered])) { saved[entered].wid = 0; entered = -1; }
    int owner = 0;
    CGRect frame;
    if (SLSGetWindowOwner(cid, wid, &owner) != kCGErrorSuccess) return false;
    // The native move goes in the transaction where it can (sunlight-15, `sunbeam_moves_in_transaction`),
    // and the settled transform draws the window at the point asked for. Where it can't, the move is
    // made now, under the transform in force, which shows it; the settled transform is then read from
    // where the window landed (an app can clamp a move).
    bool move = sunbeam_moves_in_transaction();
    CGPoint drawn = point;
    point = sunbeam_native_at(drawn, top);
    if (!move) {
        if (SLSMoveWindowWithGroup(cid, wid, &point) != noErr) return false;
        if (SLSGetWindowBounds(cid, wid, &frame) != kCGErrorSuccess) return false;
        point = frame.origin;
        drawn = point;
    }
    CGAffineTransform settled = CGAffineTransformMakeTranslation(-drawn.x, -drawn.y);
    // Its own level back (a frame put it at the canvas's), with the rest of the handoff: set now, it
    // would land at the front of the normal level, under the backdrop still up at the canvas's.
    // Its own level, and the kept ones', remembered (sunlight-41, `sunbeam_lifted`): the handoff lifts
    // them to the front level, and the next lease that takes them puts them back to it.
    int wid_level = 0;
    if (entered >= 0) wid_level = saved[entered].level;
    else if (SLSGetWindowLevel(cid, wid, &wid_level) != kCGErrorSuccess) wid_level = 0;
    // The ones pinned to the screen (sunlight-42): leased, not the one entered, they stay as they are.
    bool pinned[SUNBEAM_LIMIT];
    for (int i = 0; i < count; ++i) {
        pinned[i] = overlay && i != entered && sunbeam_is_pinned(state, saved[i].wid) && sunbeam_owner_matches(&saved[i]);
    }
    // The ones kept on show: moved natively in the transaction too, or now where there is none.
    struct sunbeam_kept kept[SUNBEAM_LIMIT];
    int kept_count = 0;
    for (int k = 0; k < keep_count && overlay; ++k) {
        uint32_t kid; float kx, ky;
        memcpy(&kid, keep + k * 12, 4); memcpy(&kx, keep + k * 12 + 4, 4); memcpy(&ky, keep + k * 12 + 8, 4);
        int index = -1;
        for (int i = 0; i < count; ++i) if (saved[i].wid == kid && i != entered) index = i;
        if (index < 0 || pinned[index] || !sunbeam_owner_matches(&saved[index])) continue;
        bool twice = false;
        for (int j = 0; j < kept_count; ++j) if (kept[j].index == index) twice = true;
        if (twice) continue;
        CGPoint kdrawn = CGPointMake(kx, ky);
        CGPoint kpoint = sunbeam_native_at(kdrawn, top);
        if (!move) {
            CGRect kframe;
            if (SLSMoveWindowWithGroup(cid, kid, &kpoint) != noErr || SLSGetWindowBounds(cid, kid, &kframe) != kCGErrorSuccess) continue;
            kpoint = kframe.origin;
            kdrawn = kpoint;
        }
        kept[kept_count].index = index;
        kept[kept_count].point = kpoint;
        kept[kept_count].drawn = kdrawn;
        kept[kept_count].settled = CGAffineTransformMakeTranslation(-kdrawn.x, -kdrawn.y);
        ++kept_count;
    }
    uint32_t ov = overlay ? overlay : state->overlay;
    uint32_t bd = backdrop ? backdrop : state->backdrop;
    if (ov) {
        sunbeam_lifted_add(wid, wid_level, ov);
        for (int k = 0; k < kept_count; ++k) sunbeam_lifted_add(saved[kept[k].index].wid, saved[kept[k].index].level, ov);
        for (int i = 0; i < count; ++i) if (pinned[i]) sunbeam_lifted_add(saved[i].wid, saved[i].level, ov);
    }
    uint32_t anchor = bd;
    bool changed = false, transacted = false;
    for (int attempt = 0; attempt < 2; ++attempt) {
        CFTypeRef transaction = attempt == 0 ? sunbeam_transaction_begin(cid) : NULL;
        sunbeam_handoff_apply(transaction, wid, point, move, settled, overlay, ov, bd, saved, count, entered, kept, kept_count, pinned, anchor, &changed);
        transacted = transaction != NULL;
        if (sunbeam_transaction_end(transaction)) break;
    }
    // Moved in the transaction: the window is drawn at the point asked for either way (the transform
    // was taken against the native origin after the move). Whether it landed there natively is checked
    // a frame later, from the settle queue (sunlight-23): read straight after the commit, a kept
    // window's bounds could still be the old ones, and redrawing it where it "landed" put the window
    // just left back over the entered one, full-size, at its last place (reported as the Finder over
    // the Claude window). A window found elsewhere then is moved again, with its transform, in one
    // transaction. The entered window gone by now is the one failure.
    if (move) {
        if (SLSGetWindowOwner(cid, wid, &owner) != kCGErrorSuccess) return false;
        sunbeam_place_later(wid, owner, point, drawn);
        for (int k = 0; k < kept_count; ++k) sunbeam_place_later(saved[kept[k].index].wid, saved[kept[k].index].owner, kept[k].point, kept[k].drawn);
    }
    // Its full shape back (sunlight-52), should the canvas not have asked for it before the handoff: a
    // window used at 1:1 has its own corners.
    sunbeam_shape_reset(wid);
    // Levels changed in a transaction: the orders once more, directly, in case the window server took
    // them before the levels (see `sunbeam_release_all`). A no-op when it didn't.
    if (changed) {
        if (overlay) sunbeam_order(NULL, cid, wid, 1, overlay);
        uint32_t above = wid;
        for (int k = kept_count - 1; k >= 0; --k) { sunbeam_order(NULL, cid, saved[kept[k].index].wid, -1, above); above = saved[kept[k].index].wid; }
        if (overlay && bd) sunbeam_order(NULL, cid, bd, -1, overlay);
        uint32_t skip[2 * SUNBEAM_LIMIT + 1] = { wid };
        int skip_count = 1;
        for (int k = 0; k < kept_count; ++k) skip[skip_count++] = saved[kept[k].index].wid;
        for (int i = 0; i < count; ++i) if (pinned[i]) skip[skip_count++] = saved[i].wid;
        uint32_t redo_anchor = bd;
        for (int i = count - 1; i >= 0; --i) {
            bool on_show = i == entered || pinned[i];
            for (int k = 0; k < kept_count; ++k) if (kept[k].index == i) on_show = true;
            if (!on_show) sunbeam_restore(NULL, &saved[i], bd, ov, &redo_anchor, skip, skip_count, false);
        }
    }
    // The windows put back go to native size only now, under the backdrop (see `sunbeam_restore`).
    if (transacted) {
        for (int i = count - 1; i >= 0; --i) {
            bool on_show = i == entered || pinned[i];
            for (int k = 0; k < kept_count; ++k) if (kept[k].index == i) on_show = true;
            if (!on_show) sunbeam_settle_later(&saved[i], bd, top);
        }
    }
    return true;
}

// MARK: Anchor

/// A leased window's real frame to a native origin, its picture unmoved (sunlight-56). The request:
/// the window and the origin (two floats, global top-left). The move and the transform in force go in
/// one transaction, the transform after the move: the window server takes a transform against the
/// native origin the window has when it is set, so a move alone shifts the picture by the move (the
/// handoff's moves go the same way, `sunbeam_moves_in_transaction`). For an app that reads the raw
/// pointer against its real frame (`NSEvent.mouseLocation`: Preview's zoom around the pointer), which
/// the canvas puts under the pointer as a gesture starts; the picture is where the transform draws it,
/// so the real frame isn't clamped under the menu bar here. The answer carries where the window landed
/// (the window server or its app may clamp a move), so the canvas's record of its real frame is right.
/// The lease's record of the window's own transform follows the move (sunlight-57), so a release puts
/// it back where it now is. Status 1 for a request that makes no sense, 25 for a window this lease
/// doesn't hold, 3 when the transform couldn't be set directly (a transaction's code says nothing, see
/// `sunbeam_transaction_end`).
static uint8_t sunbeam_anchor_set(const char *bytes, int length, struct sunbeam_saved *saved, int count, CGPoint *landed)
{
    *landed = CGPointZero;
    if (length != 12) return 1;
    uint32_t wid; float x, y;
    memcpy(&wid, bytes, 4); memcpy(&x, bytes + 4, 4); memcpy(&y, bytes + 8, 4);
    if (!wid || !isfinite(x) || !isfinite(y) || fabsf(x) > 1e6f || fabsf(y) > 1e6f) return 1;
    struct sunbeam_saved *entry = NULL;
    for (int i = 0; i < count && !entry; ++i) if (saved[i].wid == wid) entry = &saved[i];
    if (!entry || !sunbeam_owner_matches(entry)) return 25;
    int cid = SLSMainConnectionID();
    CGPoint point = CGPointMake(x, y);
    CGAffineTransform t = entry->has_applied ? entry->applied : entry->transform;
    CFTypeRef transaction = sunbeam_moves_in_transaction() ? sunbeam_transaction_begin(cid) : NULL;
    uint8_t status = 0;
    if (transaction) {
        sunbeam_move(transaction, cid, wid, point);
        sunbeam_transform(transaction, cid, wid, t);
        sunbeam_transaction_end(transaction);
    } else {
        SLSDisableUpdate(cid);
        SLSMoveWindowWithGroup(cid, wid, &point);
        if (SLSSetWindowTransform(cid, wid, t) != kCGErrorSuccess) status = 3;
        SLSReenableUpdate(cid);
    }
    CGRect frame;
    *landed = SLSGetWindowBounds(cid, wid, &frame) == kCGErrorSuccess ? frame.origin : point;
    // The window's own transform, put back when the lease lets it go (`sunbeam_settle`, `sunbeam_restore`),
    // is the native one where the lease found it: a translation to minus that origin. The window lives
    // at the new origin now, so that is what it goes back to (sunlight-57); with the old one a window let
    // go at a zoom was drawn at its old place while its app had it at the new one.
    if (fabs(entry->transform.a - 1) < 1e-3 && fabs(entry->transform.d - 1) < 1e-3) {
        entry->transform = CGAffineTransformMakeTranslation(-landed->x, -landed->y);
    }
    return status;
}

// MARK: Session

static void *sunbeam_session(void *context)
{
    int fd = (int)(intptr_t)context;
    struct sunbeam_saved saved[SUNBEAM_LIMIT];
    int count = 0;
    struct sunbeam_session_state state = { .order_count = -1, .top = NAN };
    // One app's canvases own transforms, a lease each. The stock yabai daemon remains free to accept commands.
    pid_t peer = 0;
    socklen_t peer_length = sizeof(peer);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &peer_length) != 0) peer = 0;
    pthread_mutex_lock(&sunbeam_lock);
    bool admitted = sunbeam_sessions == 0 || (sunbeam_sessions < SUNBEAM_SESSIONS && peer && peer == sunbeam_sessions_pid);
    if (admitted && sunbeam_sessions++ == 0) sunbeam_sessions_pid = peer;
    pthread_mutex_unlock(&sunbeam_lock);
    if (!admitted) { close(fd); return NULL; }
    struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    if (send(fd, SUNBEAM_MAGIC, sizeof(SUNBEAM_MAGIC) - 1, 0) != sizeof(SUNBEAM_MAGIC) - 1) goto done;
    for (;;) {
        int16_t length;
        char bytes[SA_SOCKET_BUFF_LEN];
        if (!sunbeam_read(fd, &length, 2) || length <= 0 || length >= SA_SOCKET_BUFF_LEN ||
            !sunbeam_read(fd, bytes, length)) break;
        bool ok = false;
        pthread_mutex_lock(&sunbeam_lock);
        sunbeam_status = 1;
        if ((uint8_t)bytes[0] == SUNBEAM_FRAME) {
            ok = sunbeam_frame(bytes + 1, length - 1, saved, &count, &state);
        } else if ((uint8_t)bytes[0] == SUNBEAM_SHADOW && length == 45) {
            // Shadows are cosmetic: a refusal is answered with its status and the lease goes on, a frame
            // or a handoff behind it.
            uint8_t status = sunbeam_shadow_set(bytes + 1);
            pthread_mutex_unlock(&sunbeam_lock);
            if (send(fd, &status, 1, 0) != 1) break;
            continue;
        } else if ((uint8_t)bytes[0] == SUNBEAM_ALPHA && length >= 2) {
            // Cosmetic too: answered with its status, the lease goes on.
            uint8_t status = sunbeam_alpha_set(bytes + 1, length - 1, saved, count);
            pthread_mutex_unlock(&sunbeam_lock);
            if (send(fd, &status, 1, 0) != 1) break;
            continue;
        } else if ((uint8_t)bytes[0] == SUNBEAM_SHAPE && length == 9) {
            // A tile's rounded corners (sunlight-52): cosmetic, answered with its status, the lease goes on.
            uint8_t status = sunbeam_shape_set(bytes + 1, length - 1);
            pthread_mutex_unlock(&sunbeam_lock);
            if (send(fd, &status, 1, 0) != 1) break;
            continue;
        } else if ((uint8_t)bytes[0] == SUNBEAM_ANCHOR && length == 13) {
            // A leased window's real frame under the pointer (sunlight-56): answered with its status and
            // where the window landed (two floats); the lease goes on.
            CGPoint landed;
            uint8_t answer[9];
            answer[0] = sunbeam_anchor_set(bytes + 1, length - 1, saved, count, &landed);
            float lx = (float)landed.x, ly = (float)landed.y;
            memcpy(answer + 1, &lx, 4); memcpy(answer + 5, &ly, 4);
            pthread_mutex_unlock(&sunbeam_lock);
            if (send(fd, answer, 9, 0) != 9) break;
            continue;
        } else if ((uint8_t)bytes[0] == SUNBEAM_PIN && length >= 2) {
            // The windows pinned to the screen (sunlight-42): a count, then that many IDs. Replaces the
            // last list; the lease goes on either way, with the old list if this one makes no sense.
            int n = (uint8_t)bytes[1];
            uint8_t status = 1;
            if (length == 2 + n * 4 && n <= SUNBEAM_LIMIT) {
                memcpy(state.pinned, bytes + 2, n * 4);
                state.pinned_count = n;
                status = 0;
            }
            pthread_mutex_unlock(&sunbeam_lock);
            if (send(fd, &status, 1, 0) != 1) break;
            continue;
        } else if ((uint8_t)bytes[0] == SUNBEAM_HANDOFF && (length == 13 || length == 21 ||
                   (length > 22 && (length - 22) % 12 == 0 && (uint8_t)bytes[21] == (length - 22) / 12) ||
                   (length >= 26 && (length - 26) % 12 == 0 && (uint8_t)bytes[21] == (length - 26) / 12))) {
            // 13 bytes: the window and its native position. 21 (since sunlight-3): also the canvas's
            // overlay and backdrop, so the raise above the canvas and the backdrop's tuck under it land
            // with the rest. Sent as separate requests after the acknowledgement, they could only be
            // made atomic by the canvas holding its own update freeze across this request — which
            // deadlocks against the Dock's own freeze until the window server's timeout. Longer (since
            // sunlight-10): a count, then the windows kept on show with it, 12 bytes each. A trailing
            // float (since sunlight-28): the top of the display's visible part, under the menu bar,
            // which no window goes above natively (`sunbeam_native_at`).
            sunbeam_status = 7;
            uint32_t wid, overlay = 0, backdrop = 0; float x, y;
            int keep_count = length > 21 ? (uint8_t)bytes[21] : 0;
            bool with_top = length >= 26 && (length - 26) % 12 == 0;
            if (with_top) {
                float top;
                memcpy(&top, bytes + length - 4, 4);
                state.top = isfinite(top) ? top : NAN;
            }
            memcpy(&wid, bytes + 1, 4); memcpy(&x, bytes + 5, 4); memcpy(&y, bytes + 9, 4);
            if (length >= 21) { memcpy(&overlay, bytes + 13, 4); memcpy(&backdrop, bytes + 17, 4); }
            bool sane = keep_count <= SUNBEAM_LIMIT;
            for (int k = 0; sane && k < keep_count; ++k) {
                uint32_t kid; float kx, ky;
                memcpy(&kid, bytes + 22 + k * 12, 4); memcpy(&kx, bytes + 26 + k * 12, 4); memcpy(&ky, bytes + 30 + k * 12, 4);
                sane = kid && kid != wid && kid != overlay && kid != backdrop && isfinite(kx) && isfinite(ky);
            }
            if (sane && wid && isfinite(x) && isfinite(y) && wid != overlay && wid != backdrop && (!overlay || overlay != backdrop)) {
                ok = sunbeam_handoff(wid, CGPointMake(x, y), overlay, backdrop, bytes + 22, keep_count, saved, count, &state);
                if (ok) {
                    // Every window is back where the add-on found it, and the entered one (and any
                    // kept with it) keeps its committed position with the native identity transform
                    // on disconnect. Those on show get their own alpha back here (the rest already
                    // have, as they were put back).
                    for (int i = 0; i < count; ++i) sunbeam_alpha_reset(&saved[i]);
                    count = 0;
                    state.order_count = -1;
                }
            }
        }
        uint8_t status = ok ? 0 : sunbeam_status;
        pthread_mutex_unlock(&sunbeam_lock);
        if (send(fd, &status, 1, 0) != 1 || !ok) break;
    }
done:
    pthread_mutex_lock(&sunbeam_lock);
    sunbeam_release_all(saved, count, state.backdrop, state.overlay, 0, state.top, &state);
    --sunbeam_sessions;
    pthread_mutex_unlock(&sunbeam_lock);
    shutdown(fd, SHUT_RDWR); close(fd);
    return NULL;
}

// Called only after the ordinary length-prefixed envelope has been read. Returning true transfers
// ownership of fd to the lease worker; the normal handler must not close it.
static bool sunbeam_dispatch(int fd, char *message)
{
    if ((uint8_t)message[0] == SUNBEAM_CAPABILITY) {
        send(fd, SUNBEAM_MAGIC, sizeof(SUNBEAM_MAGIC) - 1, 0);
    } else if ((uint8_t)message[0] == SUNBEAM_SESSION) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, sunbeam_session, (void *)(intptr_t)fd) == 0) {
            pthread_detach(thread);
            return true;
        }
    }
    return false;
}
