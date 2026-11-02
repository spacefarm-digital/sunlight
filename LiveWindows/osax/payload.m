// Sunlight Live Windows: the add-on that runs inside the Dock.
//
// Why the Dock: WindowServer lets the Dock's connection transform, re-level and reorder any app's
// windows (it's how Mission Control is drawn). Loaded into the Dock by the loader, this code listens
// on a per-user socket and applies the live-window protocol in sunbeam.h with the Dock's connection.
//
// Adapted from yabai's scripting addition (https://github.com/koekeishiya/yabai, MIT, Copyright (c)
// 2019 Åsmund Vikane; see LICENSE-yabai.txt): the socket daemon and the length-prefixed envelope are
// yabai's. What Sunlight doesn't use is gone: the search through the Dock's own code for its Spaces
// objects and functions (the part that breaks with each macOS release), the patching of the Dock's
// animation-time instruction, and the Spaces, opacity, sticky, shadow, focus, thumbnail-scale and
// proxy operations. Only the stock move (0x06) and order (0x10) operations remain beside Sunlight's,
// and 0x01 now answers with the add-on's version. Desktops came back in sunlight-55 (spaces.h), through
// SkyLight's own Space calls rather than the Dock's internals.
#include <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>
#include <pwd.h>
#include <errno.h>
#include <string.h>
#include "common.h"

extern int SLSMainConnectionID(void);
extern OSStatus SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point);
extern CGError SLSReassociateWindowsSpacesByGeometry(int cid, CFArrayRef window_list);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *window_cid);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSGetWindowTransform(int cid, uint32_t wid, CGAffineTransform *t);
extern CGError SLSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform t);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);

#include "sunbeam.h"
#include "spaces.h"

static int daemon_sockfd = -1;

// MARK: Stock operations, as yabai encodes them: memcpy-packed fields after the opcode, no padding.
// Unlike the original, a message of the wrong length is dropped rather than read past its end.

static void do_version(int sockfd)
{
    static const char reply[] = OSAX_VERSION "\n";
    send(sockfd, reply, sizeof(reply) - 1, 0);
}

static void do_window_move(const char *fields, int length)
{
    uint32_t wid;
    int32_t x, y;
    if (length != 12) return;
    memcpy(&wid, fields, 4); memcpy(&x, fields + 4, 4); memcpy(&y, fields + 8, 4);
    if (!wid) return;
    int cid = SLSMainConnectionID();
    CGPoint point = CGPointMake(x, y);
    SLSMoveWindowWithGroup(cid, wid, &point);
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    CFArrayRef list = CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    SLSReassociateWindowsSpacesByGeometry(cid, list);
    CFRelease(list);
    CFRelease(number);
}

static void do_window_order(const char *fields, int length)
{
    uint32_t wid, other;
    int32_t order;
    if (length != 12) return;
    memcpy(&wid, fields, 4); memcpy(&order, fields + 4, 4); memcpy(&other, fields + 8, 4);
    if (!wid || order < -1 || order > 1) return;
    SLSOrderWindow(SLSMainConnectionID(), wid, order, other);
}

/// A window's level, set at once (sunlight-27): the canvas lifts a sheet or prompt of the entered app
/// above itself the moment the window server announces it, since every window is born under the canvas.
static void do_window_level(const char *fields, int length)
{
    uint32_t wid; int32_t level;
    if (length < 8) return;
    memcpy(&wid, fields, 4); memcpy(&level, fields + 4, 4);
    if (!wid || level < 0 || level > 2) return;
    SLSSetWindowLevel(SLSMainConnectionID(), wid, level);
}

static void handle_message(int sockfd, const char *message, int length)
{
    switch ((uint8_t)message[0]) {
    case SA_OPCODE_VERSION:      do_version(sockfd); break;
    case SA_OPCODE_WINDOW_MOVE:  do_window_move(message + 1, length - 1); break;
    case SA_OPCODE_WINDOW_ORDER: do_window_order(message + 1, length - 1); break;
    case SA_OPCODE_WINDOW_LEVEL: do_window_level(message + 1, length - 1); break;
    case SUNBEAM_SPACES:         sunbeam_spaces(sockfd, message + 1, length - 1); break;
    default: break;   // unknown opcodes are ignored, not answered
    }
}

// MARK: The daemon

// The envelope: a native int16 length (not counting itself), then that many bytes, the first of
// which is the opcode. Returns the length read, or 0 for a short read, a timeout or a bad length.
static int read_message(int sockfd, char *message)
{
    int16_t length;
    if (!sunbeam_read(sockfd, &length, sizeof(length))) return 0;
    if (length <= 0 || length >= SA_SOCKET_BUFF_LEN) return 0;
    return sunbeam_read(sockfd, message, (size_t)length) ? length : 0;
}

static void *serve(void *unused)
{
    (void)unused;
    pthread_setname_np("Sunlight Live Windows");
    for (;;) {
        int sockfd = accept(daemon_sockfd, NULL, NULL);
        if (sockfd == -1) {
            if (errno == EINTR || errno == ECONNABORTED) continue;
            usleep(100000);   // out of descriptors, say: don't spin a Dock thread
            continue;
        }
        // A peer that vanishes must not SIGPIPE the Dock, and one that stalls must not hold the
        // listener. A session (sunbeam.h) sets its own, longer timeouts once it owns the socket.
        int yes = 1;
        setsockopt(sockfd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        struct timeval timeout = { .tv_sec = 1, .tv_usec = 0 };
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

        char message[SA_SOCKET_BUFF_LEN];
        int length = read_message(sockfd, message);
        if (length) {
            if (sunbeam_dispatch(sockfd, message)) continue;   // the session thread owns sockfd now
            handle_message(sockfd, message, length);
        }
        shutdown(sockfd, SHUT_RDWR);
        close(sockfd);
    }
    return NULL;
}

static bool start_daemon(const char *socket_path)
{
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (strlen(socket_path) >= sizeof(address.sun_path)) return false;
    strlcpy(address.sun_path, socket_path, sizeof(address.sun_path));
    unlink(socket_path);   // a socket left by the previous Dock
    if ((daemon_sockfd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) return false;
    // Only this user's processes may connect, and the mode is set before anything can be accepted.
    pthread_t thread;
    if (bind(daemon_sockfd, (struct sockaddr *)&address, sizeof(address)) == -1
        || chmod(socket_path, 0600) != 0
        || listen(daemon_sockfd, SOMAXCONN) == -1
        || pthread_create(&thread, NULL, serve, NULL) != 0) {
        int saved = errno;
        close(daemon_sockfd);
        daemon_sockfd = -1;
        unlink(socket_path);
        errno = saved;
        return false;
    }
    pthread_detach(thread);
    return true;
}

__attribute__((constructor))
static void load_payload(void)
{
    // The Dock runs as the logged-in user, so its uid names the socket, as Sunlight expects.
    struct passwd *pw = getpwuid(getuid());
    const char *user = pw ? pw->pw_name : getenv("USER");
    if (!user) {
        NSLog(@"[sunlight-live] no user name to name the socket by; not listening");
        return;
    }
    char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    if (snprintf(socket_path, sizeof(socket_path), SA_SOCKET_PATH_FMT, user) >= (int)sizeof(socket_path)) {
        NSLog(@"[sunlight-live] the socket path for user %s is too long; not listening", user);
        return;
    }
    if (start_daemon(socket_path)) {
        NSLog(@"[sunlight-live] %s listening at %s", OSAX_VERSION, socket_path);
    } else {
        NSLog(@"[sunlight-live] couldn't listen at %s: %s", socket_path, strerror(errno));
    }
}
