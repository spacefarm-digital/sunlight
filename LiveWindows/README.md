# Live windows

Sunlight can render its managed windows as live WindowServer surfaces, with its existing canvas
handling the camera, hit testing, labels and controls. This is **Scaled real windows**, the default renderer
once the add-on below is loaded (Settings › Live Windows shows its state); until then the canvas uses
capture proxies (preview mode). Sunlight only switches to it while the loaded add-on answers the
live-window protocol v1 capability request. Selecting live mode at launch does not
request Screen Recording, enumerate ScreenCaptureKit content, start streams, or take screenshots.
Accessibility is still used for focus, close, window metadata and widget actions.

The canvas's `worldRect` is in **world coordinates**. The target is `camera.toScreen(worldRect)`.
Widget margins are expanded before this mapping because the transform applies to the entire window.
The native rectangle stays unchanged during camera movement; only the surface transform changes.

## Source and build

The add-on and its loader are Sunlight's own code in `osax/`, adapted from yabai's scripting addition
(the macOS 27 fork at LCS-Dev-Ergos/yabai, commit 8135286; MIT, see `osax/LICENSE-yabai.txt`):

- `osax/payload.m`: runs inside the Dock. It keeps yabai's socket daemon and envelope and drops the
  rest: the search through the Dock's own code for its Spaces objects (the part that broke with each
  macOS release and needed a fork), the patching of the Dock's animation-time instruction, and every
  operation Sunlight never sends. What stays answers the version (`0x01`), moves (`0x06`), orders
  (`0x10`), and dispatches `osax/sunbeam.h` (written for Sunlight), the live-window protocol below.
  Compared with the original, messages are length-checked before their fields are read, a vanished
  peer can't SIGPIPE the Dock, and a stalled one can't hold the listener.
- `osax/loader.m`: injects the payload into the Dock. Built arm64e, as the Dock is, so it shares the
  Dock's library addresses. `scripts/build-live-windows.sh` then pins the payload and the loader to PAC
  ABI v0 (Mach-O caps `USR00`). The Dock on macOS 15 is v0, and Xcode 26 stamps arm64e executables as v1;
  the kernel will not inject v1 into that Dock, so the loader exits 1. The two ABIs share an instruction
  stream, and only the capability byte differs.
- `osax/common.h`: opcodes, the 4096-byte buffer, the socket name (`/tmp/sunlight-live_<user>.socket`)
  and the add-on version, which the helper compares with what's installed.
- `helper.m`: `SunlightLiveWindows`, the one program that runs as root, through sudo or as the launch
  daemon. The payload and loader are built into its `__TEXT` segment, so the sudoers rule's hash covers
  everything. A newer built-in loader replaces the installed one without reinstalling the add-on.

The stock `0x0D` scale operation is a thumbnail toggle. It is **never used** for camera updates.

```sh
make app                       # builds the helper (scripts/build-live-windows.sh) into Sunlight.app
build/Sunlight.app/Contents/Helpers/SunlightLiveWindows status
build/Sunlight.app/Contents/MacOS/Sunlight --renderer-status
```

Bump `OSAX_VERSION` in `osax/common.h` whenever the payload changes: the helper reinstalls the add-on
only when the installed version differs.

## Installation boundary

`SunlightLiveWindows load`, as root, writes `/Library/ScriptingAdditions/Sunlight.osax` if the
installed version differs (restarting the Dock, which drops whatever was loaded, and waiting for the
new one), then injects the payload into the running Dock. It needs System Integrity Protection's
Filesystem Protections and Debugging Restrictions off and the `-arm64e_preview_abi` boot argument, and
says which is missing. Sunlight runs it itself (see Dock restarts below); from a terminal,
`sudo …/SunlightLiveWindows load`. `SunlightLiveWindows unload` removes the add-on and restarts the
Dock without it. A `yabai.osax` from an earlier setup is left alone.

Only `Sunlight live-window protocol v1: available` from `--renderer-status` confirms the payload is
loaded and answering.

