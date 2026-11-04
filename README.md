<div align="center">

<img src="docs/images/icon.png" width="128" height="128" alt="Sunlight's icon: a black sun on yellow">

# Sunlight

**The first camera-based inifinite canvas window manager for Mac**<br>
Free, open source and yours forever.

[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](#requirements)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-only-black)](#requirements)
[![Beta](https://img.shields.io/badge/status-beta-f5c518)](#beta-heads-up)
[![MIT licence](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)

[**Download for Mac**](https://github.com/spacefarm-digital/sunlight-releases/releases/latest/download/Sunlight.dmg)
&nbsp;·&nbsp; [Homebrew](#install)
&nbsp;·&nbsp; [sunlight.software](https://sunlight.software)
&nbsp;·&nbsp; [How it works](docs/how-it-works.md)

</div>

<p align="center">
  <img src="docs/images/hero.gif" width="800" alt="Sunlight in action: from inside Safari out to the canvas with five windows, zooming and panning, then back into Safari at full size">
</p>

---

## What is this?

Your Mac stacks windows on top of each other like a pile of pizza boxes. Sunlight lays them all out
on a canvas that goes on forever instead. Every window you have open stays on it, live, right where you
put it. Pinch out and your whole day is in front of you. Click one and it grows into the real window at
its real size, no seam, no "preview", and you just keep working.

Desktop widgets and the files on your desktop live on the canvas too, and ⌘Tab, Mission Control and Show
Desktop all land on it. So it's still your Mac. It just has room now.

<p align="center">
  <img src="docs/images/hero.png" width="800" alt="The canvas zoomed out to 23%: Safari, TextEdit, Calculator, Finder and Terminal laid out over the wallpaper, desktop files on the left and the minimap in the corner">
</p>

## Features

- 🗺️ **One infinite canvas.** Pan with two fingers, pinch to zoom, four-finger drag to pan from anywhere,
  even over a window.
- 🪟 **Real windows, not screenshots.** With live windows on, the canvas shows the actual windows, scaled
  in place by a small add-on in the Dock. At 1:1 you can click, type and scroll in them right there.
- 🎯 **Seamless handoff.** Click a window to step into it where it is; double-click to bring it to the
  middle. The Mission Control key (F3) or a four-finger tap takes you back out, and again takes you back in.
- 🧲 **Neat without trying.** Windows snap to guides and a grid as you drag, resize from their edges, and
  can shove each other out of the way if you want them to (Settings › Windows).
- ⌨️ **Move & Resize keys.** ⌃⌥ + arrows for halves, plus quarters, thirds, two-thirds, full screen and
  centre.
- 💾 **Layouts.** ⌘S saves where everything is, ⌘1 – ⌘9 brings it back, reopening apps and documents that
  were closed.
- 🖥️ **Your desktop comes along.** Finder's desktop files are the canvas floor (open, drag, rename, drag into
  a window), widgets sit beside your windows, and Show Desktop (F11 or the four-finger spread) flies there.
- 🖼️ **Picture in Picture, for any window.** Right-click a window › Picture in Picture (⌃⌥P) and it flies
  into a corner as a small live tile, like a video does, while you work in anything else: a call, a video,
  a timer. Drag it between corners, tuck it off the side; a click brings it back full size.
- 🫥 **Nothing gets lost.** Hidden and minimized windows keep their spot, shown dashed in the minimap.
- 🌄 **Backgrounds** from your wallpaper, Photos, files, colours or gradients, with blur and dim that follow
  the zoom.
- 🦸 **Takeover mode.** Hides the Dock and makes ⌘Tab, Mission Control and Show Desktop work on the canvas.
  Quit, and every setting it touched goes back how it was.
- 🧪 **Experimental**, off until you flip them in Settings › Experimental: Arrange and Tidy,
  strip mode (every app on one endless strip), and a canvas on every display.

## Getting around

<p align="center">
  <img src="docs/images/gestures.png" width="820" alt="Settings › How to use acting out two gestures: a click bringing a window forward, and the four-finger spread for Show Desktop">
</p>

| To | Trackpad | Keys |
|---|---|---|
| Zoom | pinch | ⌥ or ⌘ + scroll |
| Pan | two-finger scroll, or four-finger drag from anywhere | |
| Go into a window | click it (double-click to centre it), or pinch in over it | ⏎ over it |
| Use a window at 1:1 | just click, type and scroll, as on the desktop | |
| See everything, and back in | four-finger tap | Mission Control key (F3) |
| Show Desktop | four-finger spread (thumb and three fingers) | F11 |
| Move & Resize a window | | ⌃⌥ ← → ↑ ↓ halves, U I J K quarters, D F G thirds, ⏎ full, C centre |
| Picture in Picture | right-click a window › Picture in Picture | ⌃⌥P |
| Save / restore a layout | | ⌘S / ⌘1 – ⌘9 |
| Settings · How to use | | ⌘, · ⌘? |

Everything else lives in the **sun icon in the menu bar** (Sunlight has no Dock icon): the on/off switch,
the minimap, your layouts, and More for the rest. **Settings › How to use** (⌘?) is the whole manual: the basics,
every gesture acted out, placing windows and every key. The full list of controls is in
[docs/how-it-works.md](docs/how-it-works.md#controls).

## Two ways to run it

You can try Sunlight with nothing but two privacy permissions. The full version needs one bigger step.

| | Demo mode | Live windows |
|---|---|---|
| Windows on the canvas | live pictures from the screen recording API | the real windows, scaled |
| Streaming | the 8 largest at 30 fps, the rest once a second | every window, always, at full refresh rate |
| Energy while panning | about 20% more | normal |
| What it needs | Accessibility and Screen Recording | part of System Integrity Protection (SIP) off, and an admin password once |

Live windows work by loading a tiny add-on into the Dock, which macOS only allows with part of SIP turned
off. The **Set Up Sunlight** wizard walks you through it one screen at a time, Recovery restart included
(there's a QR code so you can follow along on your phone while your Mac reboots).
**Settings › General › Uninstall Sunlight…** walks all of it back. Read
[LiveWindows/README.md](LiveWindows/README.md) for exactly what the add-on does and why before you
flip anything.

## Install

**Download** the DMG and drag Sunlight to Applications:

<p>
  <a href="https://github.com/spacefarm-digital/sunlight-releases/releases/latest/download/Sunlight.dmg"><b>⬇️ Sunlight.dmg</b></a>
  &nbsp;(all releases on the <a href="https://github.com/spacefarm-digital/sunlight-releases/releases">releases page</a>)
</p>

**Or with Homebrew:**

```sh
brew install --cask spacefarm-digital/tap/sunlight
```

The first launch opens **Set Up Sunlight**, which grants the permissions and lands you on the canvas in
demo mode. From there the demo mode card leads to live windows whenever you're ready. Sunlight updates
itself (it asks first). [INSTALL.md](INSTALL.md) covers every step, checking the setup, and removing it.

### Requirements

- A Mac with **Apple silicon** (M1 or later)
- **macOS 15** Sequoia or later
- An administrator account, for live windows
- **Stage Manager off**. Setup turns it off for you, and Sunlight turns it back on when it quits
- One canvas on the **main display** by default; the others show where their windows are. A canvas on
  every display is experimental (Settings › Experimental › Multiple displays).

## Beta heads-up

Sunlight 0.1 is the first public release, and it's a beta. It moves windows around, talks to the Dock and
takes over a few system shortcuts, so expect the odd glitch. Live windows have had the most miles on
macOS 27. If something goes sideways, **Settings › Live Windows › Diagnose…** copies a plain-text report
(no window titles or pictures) you can paste into an
[issue](https://github.com/spacefarm-digital/sunlight/issues). Turning Sunlight off from the menu bar puts
every window back at 1:1 where it was.

## Privacy

No analytics, no crash reporting, no accounts. The only thing Sunlight sends over the network is the update
check (Sparkle fetching the release feed, `packaging/release.conf`). Window pictures, titles and layouts stay
on your Mac.

## Build from source

```sh
make run
```

Needs macOS 15 or later and Xcode 16 or later (the command-line tools are enough). `swift test` runs the
tests. The build signs with the first Developer ID Application or Apple Development identity in your
keychain, or ad-hoc with neither; [INSTALL.md](INSTALL.md#building-from-source) says what each one changes.
How the canvas is drawn, the handoff, the add-on and the known limits are all in
[docs/how-it-works.md](docs/how-it-works.md).

## Contributing

Bug reports, ideas and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and see
[SECURITY.md](SECURITY.md) for reporting anything security related privately. What changed in each version
is in [CHANGELOG.md](CHANGELOG.md).

## Credits and licence

Sunlight is MIT licensed, see [LICENSE](LICENSE). Made by spacefarm.

The Dock add-on and its loader in `LiveWindows/osax` are adapted from
[yabai](https://github.com/koekeishiya/yabai)'s scripting addition (MIT, © 2019 Åsmund Vikane), by way of
the macOS 27 fork at [LCS-Dev-Ergos/yabai](https://github.com/LCS-Dev-Ergos/yabai); see
`LiveWindows/osax/LICENSE-yabai.txt`. Huge thanks to everyone who figured out the Dock first.
