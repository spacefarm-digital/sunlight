// SunlightLiveWindows: puts Sunlight's Dock add-on in place and loads it into the running Dock.
//
//   SunlightLiveWindows load     install the add-on if it isn't (restarting the Dock), load it, and check
//                                it answers; as root. Does nothing when it's already answering.
//   SunlightLiveWindows unload   remove the add-on and restart the Dock, which drops it; as root
//   SunlightLiveWindows status   what's installed, whether it answers, and whether this Mac can load it
//   SunlightLiveWindows bootarg  add -arm64e_preview_abi to the boot arguments for the next startup; as root
//   SunlightLiveWindows daemon   run as the launch daemon the app registers with SMAppService
//                                (Contents/Library/LaunchDaemons), answering `load` and `bootarg` over XPC
//                                for the app alone: same team, Sunlight's bundle identifier
//
// The add-on (payload) and the loader that injects it are built in with -sectcreate, so the one file the
// sudoers rule pins by hash is everything that runs as root. The daemon is the main way the app reaches
// root (one approval in System Settings › Login Items, no password, nothing in /etc); `sudo` with the
// administrator prompt is the fallback for builds without a team signature, which launchd won't run.
// Nothing here uses NSRunningApplication: a launch daemon sits outside the user's session, where
// LaunchServices doesn't list the Dock, so the Dock is found by its path and owner instead. Adapted from yabai's src/sa.m
// (https://github.com/koekeishiya/yabai, MIT, Copyright (c) 2019 Åsmund Vikane); see osax/LICENSE-yabai.txt.
#include <Cocoa/Cocoa.h>
#include <Security/Security.h>
#include <libproc.h>
#include <mach-o/fat.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <mach-o/loader.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <pwd.h>
#include <signal.h>
#include <unistd.h>
#include "osax/common.h"

extern int csr_get_active_config(uint32_t *config);
#define CSR_ALLOW_UNRESTRICTED_FS 0x02
#define CSR_ALLOW_TASK_FOR_PID    0x04

static NSString *const kBase    = @"/Library/ScriptingAdditions/Sunlight.osax";
static NSString *const kLoader  = @"/Library/ScriptingAdditions/Sunlight.osax/Contents/MacOS/loader";
static NSString *const kPayload = @"/Library/ScriptingAdditions/Sunlight.osax/Contents/Resources/payload.bundle";
static NSString *const kPayloadBinary = @"/Library/ScriptingAdditions/Sunlight.osax/Contents/Resources/payload.bundle/Contents/MacOS/payload";
static NSString *const kMachService = @"com.spacefarm.sunlight.live-windows";
static NSString *const kAppIdentifier = @"com.spacefarm.sunlight";
static const char kDockPath[] = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock";
static const char kBootArg[] = "-arm64e_preview_abi";