For a single launch without changing preferences:

```sh
CANVAS_RENDERER=realWindows CANVAS_TAKEOVER=light build/Sunlight.app/Contents/MacOS/Sunlight
```

`CANVAS_TAKEOVER=light` avoids takeover's Dock/Finder preference changes. It does not install or load
the addition. If live mode is unavailable, the app uses capture proxies and requests Screen Recording
if needed. Reopen Settings to check availability again, then select the mode to retry a connection.

**Full takeover:** applying or restoring the existing takeover preferences can restart Dock and
unload the addition. Start full takeover first, load the prepared addition into the resulting Dock,
then open Settings and select **Scaled real windows**. This sequence was tested on the target Mac.
The app restores its live windows before its orderly quit restores takeover preferences.

**Dock restarts.** Every Dock restart unloads the addition. While Scaled real windows is selected,
Sunlight watches the Dock's process ID; when a new Dock appears it falls back to capture proxies, waits
for the Dock to settle, runs the helper's `load`, and returns to live windows once the
capability probe answers. Takeover releases the live windows itself before it restarts the Dock, so
no lease dies holding transforms; a Dock restart from elsewhere still should not happen while a lease
owns transforms (see Protocol v1). If takeover restarted the Dock before Sunlight could watch it, the
first renderer check that finds the addition missing tries a reload the same way.

If the Dock goes down three times in a row while a load runs or within a minute of one (`DockCrashGuard`),
Sunlight takes the add-on to be what brings it down and stops loading it by itself, staying on capture
proxies and saying so on the canvas. The pause is remembered across launches for that add-on version
(defaults key `LiveWindowsPausedForAddition`) and shows in Diagnose; Reload Live Windows… or the setup's
Load page lifts it, and a build carrying a new add-on version tries again by itself.

The reload needs root. In builds signed with a team identity, the helper is also a launch daemon
(`Contents/Library/LaunchDaemons/com.spacefarm.sunlight.live-windows.plist`, `SunlightLiveWindows daemon`)
that the app registers with SMAppService. Once the user turns it on in System Settings › General › Login
Items, the app asks it over XPC (Mach service `com.spacefarm.sunlight.live-windows`) to run `load` or
`bootarg`, with no prompt. The daemon accepts only callers signed by its own team with Sunlight's bundle
identifier, runs only those two commands, and quits a minute after the last one. It finds the Dock by path
and owner and passes its pid to the loader, since LaunchServices doesn't list the Dock outside the user's
session. Choosing Reload Live Windows… registers the daemon and opens Login Items when it isn't on yet.

Ad-hoc builds have no daemon. There, `sudo -n SunlightLiveWindows load` runs without a prompt where sudoers allows
it. The first time it doesn't, Sunlight shows the administrator prompt itself (once per Dock); that
prompt loads the add-on and installs `/private/etc/sudoers.d/sunlight-live-windows`, a rule for exactly
`<helper> load` pinned to the helper's SHA-256 (as yabai's documentation does), so later reloads are
silent. A rebuilt helper has a new hash, so the app asks once more. If the prompt is cancelled, nothing
asks again until the next Dock restart; **Sunlight › Reload Live Windows…** asks on demand, and says so
if the reload fails. `--renderer-status` reports which of the two applies.

## Protocol v1

All messages use yabai's existing `int16 length` (not including the length field), one-byte opcode,
then native-endian `memcpy` fields with **no padding**. Both supported Mac architectures are little
endian. The socket is `/tmp/sunlight-live_<username>.socket`. Stock move (`0x06`) and order
(`0x10`) keep yabai's encoding, and `0x01` answers with the add-on's version and a newline; every
other stock opcode is gone, so the add-on ignores it. Arbitrary transforms use the extension below.

