# How Sunlight works

The long version: how the canvas is drawn, every control, the modes, and what each part costs. For a
short introduction see the [README](../README.md); to install a release see [INSTALL.md](../INSTALL.md).

## Rendering

An infinite, zoomable canvas of **real macOS windows and desktop widgets**, always on, with handoff to the
real window at 1:1. Public APIs almost everywhere: ScreenCaptureKit for live window textures, Accessibility
for moving/raising windows and using widgets. One-shot proxy refreshes can use a private window-server call,
SkyLight's `SLSHWCaptureWindowList` (looked up at runtime, with ScreenCaptureKit as the fallback); the
**Capture Method** submenu in the menu bar menu switches between them. This renderer needs no SIP changes, no virtual displays
and no entitlements; live windows (below) do need SIP partly off.

Screen capture mode is a feature flag, off by default (Settings › Live Windows › **Mode**:
Screen capture, defaults key `ScreenCaptureMode`): with Live windows chosen, Sunlight always asks for **Scaled
real windows** (below).
While the live-window add-on isn't answering (being loaded, or after a Dock restart) the canvas falls back
to capture proxies without any stream: each window and widget is a still, one renewed a second in turn.
Choosing Screen capture turns the flag on together with the capture renderer, and up to eight windows, the
largest on screen, stream live.

A fresh install starts in **preview mode** instead: until live windows have loaded once on the Mac
(defaults key `LiveWindowsEverLoaded`), the capture renderer streams as in screen capture mode, so
Sunlight can be tried with nothing but Accessibility and Screen Recording granted. A card in the canvas's
bottom-left corner (the minimap has the other one) says "Demo mode" under a warning triangle, over a
two-column table of demo against the full version (screen recording API streams against the real windows; only the 8 largest on screen streaming at 30 fps
against every window at full refresh rate; the rest once a second against always live; about 20% more
energy while panning, as measured on a Mac), with a Use Full Version button that leads to
Set Up Sunlight's live-windows steps. It can't be closed, and goes when preview mode does.
`Sunlight --preview-mode` shows preview mode for one launch on a Mac already set up for live windows.
Preview mode ends by itself the first time the add-on answers; after that the stills rule above
applies. Nothing is loaded into the Dock without being asked while it lasts.

The **Scaled real windows** renderer, the default, uses Sunlight's own Dock
add-on, built into the app, to transform live windows without capture or Screen Recording. It requires
the machine configuration described in [LiveWindows/README.md](../LiveWindows/README.md); the capture
renderer retains the requirements above. A missing or incompatible add-on falls back to
capture proxies. Desktop widgets are the exception: Notification Center keeps them in the desktop's band,
where the add-on can't show them among the app windows, so they stay captured (they need Screen
Recording) and are drawn on the backdrop, under the real windows. The guide covers how it's built and
loaded, the protocol, recovery and test boundaries.

## The model

- The canvas is a full-screen borderless window at *normal* level. While Sunlight is the active app it covers
  every real window and draws each one as a live proxy.
- **Entering a window** animates the camera to 1:1 with its proxy, AX-moves the real window to that exact
  rect while it's still hidden behind the canvas, then activates its app. The real window rises above the
  canvas, pixel-matched. Every other window stays hidden behind the canvas. You now work in the real window.
- **Coming back** (click the canvas, ⌘-tab to Sunlight, or the Mission Control key) activates Sunlight again, so the canvas is in
  front with the proxy already where the real window was. If you moved the window while it was real, the
  proxy follows — the real desktop is the source of truth for the window you're in.
- World coordinates are screen coordinates at the identity camera, so at launch the canvas *is* your
  desktop at 1:1. It then pulls back slightly so it reads as a canvas.
