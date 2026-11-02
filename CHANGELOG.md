# Changelog

## 0.2

- Picture in Picture for any window: right-click a window > Picture in Picture (or ⌃⌥P over it, or from inside it) and it flies into a corner of the screen as a small live tile, the way a video does, and stays there wherever the canvas goes and while you work in anything else: a call, a video, a timer. It's still the real window, so a click in it works. Drag the tile and it springs to the nearest corner (a fling goes to the corner it's heading for; hold ⌘ to leave it anywhere); drag it past the left or right edge to tuck it away, leaving a tab that brings it back; resize it from its edges, or pinch, and it keeps its shape. Click it and it opens full size where the tile is, and shrinks back into its corner when the canvas comes back; hover it for the home button (back to its place on the canvas). Several windows can be tiles at once, each in its own corner, and tiles are remembered with the canvas and saved in layouts.
- Hold the Mission Control key (F3) to jump to a window: everything shows, the window under the pointer lights up as you move to it, and letting go takes you into it, centred at full size. A quick press works as before.
- Use windows at any zoom, in Settings > Experimental (off by default, live windows only): click and type in windows while zoomed out. A click focuses a window; until then a drag anywhere moves it, and pinch and two-finger scroll over it move the canvas. Once you're in it, drags, pinches and scrolls are the app's own, the title bar or ⌘ moves it, and a double-click still brings it to the middle at 1:1. Right-click opens Sunlight's window menu anywhere on a window.
- Tell Sunlight, in Settings > Experimental (off by default): press ⌃⌥Space, type what you want done with your windows ("put Slack and Calendar side by side", "restore Writing and open Notes beside it") and Claude carries it out with the canvas's own commands: moving, resizing, tiling, opening apps, layouts, minimizing, going into a window. It also works inside apps (reading pages and documents, clicking, filling in fields, choosing options, scrolling) through Accessibility, without taking your pointer or keyboard. A click that sends, deletes, pays or publishes waits for your Allow in the bar; settings, password and terminal apps, and password fields, are never worked in. Needs your Anthropic API key, kept in the keychain. Each request sends the request and your window list (apps, titles, positions); esc stops it.
- Sunlight takes the place of Spaces: in takeover mode with live windows, each display keeps one Desktop, the canvas. Windows on other Desktops move onto the canvas beside the others and the empty Desktops are removed, at start and whenever a new Desktop appears. Full-screen apps keep their own Spaces. Takeover's consent text says so before you turn it on, and merged Desktops are not recreated when Sunlight quits. ⌃↑ and ⌃↓ are taken on the canvas along with ⌃← and ⌃→.
- Stage Manager is turned off while Sunlight runs, since it hides other apps' windows away from their canvas spots. Setup says so first, and Stage Manager comes back on when Sunlight quits (unless you turned it on yourself meanwhile).
- Settings is redesigned: eight panes (General, Canvas, Background, Windows, Motion, Trackpad, Live Windows, Experimental), each opening with a picture that acts its settings out as you change them, and visual choices drawn as picture tiles. Effects, camera and haptics have their own Motion pane, and every unfinished feature is a card in Experimental. Instructions is now How to use (⌘?): the basics, every gesture acted out, placing windows and every key.
- Stability: live windows no longer drop to screen capture with very many windows open, or when a window closes mid-frame; stalls are gone when apps launch, windows open or close, focus moves, layouts restore, Tidy or Arrange run, and on entering a window; launching with no display (a closed lid at login) no longer crashes; ⌘Tab and the Mission Control key are given back as soon as Sunlight is turned off; and ⌘ shortcuts no longer crash Sunlight on macOS 27.
- Screen capture mode: entering a window no longer shows its picture stretched for a few frames, and windows no longer shift on the canvas after you leave them.
- These need the Dock add-on sunlight-57. Sunlight loads it by itself the first time it starts after the update, which restarts the Dock once. With live windows allowed in Login Items that needs nothing from you; otherwise Sunlight asks for your administrator password once.

## 0.1.5

- Windows open and close with an effect. Automatic (the default) picks one per window: a window opened with Open Here… grows out of the spot you clicked, one placed beside another slides out from behind it, sheets and prompts unfold from their top edge, and the rest rise into place as they brighten, like the sun coming up. Closing from the canvas plays the effect first, then presses the close button; a window its app keeps ("save changes?") opens again. Settings > Windows > Opening and closing has Sunrise, Unfold, Bloom, Dissolve and None; Reduce Motion makes every effect a fade.
- Entering a window or switching apps no longer blinks: the window, and the ones kept on show around it, no longer vanish for a frame at the seam, a new window or a launching app comes onto the canvas without flashing at full size first, and no window is left out of place or on top afterwards.
- Sheets, alerts and prompts hang from the window they opened over: they sit beside it on the canvas, move with it, and come back in front of it when you go into it, instead of getting a place of their own.
- See All starts at once, even with many windows open.
- The minimap shows only on the canvas, popping in and out, and no longer peeks out from behind a window you're in.
- Saved layouts that don't restore now say why in the log, for bug reports.
- These need the Dock add-on sunlight-41. Sunlight loads it by itself the first time it starts after the update, which restarts the Dock once. With live windows allowed in Login Items that needs nothing from you; otherwise Sunlight asks for your administrator password once.