| Opcode | Payload | Response / lifetime |
|---|---|---|
| `0x70` capability | none | nine bytes `SUNBEAM1\n`, then close |
| `0x71` lease | none | same magic; transfers socket to a dedicated session thread |
| `0x72` snapshot | `uint32 backdrop`, `uint32 overlay`, `uint16 count`, since sunlight-8 optionally `uint8 flags` (bit 0: full), then `count × (uint32 id, float32 a,b,c,d,tx,ty)` | one byte: 0 applied, nonzero identifies the rejected stage |
| `0x73` handoff | `uint32 id`, `float32 x,y`, and since sunlight-3 optionally `uint32 overlay, backdrop` | commit native position and identity transform, restore all other leased windows; with the canvas's IDs also order the backdrop under the overlay and the window above it. Since sunlight-5 all of it is one window-server transaction, and the window needn't be leased: it is taken to its place from wherever it is. Acknowledge; 7 only when the window is gone or won't move |
| `0x74` shadow (since sunlight-7) | `uint32 id`, `float32 inactiveWeight, activeWeight`, then the window's two standard looks, each `float32 radius, density, rimDensity, verticalOffset` | rewrites the window's two shadow looks (`SLSWindowSetShadowProperties`, the whole dictionary AppKit writes), each set its weight of the way from the standard inactive look to the standard active one; 0 and 1 are the window's own. One byte: 0, 1 for a request that makes no sense, 8 when the window is gone or the window server won't, 9 for a window whose shadow isn't the standard kind (left alone); the lease goes on either way |

Snapshots contain at most 128 windows, in canvas back-to-front order. Entries use the WindowServer
inverse mapping: `a = d = 1/zoom`, `b = c = 0`, `tx = -targetX/zoom`, `ty = -targetY/zoom`.
A zero-window snapshot releases everything, and since sunlight-3, if it names the backdrop and overlay, orders the backdrop under the overlay — first, since sunlight-5, so the windows go back out of sight under it. An entry absent from a later snapshot is restored.

Since sunlight-8 a snapshot may carry a flags byte (its length says so). With bit 0 set it is **full**: every leased window, level and stacking asserted for each, an absent one restored. Without it the snapshot is **partial**: only the transforms in it change, in one window-server transaction when SkyLight has them (one by one under the update freeze otherwise), and the windows it leaves out stay leased where they are; an empty partial snapshot is a keepalive. The canvas sends a full snapshot when its window set or order changes, when a window is parked off screen or woken (a window more than a screen away from the view is left out of partial snapshots at the transform it was last sent), when the window server's listing shows an order it didn't ask for, and once the camera has been still for a second; a partial one otherwise. A partial snapshot naming a window the session hasn't taken, or arriving on a session that has taken none, is done in full for what it carries. A snapshot without the flags byte is taken the old way: the whole set every time, with level and stacking reasserted at most once a second.
Malformed lengths, duplicate IDs, nonfinite values and invalid scales are rejected before mutation.
Window owner connection IDs are checked before subsequent updates/restoration to reduce ID reuse risk.

Since sunlight-11 a full snapshot also lifts the canvas: the backdrop, every leased window and the overlay go to window level 1 (`SUNBEAM_LEVEL`), one above the normal level where app windows live. A window an app opens is ordered in at the front of its level, so at the normal level it was born on top of the canvas at full size and showed there until the canvas had listed it and a snapshot had scaled it, a frame or two however fast the canvas reacted; one level down, it is born behind the backdrop and first shows once a snapshot has scaled and lifted it. The handoff and the release bring everything on show back to the normal level (the entered window's own new windows then come up in front of it as they always did), levels first in the transaction, since an order against a window at another level does nothing; and an empty full snapshot may carry, after its flags byte, the pid of the app that took the front, so the canvas comes down under that app's windows rather than on top of them. The app's own `NSWindow.level` never changes; it lowers its two windows itself if a lease ends without the add-on doing it.

Since sunlight-12 a window that isn't on screen is never given a place in the order. The canvas keeps a window it is minimizing leased through the Dock's animation (the Dock warps the window itself, in place, and it leaves the screen only as the animation ends) and hands it back once it has gone; from the Dock's connection, ordering a minimized window brings it back on screen behind its app's back, which is what happened on every release of one. Such a window gets its level and transform back, which the Dock keeps through the minimize and the restore, and nothing else; the same goes for a leased window that has left the screen by the time a full snapshot places it, and for a hidden app's windows.

The payload saves each acquired window's transform, level and lower neighbour (the nearest window under it at its own level, never the canvas's own windows). On release the window goes back above that neighbour if it is still on screen at that level and isn't the window being entered, else straight under the backdrop (since sunlight-4; ordering against a gone, off-Space, other-level or canvas window left the released window on top of everything). Its place is set before its transform, so the jump back to native size happens out of sight.

