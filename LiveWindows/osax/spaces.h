// Desktops (sunlight-55), Sunlight's own code. Included by payload.m after sunbeam.h.
//
// Takeover keeps one Desktop per display, the canvas's: the others are folded into it. With SIP on the
// window server takes two parts of that only from the Dock (LiveWindows/spaces-probe.m, macOS 27.2):
// moving another app's window to a Desktop, and removing a Desktop. This op does both with the Dock's
// connection. One request on its own connection, answered with one status byte:
//
//   0x78, 1, uint64 space, uint8 count, count × uint32 window   move the windows onto the Desktop
//   0x78, 2, uint64 space                                       remove the Desktop, which must be empty
//
// Status 0 done; 1 a request that makes no sense; 20 SkyLight lacks the calls; 21 not a Desktop (a
// full-screen app's Space, the system's, or a display's only Desktop); 22 a window didn't go; 23 the
// Desktop still has an app's window of its own; 24 the Desktop is still there afterwards. (10 to 12 are
// alpha's and shape's.)
#define SUNBEAM_SPACES        0x78
#define SUNBEAM_SPACES_MOVE   1
#define SUNBEAM_SPACES_REMOVE 2

extern CFArrayRef SLSCopyManagedDisplaySpaces(int cid) SUNBEAM_WEAK;
extern CFArrayRef SLSCopySpacesForWindows(int cid, int mask, CFArrayRef windows) SUNBEAM_WEAK;
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef windows, uint64_t space) SUNBEAM_WEAK;
extern void SLSSpaceDestroy(int cid, uint64_t space) SUNBEAM_WEAK;
extern CGError SLSManagedDisplaySetCurrentSpace(int cid, CFStringRef display, uint64_t space) SUNBEAM_WEAK;
extern void SLSShowSpaces(int cid, CFArrayRef spaces) SUNBEAM_WEAK;
extern void SLSHideSpaces(int cid, CFArrayRef spaces) SUNBEAM_WEAK;
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner, CFArrayRef spaces, uint32_t options, uint64_t *set_tags, uint64_t *clear_tags) SUNBEAM_WEAK;
// yabai's way onto a Space where a plain move is ignored (macOS 14.5 on): the Space takes a workspace
// number for a moment, and the windows are put in that workspace.
extern CGError SLSSpaceSetCompatID(int cid, uint64_t space, int workspace) SUNBEAM_WEAK;
extern CGError SLSSetWindowListWorkspace(int cid, uint32_t *windows, int count, int workspace) SUNBEAM_WEAK;
#define SUNBEAM_SPACES_WORKSPACE 0x79616265

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"   // the symbols are weak
static bool sunbeam_spaces_available(void)
{
    return SLSCopyManagedDisplaySpaces && SLSCopySpacesForWindows && SLSMoveWindowsToManagedSpace && SLSSpaceDestroy
        && SLSManagedDisplaySetCurrentSpace;
}
#pragma clang diagnostic pop

static CFNumberRef sunbeam_spaces_number(uint64_t value)
{
    return CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
}

static uint64_t sunbeam_spaces_value(CFTypeRef number)
{
    uint64_t value = 0;
    if (number && CFGetTypeID(number) == CFNumberGetTypeID()) CFNumberGetValue(number, kCFNumberSInt64Type, &value);
    return value;
}