static NSString *plist(NSDictionary *entries)
{
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:entries format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSData *embedded(const char *section)
{
    unsigned long size = 0;
    uint8_t *bytes = getsectiondata(&_mh_execute_header, "__TEXT", section, &size);
    if (!bytes || !size) return nil;
    return [NSData dataWithBytes:bytes length:size];
}

/// The arm64e pointer-authentication ABI a Mach-O file is built for: the top byte of its cpusubtype,
/// 0x80 for v0 and 0x81 for v1; 0 when it has no arm64e image. The macOS 15 Dock is v0 and Xcode 26
/// stamps what it builds v1, and the Dock won't take an add-on or loader whose ABI differs from its own.
/// Spotted by Alvaro Almeida (spacefarm-digital/sunlight#2).
static uint8_t arm64eABI(NSString *path)
{
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *data = [file readDataUpToLength:4096 error:nil];
    [file closeFile];
    if (data.length < sizeof(struct mach_header_64)) return 0;
    const uint8_t *bytes = data.bytes;
    uint32_t magic = OSSwapBigToHostInt32(*(const uint32_t *)bytes);
    if (magic == FAT_MAGIC || magic == FAT_MAGIC_64) {
        // A universal file: its table is big-endian, and both entry layouts start with cputype, cpusubtype.
        uint32_t count = OSSwapBigToHostInt32(((const struct fat_header *)bytes)->nfat_arch);
        size_t entry = magic == FAT_MAGIC ? sizeof(struct fat_arch) : sizeof(struct fat_arch_64);
        for (uint32_t i = 0; i < count && sizeof(struct fat_header) + (i + 1) * entry <= data.length; i++) {
            const struct fat_arch *arch = (const void *)(bytes + sizeof(struct fat_header) + i * entry);
            uint32_t subtype = OSSwapBigToHostInt32((uint32_t)arch->cpusubtype);
            if (OSSwapBigToHostInt32((uint32_t)arch->cputype) == CPU_TYPE_ARM64 && (subtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E) return subtype >> 24;
        }
        return 0;
    }
    const struct mach_header_64 *header = (const void *)bytes;
    uint32_t subtype = (uint32_t)header->cpusubtype;
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 || (subtype & ~CPU_SUBTYPE_MASK) != CPU_SUBTYPE_ARM64E) return 0;
    return subtype >> 24;
}

/// A built-in arm64e image relabelled with the Dock's ABI. The two ABIs share an instruction stream, so
/// only the header changes; install() signs the result afresh.
static NSData *matchingDock(NSData *image)
{
    uint8_t dock = arm64eABI(@(kDockPath));
    if (!image || image.length < sizeof(struct mach_header_64) || !dock) return image;
    NSMutableData *copy = [image mutableCopy];
    struct mach_header_64 *header = copy.mutableBytes;
    uint32_t subtype = (uint32_t)header->cpusubtype;
    if (header->magic != MH_MAGIC_64 || (subtype & ~CPU_SUBTYPE_MASK) != CPU_SUBTYPE_ARM64E) return image;
    header->cpusubtype = (cpu_subtype_t)((subtype & ~CPU_SUBTYPE_MASK) | ((uint32_t)dock << 24));
    return copy;
}

static bool sipAllowsLoading(void)
{
    uint32_t config = 0;
    csr_get_active_config(&config);
    return (config & CSR_ALLOW_UNRESTRICTED_FS) && (config & CSR_ALLOW_TASK_FOR_PID);
}

static bool bootArgsAllowLoading(void)
{
    char args[2048];
    size_t length = sizeof(args) - 1;
    if (sysctlbyname("kern.bootargs", args, &length, NULL, 0) != 0) return false;
    return strnstr(args, kBootArg, length) != NULL;
}

static NSString *installedVersion(void)
{
    return [[NSBundle bundleWithPath:kPayload] objectForInfoDictionaryKey:@"CFBundleVersion"];
}

static int run(NSString *path, NSArray<NSString *> *arguments)
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return -1;
    [task waitUntilExit];
    return task.terminationStatus;
}

/// Runs a command and hands back its exit status, with stdout and stderr in `output`.
static int runCapturing(NSString *path, NSArray<NSString *> *arguments, NSString **output)
{
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        if (output) *output = error.localizedDescription;
        return -1;
    }
    // Read before waiting: a full pipe would otherwise hold the child up forever.
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (output) *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return task.terminationStatus;
}

/// The console user's uid: whose Dock this is, and who the socket is named after. As root (sudo, the
/// app's administrator prompt, or the launch daemon) that isn't the helper's own user.
static uid_t consoleUID(void)
{
    struct stat console;
    return stat("/dev/console", &console) == 0 ? console.st_uid : getuid();
}

static const char *consoleUser(void)
{
    struct passwd *pw = getpwuid(consoleUID());
    return pw ? pw->pw_name : NULL;
}