The handoff and the end of a lease go through SkyLight's transaction API (`SLSTransactionCreate` … `SLSTransactionCommit`, the prototypes yabai uses; weakly linked, with one-by-one calls as the fallback), because the Dock's `SLSDisableUpdate` freeze doesn't keep the compositor from showing a step in between: a screen recording caught the entered window missing for one frame, between its restore and its raise, on two entries in seven. Even without a transaction the steps go in an order whose in-between states look like the state before or after: the entered window above the canvas (the canvas is almost clear, so that shows nothing), then its settled transform (its native position was moved first, which the transform in force hides), then the backdrop up under the canvas (the moment the other windows leave), then the others put back under the backdrop. Full frames still use the freeze; partial ones (sunlight-8) go through a transaction, so every window moves in the same screen update.

Shadows (sunlight-7): macOS keeps two shadow looks per window, which AppKit sets once as the window is made (`SLSTransactionSetWindowShadowProperties`; for a titled window radius 8, density 0.22, offset 7 inactive, and 20, 0.4, 18 when key), and the window server switches between them in one frame as the window becomes or stops being key (`SLSTransactionSetWindowActiveShadowLegacy`, called by AppKit) — at the seam, right after the entered window has stopped growing, a shadow blink. The canvas sends a shadow request after each frame of a flight in, easing the window's inactive look towards the active one, both the active one just before the handoff, so the switch as the window becomes key changes nothing; then, once the activation has landed, the standard pair again (invisible: the active look is the one shown). Before it activates itself from an entered window it sends five, a frame apart, easing the active look back to the inactive one, so the switch back changes nothing either, and the standard pair again once it is in front. A window put back under the canvas with other looks in force (a flight cut short) gets its standard ones back there, out of sight. The window server's shadow parameters as read (`SLSGetWindowShadowAndRimParameters`, the active look's density and offset) tell a titled window from a panel or a shadowless window, which are left alone. A session owns only
the window IDs Sunlight sends. It promotes widgets to the normal window level for the session and
orders the managed live surfaces between Sunlight's opaque backdrop and almost-transparent input
window. The original levels/transforms are restored on release. The accept thread keeps serving version, move and
order requests; a separate worker serves each lease.

Since sunlight-13 there is a lease per canvas: Sunlight has a canvas on every display, each with its own
backdrop, overlay and windows, and each holds a lease of its own. Up to eight leases at once, all from
the process that took the first (`LOCAL_PEERPID`); another app, or another copy of Sunlight, is turned
away while they last, as a second lease was before. Every request, from whichever lease, is applied
under one mutex, so the window server sees one lease's changes at a time; a lease ending puts back only
the windows it took. Before sunlight-13 only the main display's canvas has live windows, and the others
show captured pictures.

Since sunlight-14 the windows a handoff or a release puts back in a transaction get their native size
only after the commit (and after the orders are redone directly), one call each, where they are already
under the backdrop. A transaction that also changes levels can land a window's level change after its
order, which puts it at the front of the normal level, over the canvas, for one frame before the redo:
at native size that was the window just left flashing full-size behind the one being entered, caught
on a screen recording of quick ⌘Tab taps. At the canvas's transform it shows only where the canvas
already drew it.

Since sunlight-15 the handoff's native moves (the entered window to its point, and the windows kept on
show to theirs) go in the same transaction as the settled transforms, each move just before its
transform (`SLSTransactionMoveWindowWithGroup`; direct, as before, where SkyLight lacks it). The window
server keeps a transform relative to the window's native origin, so a window moved natively while a
transform is in force shifts on screen by as much as the move until its transform is set again. Made
directly before the transaction, the move put the entered window, natively wherever it was last used,
off the screen for the few milliseconds until the commit: on a frame boundary, one frame of wallpaper
where the window and the ones kept with it had been, caught on a screen recording of one switch in
four. Where the window lands elsewhere than asked (an app can clamp a move) it is drawn where it landed
with one direct call after the commit, as it was before.