- **A proxy streams only while its window is behind the canvas.** macOS marks a streamed window with a
  purple capture pill in place of its traffic lights, for as long as the stream runs — with either
  window-scoped filter (measured on 27.2; a display-scoped stream and one-shot captures don't). The
  pill is drawn in the window's own title bar, so behind the canvas it's invisible. When an app is about
  to come in front (handoff, or an absorbed activation) its streams stop, and one-shot captures refresh
  those proxies a few times a second instead — no pill. They use SkyLight's private
  `SLSHWCaptureWindowList` (~12 ms, works on any macOS, 1x pixels for a proxy drawn small), falling back
  to `SCScreenshotManager` (~30 ms, macOS 26+) if the symbol is missing or returns nothing; either way the
  menu-bar privacy dot shows, the title-bar pill doesn't. The first sync after the canvas is back in front
  restarts every stream.
- **Desktop widgets are on the canvas too.** Notification Center draws each widget you've put on the
  desktop in a borderless window of its own, below every app window, so it streams like one (always: it's
  always behind the canvas, and it has no title bar for a pill). Its proxy is cropped to the card, labelled
  with the widget's name, and drags, stacks, hovers and frames like a window's. A widget can't be entered —
  it lives below every window, so activating anything never brings it in front of the canvas — so it's used
  where it is instead: a click on its proxy is passed to the real widget through Accessibility (see
  Controls). Accessibility names each widget and its app (`widget-local:<app>:<extension>:<kind>`).
- **Finder's desktop is the floor.** The files on the desktop, with their Stacks, tags and selection, sit
  under every window and widget, trimmed to the part of the desktop that has files on it, and pan and zoom
  with everything else. Finder draws them in a screen-sized window of their own
  at the desktop-icon level with a clear background (the wallpaper is Window Manager's window), so the
  floor is that window, captured from under the canvas with SkyLight's one-shot capture (`DesktopFloor`;
  about 11 ms at 1x, 35 ms at 2x on 27.2, no capture pill). Nothing announces a change on the desktop:
  it's captured again every 2 s while the canvas is in front and the floor is in view, and as soon as the
  canvas is back from a window. It needs Screen Recording, like widgets, and is drawn on the backdrop under
  the widgets in live mode. **Sunlight › Desktop Files** turns it off. **Show Desktop** (F11, the
  four-finger spread) flies there and dims everything over it, with the files lit above the dim. The files
  work as on the desktop (see Controls): Accessibility lists them with their frames and selects them in
  Finder, Sunlight does the opening, menus and file operations itself, and a drag of files lifts off as a
  real drag. Held over a window for 0.6 s, the drag enters that window where it is, and the canvas lets the
  pointer through for the rest of the drag so the drop lands in the real window (macOS doesn't reorder
  windows during a drag, so the window can't come above the canvas until it ends). Renaming, making a
  folder or moving to the Trash may bring up macOS's prompt for access to the Desktop folder once.
- **The files and the widgets each have a place (Settings › Canvas › Desktop).** Each is one block that
  keeps the desktop's own arrangement: the files as Finder lays them out, the widgets as they sit on the
  desktop relative to each other (`DesktopPlacement`). The setting is a map of the whole canvas at true
  proportions: the windows (a Screen box when there are none) and both blocks drawn to scale, with half the
  windows' size spare around them, and a dot for each block: blue for the files, orange for the widgets. Drag a dot and let go, and the block glides to be centred there:
  outside the windows it's beside them, pushed straight out to sit 80 pt clear if it would overlap them;
  inside, it's under them. Where the two blocks would meet, the files move clear of the widgets. Spots are
  relative to the windows' bounds, so the blocks follow the windows as they settle; with no windows they're
  relative to the screen at 1:1. Reset puts both back: the files to the right of the windows and the
  widgets to the left, near the top, as macOS lays them out. A drag on a widget pans the canvas, and
  windows neither push it nor line up with it. Show Desktop flies to the files, Fit All takes them in, and
  the minimap shows them as a faint patch.
- **The minimap is the one thing that doesn't move.** Bottom right, in screen space: every window and
  widget as a small shape (a window with its app's icon in the middle), the desktop's files as a faint
  patch, the screen as an outline, the zoom readout. Click to look there, drag to pan.
- **Hidden and minimized windows keep their place.** Hide an app (⌘H) or minimize a window into the
  Dock (⌘M) and its windows leave the canvas but not their spots: the minimap shows each as a dashed
  outline, and unhiding the app or restoring the window from the Dock puts it back exactly there.

## Build & run

```
make run
```

Needs macOS 15+ (built on 26), Xcode 16+ command-line tools. The Makefile wraps the SwiftPM binary in a
minimal `.app` bundle so TCC can attach permissions to it; a build in a checkout is never offered the
move to Applications a downloaded copy gets. First launch opens **Set Up Sunlight**, a
full-screen wizard, one step to a screen over a field of slow light that rises as the steps are done:
Accessibility and Screen Recording first, then the canvas in preview mode; live windows (why SIP goes
partly off, the background helper, the Recovery restart, the boot argument, then the load, which runs by
itself) from the demo mode card on the canvas, with the menu bar's rays filling one per step. Settings › Live Windows
shows the progress and the setup log, **Diagnose…** copies a plain-text report for an issue, and
**Settings › General › Uninstall Sunlight…** walks the whole install back. `Sunlight --setup-preview <scenario>`
shows every page against a made-up Mac. To install a release instead, see [INSTALL.md](../INSTALL.md).

The build signs with the first Developer ID Application or Apple Development identity in your keychain, so
the grants carry over to the next build. With neither it signs ad-hoc, and a rebuild can invalidate the
grants (the toggle stays on but silently does nothing): if windows stop capturing or moving after a
rebuild, remove and re-add Sunlight in the two privacy panes. `SIGN="Apple Development: …"` picks an
identity, `SIGN=-` forces ad-hoc. With a real identity everything is signed with the hardened runtime, and
the live-windows helper also ships as a launch daemon the app registers with SMAppService (one switch in
Login Items, no password). An ad-hoc build has no daemon: its helper is signed ad-hoc, so its hash, and the
passwordless sudoers rule pinned to it, only change when its code does.

### Packaging

```
make package
```

builds `build/Sunlight.app` (icon, Info.plist, signed as above) and packs it
as `build/Sunlight-<version>.zip` and `build/Sunlight-<version>.dmg`; the version is
`CFBundleShortVersionString` in `Info.plist`. `make dist NOTARY_PROFILE=<profile>` notarizes and staples
both and adds Sparkle's appcast and the Homebrew cask (see [INSTALL.md](../INSTALL.md#building-a-release-maintainers)). `make app` stops at the bundle. The icon is
`Resources/Sunlight.icon`, made in Icon Composer: a sun of three glass layers (disc, long rays, short rays)
on a flat yellow fill, black on yellow by default, yellow on near-black in dark mode and white in the clear
and tinted looks. With Xcode 26 or later, `make app` compiles it with actool into `Assets.car`; without, the
bundle gets the checked-in `Resources/Sunlight.icns`, which `make icon` refreshes from the `.icon`.

Live windows are built in: `Contents/Helpers/SunlightLiveWindows` carries the Dock add-on and loads it
(see [LiveWindows/README.md](../LiveWindows/README.md)). When the add-on isn't loaded in the Dock,
Sunlight loads it through the helper's launch daemon once it's turned on in Login Items. Builds without
the daemon ask for an administrator password once instead: that loads it and adds a sudoers rule for exactly
that helper's `load`, pinned to its SHA-256, so later Dock restarts reload it silently.

### Coming from Canvas

Sunlight was called Canvas (`com.spacefarm.canvas-spike`). Its first launch copies the old settings and
`~/Library/Application Support/Canvas` across, takeover state included, and quits a running Canvas.app.
macOS treats it as a new app, so grant Accessibility and Screen Recording again. If Canvas was a login item
from takeover mode, remove it in System Settings › General › Login Items; Sunlight registers its own.

## Controls

Sunlight has no Dock icon: it runs from the sun-rays icon in the menu bar. A click opens a small panel, Control Center's way: the Sunlight switch (off, the canvas goes away, every window stays where it is at 1:1 and ⌘Tab, the Mission Control key, F11 and the ⌃⌥ keys are the Mac's own again; on, it's all back, nothing restarts), Minimap, ⌘Tab (the icon strip; off, ⌘Tab still flies between windows, just without it; also Settings › Canvas) and Desktop (Show Desktop) as three round controls in one row, Tidy below them (with Arranging on), Layouts (each saved layout a round button, three to a row, Save always there), How to Use and More: Strip Mode (with strip mode on), Arrange (with Arranging on), Settings, setup, updates, Reload Live Windows, takeover and Quit. Desktop files, the key list (Settings › How to use › Keyboard) and Uninstall are in Settings only. A right-click on the icon opens More's rows as a menu. The ⌘ keys (⌘, ⌘S ⌘1–⌘9 ⌘Q) still work while the canvas is in front.

| | |
|---|---|
| pinch, ⌥-scroll, ⌘-scroll | zoom around the pointer |
| two-finger scroll, drag empty space | pan |
| four-finger drag, any direction | pan from anywhere: over windows too, and from inside a window (the canvas comes back first, as with the Mission Control key). A drag near horizontal stays level, near vertical stays plumb. macOS's four-finger swipes (Mission Control, Spaces, the Launchpad pinch) are held off while Sunlight runs |
| four-finger tap | see everything, as the Mission Control key: from a window, the canvas with everything fitted; tapped again on the canvas, back into the window you came from. Four fingers that land together, don't move and lift within 0.3 s; a resting hand isn't a tap. Settings › How to use can make this a four-finger swipe up instead (Mission Control's own gesture): then a quick stroke up of about 2 cm within a third of a second is See All and a slower drag up still pans, as Mission Control itself follows a slow swipe instead of opening |
| four-finger spread (thumb and three fingers apart) | Show Desktop, as F11 (see Takeover mode) |
| drag a window or widget | move it on the canvas (a widget's drag pans instead: Settings › Canvas › Desktop places the widgets). Near a neighbour its edges and centre stick to the neighbour's, or to a grid step beside it, with a pink guide drawn while they do. Let go and it settles onto the grid (40 pt by default), except along an axis a guide is holding |
| ⌘-drag | move it freely: no guides, no grid, and over other windows even when they push each other |
| drag into a neighbour (Settings › Windows › Windows push each other, off by default) | the neighbour slides out of the way along the shortest route, keeping its line on the other axis, and shoves the ones behind it along; pushed windows ease after the hand a fraction of a second, so a hard shove reads as weight, and stay where they land. The Magnetism slider runs from Gentle (a window moves only once it's touched, and eases) to Firm (the push starts a tile gap out and keeps that gap, and pushed windows snap to). Let go while moving fast and the window coasts a short way, no more than a quarter of its width, shoving as it goes, then settles onto the grid. A growing edge pushes too; ⌘Z puts everything a drag pushed back. Windows that were already stacked on each other are left stacked |
| flip a window's pole (Settings › Windows › Magnetic polarity, experimental, off by default; needs the push above) | every window is ⊕ or ⊖, ⊕ to begin with: its label leads with its pole, and the first button of its hover pill, in the pole's tint, flips it — so does P over it, or Flip Polarity in its menu. Like poles push as above. Bring a window within a few points of an opposite pole, faces lined up, and the other is pulled in to the gap (a tick-marked line shows where) and bonds: the two are now a group that moves, coasts, drops onto the grid and undoes as one, outlined together when hovered and ringed in the minimap. A group grows by bonding to a member of the opposite pole; what's caught between the hand and a pulled window is pushed aside. ⌘-drag a member to pull it out, flip it to eject it, or Ungroup from its menu; a member closed, tiled, or moved a long way as a real window also leaves. Hidden and minimized members stay in their group. Poles and groups are remembered with the canvas and in saved layouts |
| feel it (Settings › Motion › Trackpad haptics, on by default; a Force Touch trackpad under the hand) | each thing that happens under the hand has a tap of its own, told apart by weight and rhythm, never loud: an edge catching a guide is one light tick, a drawer finding its stop; running into a neighbour and shoving it is one bump, a block nudging a block (only what the hand itself hits — what that shoves behind it is weight, not a knock); like poles meeting is a light flutter, magnets that never touch; an opposite pole caught and drawn in is a light tap then a heavier one, a pull growing; two bonding is one deep click, magnets meeting; ⌘-dragging a member off its group is the catch backwards, a tap then a lighter one. A window just bumped isn't bumped again for a moment, a guide re-caught at once is silent, and a sweep through a cluster can't tick more than six times a second; only a bond cuts in on another cue. Nothing after letting go, and nothing with haptic feedback off in the Mac's trackpad settings |
| drag a window's edge or corner | resize it, on the canvas. The pointer turns into a resize arrow within a few points of the edge (corners are generous). The real window takes the new size behind the canvas as you drag, as fast as its app keeps up; let go and the moved edges settle onto the grid (⌘ leaves them be), and the proxy takes whatever size the app allowed, against the edges that didn't move. Not widgets, and not a window too small on screen to have edges to spare |
| click a window (zoomed in or out) | bring it to the front and enter it right where it is, at its own size: it grows (or shrinks) to 1:1 around the clicked spot, which stays under the pointer as far as the screen allows, and isn't brought to the middle (a second click on its way in, a double-click, takes it to the middle instead; the way in lasts at least the double-click interval so that click is never the app's). A press that moves more than a few points drags it instead. A tiled window keeps its place in its area |
| double-click / ⏎ over a window | bring it to the middle of the screen (below the menu bar) and enter it, wherever it was on the canvas. A tiled window keeps its place in its area |
| click, drag or double-click a window at 1:1 | it's the real window: entered where it is, nothing moves, and the press goes on to it as on the desktop (a button is pressed, text selected, the title bar dragged). Typing then goes to it. Clicking another window behind it switches straight to that one. Scrolling over a window scrolls it the same way; over empty canvas, or with ⌥/⌘, it still pans and zooms, and a four-finger drag pans anywhere |
| hover a window | floating controls at its top-right: – minimizes the real window into the Dock, ✕ closes it (its own buttons, via Accessibility) |
| right-click a window | Picture in Picture (below), Tidy, Tidy By and Arrange (with Arranging on, see Strip mode), Move & Resize (the placement section, as in the Window menu), Minimize, Hide *app* (⌃-click works too) |
| Picture in Picture (right-click a window, ⌃⌥P over it, Window › Picture in Picture) | the window flies into a corner of the screen as a small live tile, as the macOS video PiP does, and stays there wherever the canvas goes and while you work in another window, over it (a call, a video, a timer). It's the real window, scaled, so a click in it is the app's. A new tile is a quarter of the screen wide (never less than 240 pt, never more than half the screen on either axis, never bigger than the window), in the corner the window was last in, else the last corner used, else bottom-right; a corner already taken sends it to the nearest free one, and with all four taken the oldest tile goes home. Its place on the canvas stands as its home, drawn dashed in the minimap, and other windows go on treating that place as taken. Drag the tile and it springs to the nearest corner; flung, to the corner it's heading for; ⌘-drag leaves it where it's dropped. Dragged (or flung) more than half past the left or right edge it tucks away, sliding off until a 24 pt tab with a chevron is left; the tab, or a drag, brings it back to the corner on that side. Resize it from its edges or corners, or pinch or ⌥-scroll over it: the aspect stays, and it springs back into its corner. Its corners are rounded like a video's (the add-on shapes the real window, `SUNBEAM_SHAPE`; the window gets its own corners back when it leaves PiP). A click on the tile returns the window to 1:1 where the tile is, the canvas staying put, with the flight; hover it and a strip with the home button (leave PiP: it flies back to its place on the canvas, the pip.exit symbol) and its title fades in; a right-click offers both. The tile takes the click and the drag wherever the canvas stands (with the canvas away they bring it back first), and the canvas resizes it from a band along its edges. Come back from a returned window (the Mission Control key, a four-finger tap) and it shrinks from 1:1 into its corner; from inside a window ⌃⌥P does the same to that window. While the canvas is away a click on a tile returns it the same way. Closing, minimizing, hiding, or moving to another display take it back to its home. Tiles are remembered with the canvas and saved in layouts, in that screen's coordinates, tucked state included. Staying on show while the canvas is away needs the Dock add-on sunlight-44 (`SUNBEAM_PIN`, level 3), and the rounded corners sunlight-52, which also raises a tile to its level before the window entered under it comes up (raised after it, the tile blinked at every switch); with an older one, or with pictures instead of live windows, a tile shows only while the canvas is up, and with pictures PiP ends and the window is entered the usual way instead of returning in place. The numbers (`PictureInPicture.Reference`) are approximations of the video PiP's, to be measured |
| pinch in to ~100% over a window | enter it where it is (the handoff gesture): zoomed out it grows to 1:1 down from its title bar, the spot under your fingers staying put. macOS won't put a window's top under the menu bar, so one that would be eases down just below it, alone |
| click a widget | what a click on the desktop does: a button or toggle under the pointer is pressed (interactive widgets), anywhere else opens the widget's app |
| ⏎ over a widget | open the widget's app |
| hover a widget | the same controls: ✕ removes the widget from the desktop (its own context menu's "Remove Widget") |
| right-click a widget | Remove Widget, Add Widgets… (⌃-click works too) |
| right-click empty canvas, or Sunlight › Add Widgets… | the desktop's widget gallery. macOS's widget edit mode clears every window off the screen, the canvas too, so click a widget in the gallery (it takes the desktop's next free spot, from the top left) or drag it onto the real desktop. Done brings the canvas back, with the new widget on it where it landed on screen |
| click a file on the desktop | select it, in Finder too; ⌘-click adds or removes one, ⇧-click adds. Double-click opens it as a launch from the canvas does: the window pops onto the canvas where you're looking |
| keys after clicking a file | ⌘O or ⌘↓ open, ⏎ rename, ⌘⌫ Move to Trash (⌘Z puts it back), ⌘C copy, ⌘A select every file, esc deselect |
| right-click a file on the desktop | Open, Open With, Move to Trash, Rename…, Copy, Show in Finder |
| right-click the desktop's empty ground | New Folder (named as Finder names one, then renamed), then the canvas's own menu |
| drag files off the desktop | a real file drag: drop it on anything outside the canvas, or hold it over a window for 0.6 s to enter that window where it is and drop it in there |
| esc | nothing on the canvas (the four-finger tap, or the minimap's Fit, shows everything) |
| ⌃⌥ ← → ↑ ↓ | **Move & Resize, one window**: a window to a half. ⌃⌥ U I J K quarters, D F G thirds, E T two-thirds, ⏎ full, C centre; pressing a half again steps to two-thirds, then a third. On the canvas it's the window under the pointer (or the one used last), in its screen: the one you're looking at when at 1:1, otherwise its *page* (screen-sized areas laid out from your real desktop, 240 pt apart). In a real window, macOS's own tiling does the halves, quarters, fill and centre (its Window › Move & Resize menu, pressed through Accessibility); Sunlight does the rest. Entering a tiled window lines the camera up with its screen, so the screen shows it as a tiled desktop. ⌘Z puts the window back. The gap from the screen's edges and between windows is Settings › Windows › Tiling › Gap (8 pt by default) |
| ⌃⌥ 2 · 3 · 4, Window › Arrange | **Arrange, one screen** (experimental, off by default; see Strip mode): the windows on the screen you're looking at (or the right-clicked window's) laid out in that many columns, in the order they sit now; the menu has 2×2 and 3×2 too. Windows beyond the cells stay put. ⌘Z puts them back. From inside a real window the canvas comes forward first |
| ⌃⌥A, Window › Tidy | **Tidy, everything** (experimental, off by default): every window on the canvas on one grid, from the top-left of the screen you're looking at, the camera framing the result in the same motion. Windows keep their order (Window › Tidy By: Where They Are, Most Recent, or App; the choice is remembered) and, by default, their sizes: columns as wide as their widest window, rows as tall as their tallest, each window at the top-left of its cell. Settings › Experimental › Arranging: Columns (Auto, the square root of the count, or 2–6), Sizing (keep sizes, or make them the same size: cells that are fractions of the screen, the grid continuing onto the screens below, each window recording its screen as its tiled area), Spacing (Tight is the gap, Normal four gaps, Roomy twelve). Bonded groups go as one block, not resized; widgets stay; hidden and minimized windows take a cell after the rest. ⌘Z puts everything back, sizes included. From inside a real window the canvas comes forward first. The same three commands, in the same order, are in the Window menu, a window's right-click menu, the canvas's right-click menu and the menu bar's shortcuts menu |
| Settings (⌘,) | eight panes in the Mac's toolbar-tab settings window, each one idea, each with a stage at the top that acts its settings out and follows them as they change: General (the Sunlight card with its version and takeover switch, what comes back at launch, layouts, updates, uninstall), Canvas (the stage shows the minimap, the ⌘Tab strip on its edge and the desktop files; the strip's edge is four picture tiles), Background, Windows (the stage drags a window beside its neighbour with the guides, grid and push the pane has on; the tiling gap is five picture tiles), Motion (the stage plays the chosen open/close effect, the six effects are looping tiles; inertia, snap to full screen windows, haptics), How to use (Basics | Trackpad | Placing | Keyboard: everything the app teaches), Live Windows (the way from the real windows through the Dock add-on to the canvas, a mark on each stage; Live windows and Screen capture as two picture tiles; setup) and Experimental (one card per unfinished feature with its own rows under its switch: Arranging with Tidy's rows, Strip mode, Multiple displays, Use windows at any zoom) |
| Settings › How to use | every trackpad gesture acted out, as System Settings › Trackpad does it: Point & Click, Zoom & Pan and More Gestures tabs, and a loop of fingertips on a trackpad beside a miniature canvas for the gesture picked or pointed at (one still moment under Reduce Motion) |
| How to Use… in the menu bar icon's panel, ⌘? (caught by Sunlight itself: no Help menu, since macOS keeps ⌘? for a Help menu's search field) | Settings › How to use: everything the app teaches as four chapters in a segmented control. Basics (the tutorial to play again, getting around, where things are), Trackpad (the gestures acted out), Placing (the three scopes as looping miniature demos, each with its keys and a Try button that does it on the canvas behind, and what the hand does; the ? in Settings › Windows opens it here) and Keyboard (every key). No separate window |
| minimap (bottom right) | click to look there at the current zoom, drag the outline to pan; Fit and 1:1 buttons. A dashed outline is a hidden or minimized window: click it to bring the window back where it was and enter it. Sunlight › Minimap hides it |
| ⌃⌥S, Window › Strip Mode | experimental, off by default: every app on one horizontal strip, the one used last on the left; the ⌃⌥ arrows then step along it (see Strip mode) |
| ⌘S, or Layouts › Save Layout… | save the canvas as a named layout (see Layouts) |
| ⌘1–⌘9, or Layouts › a layout | restore it |
| ⌘, | settings, a sidebar of panes: General (remembering the canvas, what a restore does with other windows, and Experimental: Arranging and strip mode), Canvas, Background (below), Windows (dragging, alignment guides, the drop grid, windows pushing each other, magnetic polarity), Arrange (tiling's gap; Tidy's columns, sizing and spacing while Arranging is on), Shortcuts, and Live Windows (setup progress, the setup log, Diagnose) |
| drop a picture on empty canvas | it becomes the background (⌘Z puts the old one back) |
| right-click empty canvas › Background | a picture, the Mac's wallpaper, a colour or a gradient; the four styles; blur; Customise… |
| ⌘Q | quit |

## Strip mode

Experimental, off by default: Settings › Experimental › Strip mode (or `defaults write
com.spacefarm.sunlight StripModeEnabled -bool YES`) adds it. Off, there's no Strip Mode item, ⌃⌥S stays free
and the strip never comes up. Arrange and Tidy below are behind the same kind of flag, Experimental ›
Arranging (`ArrangingEnabled`); off, their menu items, ⌃⌥ 2 3 4 A, the panel's Tidy tile and Arrange row and
the Tidy rows under Settings › Experimental › Arranging are gone, and Move & Resize stays.

Window › Strip Mode (⌃⌥S, or Settings › Experimental › Strip mode) puts every window on one endless horizontal
strip: one column per app, its windows stacked top to bottom, the app used last on the left and each one
used before it further right. The strip starts a gap in from the top-left of the screen as it is at 1:1
and runs right for as long as there are apps; the gap is Tidy's Normal spacing, so it follows
Settings › Windows › Tiling › Gap. Nothing is resized: a column is as wide as its widest window.

- **Entering** a window (click, ⏎, the switcher, the pinch) is entering it where it is: the camera lands
  on it at 1:1, centred, and its neighbours stay on show at the sides as real windows. Nothing moves.
- **Coming back** to the canvas, the window you were in goes to the top of its app's column and the
  column to the left end of the strip; the columns that were left of it move one place right. The camera
  moves with that window, so it stays where it is on screen and the strip rearranges around it. Not when
  something asked from inside the window is about to move the camera (⌘Tab, a four-finger pan, Show
  Desktop, a ⌃⌥ arrow): the strip keeps its order for that and reorders on the next return.
- **New windows** are the most recent: a window that opens takes the top of its app's column, and the
  column goes to the left end. Closed windows leave no gap; hidden and minimized ones keep their slot.
- **Dragging** a window moves its whole column: let it go with its middle past a neighbouring column's
  middle and they swap; drop it above or below a sibling and the two swap in the column. That order holds
  until the next window is used. No guides, grid, pushing or polarity while the strip rules (groups wait,
  inert, until it's off). Resizing works as ever, and the column reflows around the new size.
- **⌃⌥ ← →** enter the top window of the column beside the one you're in (on the canvas: the one under
  the pointer, or the one used last); **⌃⌥ ↑ ↓** step along the column. From inside a real window the
  canvas comes forward and the strip keeps its order while you step, so ⌃⌥→ twice goes two columns along.
  The other ⌃⌥ slots, Arrange and Tidy are off.
- **Off** again (⌃⌥S, or ⌘Z right after turning it on) puts back the free canvas as it was when the strip
  came on. A strip that was on at launch goes off leaving the windows where the strip had them.
- The mode is remembered between launches, and the canvas comes back as the strip it was. Restoring a
  saved layout in strip mode puts its windows on the strip in the layout's left-to-right order.

The layout itself is pure and tested (`Sources/Canvas/Strip.swift`, `Tests/CanvasTests/StripTests.swift`).

## Layouts

The canvas remembers itself. Where every window and widget sits, and the camera, are written to
`~/Library/Application Support/Sunlight/Canvas.json` as they change and when Sunlight quits. At the next launch,
each window that's still there, or that comes back within two minutes (at login, apps reopen theirs over
a while), goes back to its spot. Only its spot: the real window keeps its size. A window is recognised by
its ID while it lives (Sunlight relaunched, the app not), and after that by its app and title, or its app
alone.

Layouts › Save Layout… (⌘S) does the same under a name, in `Layouts.json`, and also keeps each window's
size and the document it shows (Accessibility's `AXDocument`). Restoring one (⌘1–⌘9):

- every window in it glides to its spot at its saved size, stacked as saved, and the camera with them. The
  real windows are resized behind the canvas; they only move when entered, as always,
- what's missing is opened without being activated, so it comes up behind the canvas: the saved documents
  (TextEdit, Preview, Xcode…), apps that aren't running, and a reopen for a running app with no window. Each
  window takes its spot as it shows up, for up to 12 s,
- the windows on the canvas that aren't in the layout: Sunlight asks whether to leave them where they are,
  move them aside (a row to the right of the layout), or close them (their own close buttons). "Do this
  every time" makes the answer the setting.

The log says what matched, what was opened, and what never showed up (`Layout:` lines).

## Background

Behind the windows there's a colour, as before, or a picture. Settings › Background (⌘, or Change
Background… in the app menu) is modelled on the Mac's Wallpaper pane; the window floats at the top-right
of the screen so the canvas itself is the preview, and every control changes it at once.

- **Source**: the Mac's own wallpaper (the default on a fresh install; Dynamic Desktops give their light and
  dark pictures), a photo from Photos, a file, the two canvas colours, or one of six built-in gradients.
  Pictures are copied into `~/Library/Application Support/Sunlight/Backgrounds/`, so a file moved later
  changes nothing. Match the Mac follows System Settings › Appearance; a single picture is dimmed a little
  for the dark appearance, or a second picture can be chosen for it.
- **Style**: Natural, Black & White, Duotone, Colour Wash — iOS's four — with a tint drawn from the picture
  or chosen.
- **Focus**: the blur follows the zoom. At 100% the canvas is your desk and the picture is sharp; pulled back
  to 50% it reaches the chosen blur (Soft or Deep) and a dim of up to 40%, so the overview is about the
  windows, as Mission Control's is. Or a constant blur. Subtle depth drifts the picture a little as you pan.
- **Customise**: grain, a vignette, and for a gradient the living variant, which drifts slowly while the
  canvas is in front and rests with Reduce Motion and Low Power Mode.

How it's drawn: one small layer tree (`Sources/Canvas/Background/`), under the proxies in capture mode and
on the opaque backdrop window under the real windows in live mode, moved between the two as the renderer
changes. The picture is decoded once at the screen's size, styled with Core Image, and blurred into a few
levels (4, 12, 28 and 60 px, at half resolution) that are cross-faded by opacity as the zoom moves — no
filter runs per frame, so a pinch costs what it did. A layout can remember its background (a box in Save
Layout…), and restoring it brings the background along.

## What to look at

- **The seam.** Enter a window and watch the exact frame where the proxy becomes real. Anything that pops —
  title bar activation, shadow, a half-pixel — is the product.
- **Return.** The Mission Control key back out. The proxy should already be exactly under where the real window was, showing
  a frame at most a quarter second old (its stream stopped when you entered; one-shots kept it current).
- **Arrival.** Zoomed out, click an app that isn't running in the Dock. The camera stays where
  it is: the window grows in at the canvas's zoom, a thin ring ripples out from its edges, and nothing
  else moves. The log has a `Launch:` line and no `Absorb:` line. From inside a window, a launch is still
  absorbed at 1:1.
- **The pill.** Enter a window, or open one from the Dock: no purple pill should ever show in its title
  bar. A pill means a stream is running on a window that's in front of the canvas.
- **Liveness.** Play a video, then go to the canvas. Does the proxy keep updating? The canvas window is
  deliberately non-opaque so the window server doesn't report the windows beneath as occluded (occluded
  apps throttle or stop drawing). If proxies freeze anyway, that's the signal to move to virtual-display
  parking.
- **Cost.** One SCK stream per window behind the canvas, sized to the zoom in √2 steps (a window drawn
  at 10 % is captured at an eighth of its size) and at 30 fps near 1:1, 15 then 10 further out. A
  window out of sight — past a margin around the viewport, or under the entered window — streams at a
  quarter of its size at 2 fps, and after 30 s not at all; back in sight it's at full rate within a
  frame or two. Windows in front of the canvas get one-shot captures instead (~12 ms each, served one
  at a time by the window server, which manages ~100 a second system-wide): the entered window 4 a second, its visible siblings 1 a second between them. With the
  screen locked or asleep nothing is captured. Open 20 windows and watch Activity Monitor, or run
  `scripts/perf-snapshot.sh` for CPU and memory numbers. Widgets stream too, but only send frames
  when they change.
- **Desktop files.** Click a file on the floor: Finder's selection follows within a moment. Double-click a
  document: its window pops onto the canvas. Right-click › Rename…, Move to Trash then ⌘Z, New Folder.
  Drag a picture off the floor onto a Mail compose window or a Finder window on the canvas and hold it
  still: the window is entered after 0.6 s and the drop lands in it. In live mode and in capture mode.
- **Widgets.** They should come up where they are on the desktop, as cards with no margin around them,
  and in full colour with takeover on. Without takeover, Notification Center draws them dimmed to
  monochrome (the canvas is an app in front of the desktop); set Desktop & Dock › Dim widgets on desktop to
  Never to see them in colour. Click the Weather widget: Weather should open, and with takeover on, its
  window should arrive on the canvas like any launch. Add Widgets…: the gallery comes up over the bare desktop; after Done the
  canvas is back in front with every proxy where it was, and the new widget's proxy appears within a
  second or two.

## Takeover mode

The canvas can be the Mac's environment instead of a window you switch to. A literal replacement of
WindowServer isn't possible on macOS (it's SIP-protected and routes all input), so takeover mode works
with public APIs and SIP on: Sunlight becomes the root of the session and everything that happens outside
the canvas is folded back into the handoff model.

On first launch Sunlight asks once. Saying yes:

- sets the Dock to auto-hide system-wide (`com.apple.dock autohide`, with `autohide-delay` cleared so it
  still slides out at the screen edge),
- leaves Finder's desktop icons on: they're the canvas's floor. Builds before it turned them off
  (`com.apple.finder CreateDesktop`); the first takeover with this one gives your own setting back and
  restarts Finder once,
- sets Dim widgets on desktop to Never (`com.apple.widgets widgetAppearance` = 1), so widget proxies are
  in full colour; Notification Center otherwise dims widgets whenever an app is in front of the desktop,
  and the canvas always is,
- turns off the Mission Control / App Exposé / Show Desktop trackpad gestures and hot corners
  (`com.apple.dock showMissionControlGestureEnabled` etc., `wvous-*-corner`, `mcx-expose-disabled`),
- registers Sunlight as a login item (`SMAppService`),
- installs an event tap that claims ⌘Tab, ⌃← ⌃→ ⌃↑ ⌃↓ (Spaces and Mission Control), the Mission Control key
  and F11. Inside a full-screen app's Space ⌃← passes, as the way back to the canvas's Desktop. ⌃⌘F in a
  window is Sunlight's full screen, the green button's: the window fills its area and is entered there,
- keeps one Desktop per display, the canvas's (`Spaces`): every window on another Desktop moves onto the
  canvas's Desktop and the empty Desktops are removed, as takeover starts and a couple of seconds after a
  Desktop is added. Nothing asks first; the consent says so. Full-screen apps' Spaces are left alone. The merge is the one thing quitting
  doesn't undo: Desktops aren't recreated. Moving another app's window between Desktops and removing a
  Desktop are only taken from the Dock with SIP on (`LiveWindows/spaces-probe.m`), so they go through
  the add-on's Desktops op (sunlight-55); with an older add-on nothing is merged.

The Dock and Finder are restarted once to pick the values up. The originals are snapshotted before
anything is written (an absent key is remembered as absent) and put back when Sunlight quits with ⌘Q or
Ctrl-C in the terminal. Logging out leaves them in place so the login item lands straight back in the
environment. "Release the Mac…" in the menu restores everything *and* removes the login item.

For development, `CANVAS_TAKEOVER=light make run` runs the key tap and the absorb logic without the
consent step, the system changes or the login item, so the Dock and Finder aren't restarted on every
run. `scripts/smoke-takeover.sh` drives TextEdit through the main flows and prints which app is
frontmost after each step (run it while you're at the keyboard: a locked screen makes every step fail).

If Sunlight ends without quitting (a crash, a force quit, `kill -9`), its guard puts the same values back
straight away: `Sunlight --guard <pid>`, started at launch in a session of its own (so a second
"Sunlight" shows in Activity Monitor), waits for the app's process to exit, and when the app's mark in
the defaults is still there (`Stability`), records the run and reverts takeover's prefs and Stage
Manager as a quit would. The opt-in and the login item stay. Two unexpected ends in a row, each within
90 s of opening, make the next launch safe mode: no takeover, no live windows (capture stills, no quiet
add-on loads), for that launch only. The runs, the main-thread watchdog's stalls (`Watchdog`, over
500 ms, named when inside a known wait: the Dock's handoff ack, an Accessibility call, an add-on
command) and the crash reports are in Diagnose's Stability section; `defaults write
com.spacefarm.sunlight StallWatch -bool NO` turns the watchdog off.

Escape hatches, for when the app itself won't launch:

```
make release    # restore Dock, Finder, hot corners; remove the login item; opt out
make status     # what takeover has changed, and what it would restore
```

Or by hand: `defaults delete com.apple.finder CreateDesktop` (if an older build turned desktop icons
off), likewise for the gesture / `wvous` /
`mcx-expose-disabled` keys and `com.apple.widgets widgetAppearance`, then `killall Dock Finder`. Note `autohide` is only *reverted*, not deleted,
if you had it on before, and an `autohide-delay` of your own has to be written back.

What changes while it's on:

| | |
|---|---|
| ⌘Tab (tap) | the previous app's most recent window, flying there across the canvas |
| ⌘Tab (hold) | a strip of large app icons at the screen edge chosen in Settings › Canvas › ⌘ Tab (bottom by default; left, right or top), or no strip at all with Show the ⌘Tab strip off there: everything below works the same without it. Tab and ⌘← ⌘→ walk apps, the app you were in first, then by their most recently entered window, then the rest left to right; ⌘` and ⌘↑ ⌘↓ walk the highlighted app's windows, shown as chips under its name. The camera flies to each window: a pan that pulls back a little on the way (van Wijk–Nuij) and settles with a slight spring, and the strip's highlight moves on that same spring, so both land together. Hover an icon or chip to go there, click to enter it. Release ⌘ to enter the highlighted window, esc to cancel. The canvas itself isn't in the cycle: esc, or the Mission Control key, gets back to it |
| Mission Control key (F3), four-finger tap | the canvas, with everything fitted — the canvas *is* Mission Control. It's the only key for it. The Mission Control key or the tap again, on the canvas, goes back into the window you last entered, as closing Mission Control would. Held (0.3 s or more, `MissionControlHold`), it picks: the canvas shows everything (from the canvas, once the hold is known), the window under the pointer lights as you move, and letting go goes into that window, brought to the middle at 1:1 as a double-click does; let go over empty canvas and See All stays. On the canvas a tap acts on the release, so it can tell. The key's repeats while held are swallowed, and the tap times the hold by the key events' own timestamps |
| F11, four-finger spread, Window › Show Desktop | Show Desktop: the camera flies to Finder's desktop at 1:1 and every window and widget dims, the desktop's files lit above the dim. Again, and the camera flies back to where it was; a click on a window, entering one or the Mission Control key ends it where you are. From a window, the canvas comes back first |
| Dock, Spotlight, notification, URL, app launch | from the canvas, the canvas stays where it is: the app's window opens behind it and arrives on the canvas at the current zoom, with a small pop (the real window never moves). An app already on the canvas is entered where its focused window is, at 1:1. From inside an entered window, the new app's focused window is treated as entered: the camera moves to 1:1 under it, so ⌘Tab back lands on its proxy exactly. With Scaled real windows, a Dock launch blinks the scaled windows to native for a moment while the canvas comes back |
| focus moves to a sibling window (⌘`, ⌘N, a click) | that window becomes the entered one |
| the entered window closes, minimizes, or its app hides/quits | the canvas comes back. A minimized window goes into the Dock as usual (in takeover the Dock slides out at the screen edge) and a hidden app's windows go with it, but both keep their places on the canvas, dashed in the minimap; ⌘Tab still lists them, and picking one, a click on its outline, or restoring it from the Dock brings it back there and enters it |
| "Hide Others" from another app | the canvas un-hides itself without taking focus |

The menu bar stays. Entering an app still raises all of its windows; clicking a sibling makes it the
entered window. Native-fullscreen windows aren't absorbed. `_AXUIElementGetWindow`, the Mission Control
key code (160) and the Dock gesture keys are unofficial; each has a logged fallback. With ad-hoc
signing the login item may not auto-launch — sign with a real identity for that.

## Known limits

- A tile's sheets and prompts aren't in Picture in Picture with it: they're drawn at its home. ⌘Tab onto a
  tile returns it from wherever the camera is rather than flying to its home. Switching to another window
  of a returned window's app (⌘`) takes the camera as it is, zoomed out or not. A tile can't be dragged or
  resized while the canvas is away (another app in front, or a window in use): only its click and its button work then.
  Tiles don't yet follow you to other Spaces or over full-screen apps.
- With Settings › Experimental › Multiple displays on (`Settings.multipleDisplays`, off by
  default; off, the main display's canvas is the only one), every display has its own canvas (`Desk`),
  and each window is on the canvas of the display it's on. A window moves to another display's canvas
  when it's moved there for real, from inside it or with ⌃⌥⇧ → ← (Window › Move to Next Display, or its
  right-click menu). Live windows on the other displays
  need add-on sunlight-13, which holds a lease per canvas; with an older one only the main display's
  canvas is live and the others show pictures (Screen Recording). Saved layouts and the widget gallery
  act on the main display's canvas; the remembered canvas keeps a camera per display. A change of main
  display (the lid closed on an external display) starts every canvas over.
- Activating an app raises *all* its windows, not just the one you entered.
- Resizing a window while it's real: the proxy re-anchors on return, but the texture stretches for a beat
  until the stream reconfigures.
- Sheets/popovers attached to a window aren't in its texture (`includeChildWindows` is off).
- `_AXUIElementGetWindow` is private (SIP-safe, used by every Mac WM). There's a frame-matching fallback.
- Four-finger pan reads the trackpad through MultitouchSupport, also private (what MiddleClick and
  BetterTouchTool use; no public API sees touches outside the key window). If it doesn't load, the log says
  so and the pan is off. The Dock-control events it drops to hold off macOS's own four-finger swipes are an
  undocumented event type (30).
- Resizing on the canvas is by the window's edges only, with no alignment guides yet, and the texture
  stretches for a beat while the stream catches up with the new size. No semantic zoom: a window looks
  the same at every zoom, its label aside.
- Layouts: a restore can only reopen a window that shows a file, or an app's first window. A browser's tabs,
  a second Terminal window, and a widget since removed from the desktop don't come back. Matching by title
  can swap two windows of one app whose titles changed. Closing a window with unsaved changes puts its save
  sheet behind the canvas, as the ✕ does.
- Widgets: a click that isn't on a control opens the widget's app, not the deep link a widget may carry
  (Accessibility doesn't expose it), so the Weather widget opens Weather rather than that city. A widget
  whose app is a hidden container (Batteries) has nowhere to open. Removing one shows its context menu over
  the real widget for a moment. Widgets aren't in the ⌘Tab cycle: they can't be entered.
- Adding widgets goes through Notification Center's own gallery: there's no API to open it or to host a
  widget, so a widget can only be added to the real desktop. Its edit mode hides every window Sunlight has, at
  any window level (measured on 27.2), so the canvas can't stay up while you drop; it steps aside and syncs
  the new widget in afterwards (syncing pauses meanwhile, since every window is off screen). The gallery is
  opened through a widget's context menu (Accessibility), or with no widget yet, Finder's desktop menu,
  which Finder doesn't expose to Accessibility: Sunlight types the item's title into it (keys go to Finder
  only, and only while that menu is open). With Finder's desktop turned off (Show Items › On Desktop),
  there's no such menu; then add the first widget from the desktop itself.