/// The console user's Dock, by executable path and owner; 0 when there's none (between a Dock exiting
/// and launchd starting the next one).
static pid_t dockPID(void)
{
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return 0;
    pid_t *pids = calloc((size_t)count + 64, sizeof(pid_t));
    count = proc_listallpids(pids, (int)(((size_t)count + 64) * sizeof(pid_t)));
    uid_t owner = consoleUID();
    pid_t found = 0;
    for (int i = 0; i < count && !found; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        struct proc_bsdshortinfo info;
        if (pids[i] <= 0 || proc_pidpath(pids[i], path, sizeof(path)) <= 0 || strcmp(path, kDockPath) != 0) continue;
        if (proc_pidinfo(pids[i], PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) && info.pbsi_uid == owner) {
            found = pids[i];
        }
    }
    free(pids);
    return found;
}

/// Asks the add-on in the Dock for its version over that user's socket; nil when nothing answers within
/// `wait` seconds. The loader can't tell whether the code it started in the Dock actually came up.
static NSString *answeringVersion(const char *user, NSTimeInterval wait)
{
    if (!user) return nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:wait];
    for (;;) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un address = { .sun_family = AF_UNIX };
        snprintf(address.sun_path, sizeof(address.sun_path), SA_SOCKET_PATH_FMT, user);
        struct timeval timeout = { .tv_sec = 1, .tv_usec = 0 };
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        char reply[64] = {0};
        ssize_t got = -1;
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
            const char ask[] = { 1, 0, SA_OPCODE_VERSION };   // int16 length 1, then the opcode
            if (send(fd, ask, sizeof(ask), 0) == sizeof(ask)) got = recv(fd, reply, sizeof(reply) - 1, 0);
        }
        close(fd);
        if (got > 0) {
            NSString *version = [[NSString stringWithUTF8String:reply] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
            if (version.length) return version;
        }
        if ([deadline timeIntervalSinceNow] <= 0) return nil;
        [NSThread sleepForTimeInterval:0.25];
    }
}

/// Ends the Dock and waits for launchd's replacement to finish starting, so the add-on can be loaded into
/// it straight away rather than on a second run.
static bool restartDock(void)
{
    pid_t old = dockPID();
    if (old) kill(old, SIGTERM);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while ([deadline timeIntervalSinceNow] > 0) {
        pid_t fresh = dockPID();
        if (fresh && fresh != old) {
            // Outside the user's session there's no "finished launching" to wait for: give it the time
            // it takes to start and settle before anything is injected.
            [NSThread sleepForTimeInterval:2.5];
            return true;
        }
        [NSThread sleepForTimeInterval:0.1];
    }
    return false;
}

/// Puts this helper's loader in place of the installed one when they differ. The loader never runs
/// inside the Dock, so a new one doesn't need the add-on reinstalled or the Dock restarted.
static bool refreshLoader(void)
{
    NSData *loader = matchingDock(embedded("__loader"));
    if (!loader) return false;
    if ([[NSData dataWithContentsOfFile:kLoader] isEqualToData:loader]) return true;
    if (![loader writeToFile:kLoader atomically:YES]) return false;
    chmod(kLoader.fileSystemRepresentation, 0755);
    run(@"/usr/bin/codesign", @[@"-f", @"-s", @"-", kLoader]);
    return true;
}