Since sunlight-40 a lease can set the alpha of the windows it holds (opcode `0x75`: a count, then a
window ID and an alpha from 0 to 1 for each, relative to the window's own alpha, read the first time).
The canvas fades windows in as they open and out as they close from the canvas. Whatever alpha it set
goes back to the window's own whenever the window is given back: put back under the canvas (a frame
leaving it out, a release), handed off (the entered window and the ones kept on show too), or the lease
ending. A window the lease doesn't hold is passed over. Older add-ons open and close windows with
transforms alone.

The driver has one pending-frame slot on a serial worker. It replaces stale pending frames, rather
than queuing an animation history. Connect/send/receive waits are bounded at 250 ms; frames carry an
acknowledgment. A 0.5-second idle heartbeat keeps the lease alive. Disconnect, malformed input, or
three seconds without a full request restores leased windows **while Dock remains alive**. A Dock
crash/restart destroys this in-memory recovery state; that failure needs target-machine validation.
Mode changes, deactivation, sleep, widget-gallery entry and orderly quit explicitly release the lease.

## Verification

Automated checks that do not require installation:

```sh
swift test
clang LiveWindows/test-session.m -framework CoreGraphics -framework CoreFoundation -o /tmp/sunbeam-session-test
/tmp/sunbeam-session-test
```

The payload harness uses real sockets and fake WindowServer calls. It verifies fragmented messages,
disconnect cleanup, invalid-transform rejection, native-scale handoff, lease expiry and isolation of
unmanaged IDs. Swift tests cover packing, inverse camera transforms, widget margins, limits, missing
and stock sockets, fragmented capabilities, wrong protocol versions and stalled peers.

After the extension is actually loaded, this test creates only its own test windows:

```sh
clang LiveWindows/smoke-live.m -framework Cocoa -F/System/Library/PrivateFrameworks -framework SkyLight -o /tmp/sunbeam-smoke-live
/tmp/sunbeam-smoke-live
```

It animates 300 live transforms through the Dock socket, reads back the WindowServer transforms,
checks exact disconnect restoration, measures round-trip latency and checks native-scale handoff.
`LiveWindows/seam-test.m` (built the same way) runs handoffs on its own windows while a thread polls the
subject's transform at ~20 µs, and prints every distinct drawn position: a line marked "off its spot" is
the window off screen between its native move and the commit, which sunlight-15 removed.

No ScreenCaptureKit API is used. This is a prerequisite to, not a replacement for, testing Sunlight's
full canvas: pan/zoom/drag, enter/return, new/closed windows, widgets, sleep, mode switches and quit.
Verify the purple capture indicator is absent and live content updates. Keep an unmanaged window
outside the test to check it stays unchanged. Native fullscreen and other Spaces are outside this
primary-display spike's acceptance scope. Visual smoothness is not established by compilation.

Current proof boundary: 11 Swift tests, the payload harness and both builds pass. The installed
revision 2 passed repeated app handoffs and returns in the full canvas. The user confirmed scaled
windows were visible and usable during pan/zoom; WindowServer readback confirmed actual scaling and
native-scale restoration on quit. Full takeover was then enabled, the addition reloaded, and Settings
switched from capture to live mode with native scaling verified again. See
[the validation log](VALIDATION.md) for evidence and remaining limits.