/// Where `space` is: its display (retained, for the caller to release), whether it is a Desktop, whether
/// it is the display's current one, and another Desktop on the display (0 when it is the only one).
static bool sunbeam_spaces_find(int cid, uint64_t space, CFStringRef *display, bool *desktop, bool *current, uint64_t *other)
{
    CFArrayRef displays = SLSCopyManagedDisplaySpaces(cid);
    if (!displays) return false;
    bool found = false;
    for (CFIndex i = 0; i < CFArrayGetCount(displays) && !found; ++i) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(displays, i);
        CFArrayRef spaces = CFDictionaryGetValue(d, CFSTR("Spaces"));
        if (!spaces) continue;
        uint64_t neighbour = 0;
        for (CFIndex j = 0; j < CFArrayGetCount(spaces); ++j) {
            CFDictionaryRef s = CFArrayGetValueAtIndex(spaces, j);
            uint64_t id = sunbeam_spaces_value(CFDictionaryGetValue(s, CFSTR("id64")));
            bool user = sunbeam_spaces_value(CFDictionaryGetValue(s, CFSTR("type"))) == 0;
            if (id == space) {
                found = true;
                *desktop = user;
            } else if (user && !neighbour) {
                neighbour = id;
            }
        }
        if (!found) continue;
        CFDictionaryRef now = CFDictionaryGetValue(d, CFSTR("Current Space"));
        *current = now && sunbeam_spaces_value(CFDictionaryGetValue(now, CFSTR("id64"))) == space;
        *other = neighbour;
        CFStringRef identifier = CFDictionaryGetValue(d, CFSTR("Display Identifier"));
        *display = identifier ? CFRetain(identifier) : NULL;
    }
    CFRelease(displays);
    return found;
}

/// Whether `window` is on `space` (among others, or only there).
static bool sunbeam_spaces_on(int cid, uint32_t window, uint64_t space, bool only)
{
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &window);
    CFArrayRef list = CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    CFArrayRef spaces = SLSCopySpacesForWindows(cid, 0x7, list);
    CFRelease(list); CFRelease(number);
    if (!spaces) return false;
    bool on = false;
    for (CFIndex i = 0; i < CFArrayGetCount(spaces); ++i) on = on || sunbeam_spaces_value(CFArrayGetValueAtIndex(spaces, i)) == space;
    bool there = on && (!only || CFArrayGetCount(spaces) == 1);
    CFRelease(spaces);
    return there;
}

static uint8_t sunbeam_spaces_move(int cid, uint64_t space, const uint32_t *windows, int count)
{
    CFStringRef display = NULL; bool desktop = false, current = false; uint64_t other = 0;
    if (!sunbeam_spaces_find(cid, space, &display, &desktop, &current, &other)) return 21;
    if (display) CFRelease(display);
    if (!desktop) return 21;
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (int k = 0; k < count; ++k) {
        CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &windows[k]);
        CFArrayAppendValue(list, number);
        CFRelease(number);
    }
    SLSMoveWindowsToManagedSpace(cid, list, space);
    CFRelease(list);
    uint32_t missed[SUNBEAM_LIMIT]; int missed_count = 0;
    for (int k = 0; k < count; ++k) if (!sunbeam_spaces_on(cid, windows[k], space, false)) missed[missed_count++] = windows[k];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"
    if (missed_count && SLSSpaceSetCompatID && SLSSetWindowListWorkspace) {
#pragma clang diagnostic pop
        SLSSpaceSetCompatID(cid, space, SUNBEAM_SPACES_WORKSPACE);
        SLSSetWindowListWorkspace(cid, missed, missed_count, SUNBEAM_SPACES_WORKSPACE);
        SLSSpaceSetCompatID(cid, space, 0);
        int still = 0;
        for (int k = 0; k < missed_count; ++k) if (!sunbeam_spaces_on(cid, missed[k], space, false)) ++still;
        missed_count = still;
    }
    if (missed_count) NSLog(@"[sunlight-live] %d of %d window(s) didn't go to Desktop %llu", missed_count, count, space);
    return missed_count ? 22 : 0;
}

/// Whether an app's window lives on `space` alone (one on every Desktop doesn't keep it from being
/// removed). Only windows from the normal level up to under the Dock's (0 to 19) count: every Desktop has
/// windows of the system's own, its menu bar (24) and its wallpaper and underbelly (far below 0), which go
/// with it (the first build, 48, counted them and so never removed one). Taken as yes when the window server
/// won't say: a Desktop is never removed with an app's window on it.
static bool sunbeam_spaces_has_windows(int cid, uint64_t space)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"
    if (!SLSCopyWindowsWithOptionsAndTags) return true;