static bool install(void)
{
    umask(S_IWGRP | S_IWOTH);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSData *loader = matchingDock(embedded("__loader")), *payload = matchingDock(embedded("__payload"));
    if (!loader || !payload) {
        fprintf(stderr, "SunlightLiveWindows: the add-on isn't built into this helper\n");
        return false;
    }
    [fm removeItemAtPath:kBase error:nil];
    NSDictionary *attrs = @{NSFilePosixPermissions: @0755};
    if (![fm createDirectoryAtPath:[kBase stringByAppendingPathComponent:@"Contents/MacOS"] withIntermediateDirectories:YES attributes:attrs error:nil]
        || ![fm createDirectoryAtPath:[kPayload stringByAppendingPathComponent:@"Contents/MacOS"] withIntermediateDirectories:YES attributes:attrs error:nil]) {
        fprintf(stderr, "SunlightLiveWindows: couldn't create %s\n", kBase.UTF8String);
        return false;
    }
    NSString *bundlePlist = plist(@{
        @"CFBundleDevelopmentRegion": @"en", @"CFBundleExecutable": @"loader",
        @"CFBundleIdentifier": @"com.spacefarm.sunlight.live-windows", @"CFBundleInfoDictionaryVersion": @"6.0",
        @"CFBundleName": @"Sunlight Live Windows", @"CFBundlePackageType": @"osax",
        @"CFBundleShortVersionString": @OSAX_VERSION, @"CFBundleVersion": @OSAX_VERSION,
        @"OSAXHandlers": @{},
    });
    NSString *payloadPlist = plist(@{
        @"CFBundleDevelopmentRegion": @"en", @"CFBundleExecutable": @"payload",
        @"CFBundleIdentifier": @"com.spacefarm.sunlight.live-windows.payload", @"CFBundleInfoDictionaryVersion": @"6.0",
        @"CFBundleName": @"payload", @"CFBundlePackageType": @"BNDL",
        @"CFBundleShortVersionString": @OSAX_VERSION, @"CFBundleVersion": @OSAX_VERSION,
        @"NSPrincipalClass": @"",
    });
    bool ok = [bundlePlist writeToFile:[kBase stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES encoding:NSUTF8StringEncoding error:nil]
        && [payloadPlist writeToFile:[kPayload stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES encoding:NSUTF8StringEncoding error:nil]
        && [loader writeToFile:kLoader atomically:YES]
        && [payload writeToFile:kPayloadBinary atomically:YES];
    if (!ok) {
        fprintf(stderr, "SunlightLiveWindows: couldn't write the add-on into %s\n", kBase.UTF8String);
        [fm removeItemAtPath:kBase error:nil];
        return false;
    }
    for (NSString *binary in @[kLoader, kPayloadBinary]) {
        chmod(binary.fileSystemRepresentation, 0755);
        run(@"/usr/bin/codesign", @[@"-f", @"-s", @"-", binary]);
    }
    return true;
}

static int load(void)
{
    if (getuid() != 0) {
        fprintf(stderr, "SunlightLiveWindows: load needs to run as root\n");
        return 1;
    }
    if (!sipAllowsLoading()) {
        fprintf(stderr, "SunlightLiveWindows: System Integrity Protection's Filesystem Protections and Debugging Restrictions must be off\n");
        return 1;
    }
    if (!bootArgsAllowLoading()) {
        fprintf(stderr, "SunlightLiveWindows: the nvram boot-arg -arm64e_preview_abi is needed\n");
        return 1;
    }
    const char *user = consoleUser();
    // An add-on installed before a macOS update can carry the old Dock's ABI: reinstall it relabelled.
    uint8_t dockABI = arm64eABI(@(kDockPath));
    bool current = [installedVersion() isEqualToString:@OSAX_VERSION] && (!dockABI || arm64eABI(kPayloadBinary) == dockABI);
    if (current && [answeringVersion(user, 0) isEqualToString:@OSAX_VERSION]) {
        printf("SunlightLiveWindows: already loaded\n");
        return 0;
    }
    if (current && !refreshLoader()) {
        fprintf(stderr, "SunlightLiveWindows: couldn't update the loader in %s\n", kBase.UTF8String);
        return 2;
    }
    if (!current) {
        if (!install()) return 2;
        printf("SunlightLiveWindows: installed the add-on; restarting the Dock\n");
        if (!restartDock()) {
            fprintf(stderr, "SunlightLiveWindows: the Dock didn't come back within 15 s\n");
            return 3;
        }
    }
    pid_t dock = dockPID();
    if (!dock) {
        fprintf(stderr, "SunlightLiveWindows: there's no Dock running for the console user\n");
        return 4;
    }
    int status = run(kLoader, @[[NSString stringWithFormat:@"%d", dock]]);
    if (status != 0) {
        fprintf(stderr, "SunlightLiveWindows: couldn't load the add-on into the Dock (loader exit %d)\n", status);
        return 4;
    }
    if (!user) {
        printf("SunlightLiveWindows: loaded (no console user to check the socket as)\n");
        return 0;
    }
    NSString *answer = answeringVersion(user, 6);
    if (!answer) {
        fprintf(stderr, "SunlightLiveWindows: the add-on was started in the Dock but isn't answering at " SA_SOCKET_PATH_FMT
                        " (look for [sunlight-live] in the system log)\n", user);
        return 5;
    }
    if (![answer isEqualToString:@OSAX_VERSION]) {
        fprintf(stderr, "SunlightLiveWindows: the Dock is still running add-on %s, not %s; run `unload`, then `load` again\n",
                answer.UTF8String, OSAX_VERSION);
        return 6;
    }
    printf("SunlightLiveWindows: loaded (%s)\n", answer.UTF8String);
    return 0;
}

static int unload(void)
{
    if (getuid() != 0) {
        fprintf(stderr, "SunlightLiveWindows: unload needs to run as root\n");
        return 1;
    }
    [NSFileManager.defaultManager removeItemAtPath:kBase error:nil];
    pid_t dock = dockPID();
    if (dock) kill(dock, SIGTERM);
    printf("SunlightLiveWindows: removed the add-on; the Dock is restarting without it\n");
    return 0;
}

static int status(void)
{
    NSString *version = installedVersion();
    printf("Add-on: %s\n", version ? [[NSString stringWithFormat:@"%@ installed (this helper carries %s)", version, OSAX_VERSION] UTF8String] : "not installed");
    NSString *answer = answeringVersion(consoleUser(), 0);
    printf("In the Dock: %s\n", answer ? [[NSString stringWithFormat:@"answering (%@)", answer] UTF8String] : "not answering");
    uint8_t dock = arm64eABI(@(kDockPath)), installed = arm64eABI(kPayloadBinary);
    printf("Dock ABI: %s\n", dock ? [[NSString stringWithFormat:@"arm64e v%d%@", dock & 0x0f,
        installed && installed != dock ? [NSString stringWithFormat:@" (the installed add-on is v%d; `load` relabels it)", installed & 0x0f] : @""] UTF8String] : "unknown");
    printf("System Integrity Protection: %s\n", sipAllowsLoading() ? "allows loading" : "blocks loading (Filesystem Protections and Debugging Restrictions must be off)");
    printf("Boot arguments: %s\n", bootArgsAllowLoading() ? "allow loading" : "block loading (-arm64e_preview_abi is needed)");
    return 0;
}

/// Adds the boot argument for the next startup, keeping any others. It needs NVRAM protection off,
/// which the same `csrutil` command that turns off the other two protections does.
static int bootarg(void)
{
    if (getuid() != 0) {
        fprintf(stderr, "SunlightLiveWindows: bootarg needs to run as root\n");
        return 1;
    }
    if (bootArgsAllowLoading()) {
        printf("SunlightLiveWindows: the boot argument is already in effect\n");
        return 0;
    }
    NSString *current = nil;
    NSString *value = @"";
    // `nvram boot-args` prints "boot-args<tab>value", and fails when there are none.
    if (runCapturing(@"/usr/sbin/nvram", @[@"boot-args"], &current) == 0) {
        NSRange tab = [current rangeOfString:@"\t"];
        if (tab.location != NSNotFound) value = [[current substringFromIndex:NSMaxRange(tab)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if ([[value componentsSeparatedByString:@" "] containsObject:@(kBootArg)]) {
        printf("SunlightLiveWindows: the boot argument is set; restart the Mac to apply it\n");
        return 0;
    }
    NSString *updated = value.length ? [NSString stringWithFormat:@"%@ %s", value, kBootArg] : @(kBootArg);
    NSString *output = nil;
    if (runCapturing(@"/usr/sbin/nvram", @[[@"boot-args=" stringByAppendingString:updated]], &output) != 0) {
        fprintf(stderr, "SunlightLiveWindows: couldn't set the boot argument (%s); System Integrity Protection's NVRAM protection must be off\n",
                [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].UTF8String);
        return 1;
    }
    printf("SunlightLiveWindows: set the boot argument; restart the Mac to apply it\n");
    return 0;
}

// MARK: Launch daemon

/// What the app may ask the daemon for. Sources/Canvas/Setup/LiveWindowsService.swift mirrors it.
@protocol SunlightLiveWindowsXPC
- (void)runCommand:(NSString *)command reply:(void (^)(int status, NSString *output))reply;
@end

/// The team this helper is signed by; nil when ad-hoc. Callers must share it.
static NSString *ownTeam(void)
{
    SecCodeRef code = NULL;
    SecStaticCodeRef staticCode = NULL;
    CFDictionaryRef info = NULL;
    NSString *team = nil;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) == errSecSuccess
        && SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &staticCode) == errSecSuccess
        && SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &info) == errSecSuccess) {
        team = [((__bridge NSDictionary *)info)[(__bridge NSString *)kSecCodeInfoTeamIdentifier] copy];
    }
    if (info) CFRelease(info);
    if (staticCode) CFRelease(staticCode);
    if (code) CFRelease(code);
    return team;
}

static NSString *ownPath(void)
{
    char path[PROC_PIDPATHINFO_MAXSIZE];
    return proc_pidpath(getpid(), path, sizeof(path)) > 0 ? @(path) : nil;
}

@interface Daemon : NSObject <NSXPCListenerDelegate, SunlightLiveWindowsXPC>
@property (copy) NSString *requirement;
@end

@implementation Daemon {
    dispatch_queue_t _queue;
    NSUInteger _generation;
}

- (instancetype)init
{
    if ((self = [super init])) _queue = dispatch_queue_create("com.spacefarm.sunlight.live-windows", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection
{
    // The system checks the caller's signature on every message, not once at connect.
    [connection setCodeSigningRequirement:self.requirement];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SunlightLiveWindowsXPC)];
    connection.exportedObject = self;
    [connection resume];
    return YES;
}

/// One command at a time, each in a child process of this helper, so its output can go back to the app
/// and a crash in one doesn't take the daemon with it.
- (void)runCommand:(NSString *)command reply:(void (^)(int, NSString *))reply
{
    if (![@[@"load", @"bootarg"] containsObject:command]) {
        reply(64, @"SunlightLiveWindows: the daemon runs only load and bootarg");
        return;
    }
    dispatch_async(_queue, ^{
        NSString *output = nil;
        NSString *path = ownPath();
        int status = path ? runCapturing(path, @[command], &output) : -1;
        reply(status, output ?: @"SunlightLiveWindows: couldn't find its own executable");
        [self exitWhenIdle];
    });
}

/// launchd starts the daemon again on the next request, so it doesn't stay around between Dock restarts.
- (void)exitWhenIdle
{
    NSUInteger generation = ++_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), _queue, ^{
        if (self->_generation == generation) exit(0);
    });
}
@end

static int daemonMain(void)
{
    NSString *team = ownTeam();
    if (!team.length) {
        fprintf(stderr, "SunlightLiveWindows: the daemon needs a team signature to know which app to answer\n");
        return 1;
    }
    Daemon *daemon = [[Daemon alloc] init];
    daemon.requirement = [NSString stringWithFormat:
        @"anchor apple generic and identifier \"%@\" and certificate leaf[subject.OU] = \"%@\"", kAppIdentifier, team];
    NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:kMachService];
    listener.delegate = daemon;
    [listener resume];
    [daemon exitWhenIdle];
    [NSRunLoop.currentRunLoop run];
    return 0;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        const char *command = argc > 1 ? argv[1] : "";
        if (!strcmp(command, "load"))   return load();
        if (!strcmp(command, "unload")) return unload();
        if (!strcmp(command, "status")) return status();
        if (!strcmp(command, "bootarg")) return bootarg();
        if (!strcmp(command, "daemon")) return daemonMain();
        fprintf(stderr, "usage: SunlightLiveWindows load | unload | status | bootarg | daemon\n");
        return 64;
    }
}