## 0.1.4

- Windows keep their places on the canvas. They no longer shift after a new window opens or as you switch between apps, and closing a window from the canvas leaves the canvas where it was.
- Going into a window no longer leaves the app's other windows showing at full size on top of it or behind it, and an app sent back to the canvas no longer flashes its windows at full size.
- An app you open from inside a window (from the Dock, or as it launches) gets its new window beside the one you're in, and you go straight into it.
- Open Here… and new-window placement recognise an app's New Window command on any keyboard layout, and in Finder.
- See All fits your windows only, and leaves the desktop's files and widgets out.
- Settings > Live Windows has one "Show windows as" choice: Live windows or Screen capture.

## 0.1.3

- Setup no longer covers System Settings or macOS's permission prompts: the setup window steps aside as you press Allow Accessibility, Allow Screen Recording or approve the background helper, and only stays above other apps while Sunlight is in front. The Uninstall window does the same.
- Sunlight shows a Dock icon while setup is open, so you can click back to it from System Settings. The icon goes away when setup closes.

## 0.1.2

- Open Here…: double-click or right-click the empty canvas, type an app's name and press ⏎, and its new window opens on the spot you clicked (⌘⏎ also goes into it). An app that's already running is asked for a new window; one that can't make one has its last-used window brought over instead.
- The first-launch tutorial (trackpad) shows going into a window as a click or pinching in, side by side with an "or" between them, and ends with panning from anywhere with four fingers. Instructions > The Basics lists the four-finger pan too.
- Apps whose window never shows on the canvas (a panel, an overlay, a tiny or invisible window) now stay in front when you switch to them from the canvas, instead of being sent back behind it.

## 0.1.1

- Quick ⌘Tab switches no longer flash the window you just left at full size (Dock add-on sunlight-14).
  Sunlight loads the new add-on by itself the first time it starts after the update, which restarts the
  Dock once. With live windows allowed in Login Items that needs nothing from you; otherwise Sunlight asks
  for your administrator password once.
- Quick ⌘Tab taps from a window now fly the windows into place like a held ⌘ does, instead of jumping.

## 0.1

The first public release.

**The canvas**
- Every open window on one infinite canvas you pan and zoom with the trackpad: pinch or ⌥-scroll to zoom,
  two-finger scroll to pan, and four-finger drag to pan from anywhere.
- Click a window to enter it at 1:1, centred, with no seam between the canvas and the real window. A
  four-finger tap or the Mission Control key (F3) goes back, and again goes back into the window. (Settings › Trackpad can make
  See All a four-finger swipe up instead.) A window at 1:1 can be used directly, without entering it.
- Desktop widgets and Finder's desktop files sit on the canvas, with Show Desktop (F11 or the four-finger
  spread), and you can drag files into windows.
- Hidden and minimized windows keep their place, shown as dashed outlines in the minimap.
- Coming to rest almost exactly on a full screen window (a pan, pinch or minimap jump that lands near 1:1
  with its edges nearly lined up) nudges the canvas onto it on a quick spring and enters it. Settings ›
  Canvas › Snap to full screen windows turns it off.
- Windows snap to alignment guides and a grid as you drag, can be resized from their edges, and can push
  each other aside if you want (Settings › Windows).
- Move & Resize: ⌃⌥ shortcuts for halves, quarters, thirds, two-thirds, full screen and centre.
- Saved layouts (⌘S, ⌘1–⌘9) reopen missing apps and documents. The canvas remembers itself between launches.
- Backgrounds: your Mac's wallpaper, Photos, files, colours or gradients, with blur and dim that follow
  the zoom.
- Takeover mode: hides the Dock and makes ⌘Tab, Mission Control and Show Desktop work on the canvas, and
  puts every setting it changed back when you quit.
- Experimental, off by default (Settings › General › Experimental): Arrange and Tidy, and strip mode.
- A canvas on every display, behind Settings › General › Experimental › Multiple displays (off by
  default). Each window is on the canvas of the display it's on, and goes to another
  display's canvas when moved there, from inside it or with ⌃⌥⇧ → ← (Window › Move to Next Display, or its
  right-click menu). ⌘Tab reaches the windows of every display. While you work in a window on one display,
  the others keep their canvas up. Displays plugged in or out are picked up as they come and go.

**Live windows**
- The real windows themselves, scaled on the canvas by a small add-on in the Dock. They need part of
  System Integrity Protection turned off. Until then, preview mode shows windows as live pictures.
- Set Up Sunlight, a step-by-step wizard covering permissions, the Recovery restart (with a QR code for
  your phone) and the background helper, so nothing asks for a password afterwards.
- Live windows on every display, with the Dock add-on sunlight-13 (one lease per display's canvas).
- Diagnose… copies a plain-text report for bug reports. Uninstall Sunlight… walks the whole setup back.

**Getting it**
- A notarized DMG, Homebrew (`brew install spacefarm-digital/tap/sunlight`), and updates through Sparkle.
- macOS 15 or later, Apple silicon. Primary display only for now.