#pragma clang diagnostic pop
    CFNumberRef number = sunbeam_spaces_number(space);
    CFArrayRef spaces = CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    uint64_t set = 0, clear = 0;
    CFArrayRef windows = SLSCopyWindowsWithOptionsAndTags(cid, 0, spaces, 0x2, &set, &clear);
    CFRelease(spaces); CFRelease(number);
    if (!windows) return true;
    bool has = false;
    for (CFIndex i = 0; i < CFArrayGetCount(windows) && !has; ++i) {
        uint32_t window = (uint32_t)sunbeam_spaces_value(CFArrayGetValueAtIndex(windows, i));
        int level = 0;
        if (SLSGetWindowLevel(cid, window, &level) == kCGErrorSuccess && (level < 0 || level >= 20)) continue;
        has = sunbeam_spaces_on(cid, window, space, true);
    }
    CFRelease(windows);
    return has;
}

static uint8_t sunbeam_spaces_remove(int cid, uint64_t space)
{
    CFStringRef display = NULL; bool desktop = false, current = false; uint64_t other = 0;
    if (!sunbeam_spaces_find(cid, space, &display, &desktop, &current, &other)) return 0;   // gone already
    uint8_t status = 0;
    if (!desktop || !other || !display) {
        status = 21;
    } else if (sunbeam_spaces_has_windows(cid, space)) {
        status = 23;
    } else {
        if (current) {
            // Off the Desktop first, as Mission Control does before it removes the one you're on.
            SLSManagedDisplaySetCurrentSpace(cid, display, other);
            CFNumberRef to = sunbeam_spaces_number(other), from = sunbeam_spaces_number(space);
            CFArrayRef show = CFArrayCreate(NULL, (const void **)&to, 1, &kCFTypeArrayCallBacks);
            CFArrayRef hide = CFArrayCreate(NULL, (const void **)&from, 1, &kCFTypeArrayCallBacks);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"
            if (SLSShowSpaces) SLSShowSpaces(cid, show);
            if (SLSHideSpaces) SLSHideSpaces(cid, hide);
#pragma clang diagnostic pop
            CFRelease(show); CFRelease(hide); CFRelease(to); CFRelease(from);
        }
        SLSSpaceDestroy(cid, space);
        // The managed list catches up within a few frames.
        bool there = true;
        for (int attempt = 0; attempt < 10 && there; ++attempt) {
            CFStringRef again = NULL; bool d = false, c = false; uint64_t o = 0;
            there = sunbeam_spaces_find(cid, space, &again, &d, &c, &o);
            if (again) CFRelease(again);
            if (there) usleep(20000);
        }
        if (there) status = 24;
        NSLog(@"[sunlight-live] Desktop %llu %s", space, there ? "still there after removing it" : "removed");
    }
    if (display) CFRelease(display);
    return status;
}

/// The request after the opcode; answers its status.
static void sunbeam_spaces(int sockfd, const char *fields, int length)
{
    uint8_t status = 1;
    uint64_t space = 0;
    if (length >= 9) memcpy(&space, fields + 1, 8);
    if (!sunbeam_spaces_available()) {
        status = 20;
    } else if (length >= 10 && fields[0] == SUNBEAM_SPACES_MOVE && space) {
        int count = (uint8_t)fields[9];
        if (count > 0 && count <= SUNBEAM_LIMIT && length == 10 + count * 4) {
            uint32_t windows[SUNBEAM_LIMIT];
            memcpy(windows, fields + 10, count * 4);
            bool sane = true;
            for (int k = 0; k < count; ++k) sane = sane && windows[k];
            if (sane) status = sunbeam_spaces_move(SLSMainConnectionID(), space, windows, count);
        }
    } else if (length == 9 && fields[0] == SUNBEAM_SPACES_REMOVE && space) {
        status = sunbeam_spaces_remove(SLSMainConnectionID(), space);
    }
    send(sockfd, &status, 1, 0);
}
