# Installing Sunlight

Sunlight shows your real windows, live, on an infinite canvas. To do that it runs a small add-on inside
the Dock, which macOS only allows with part of System Integrity Protection (SIP) turned off. You can try
Sunlight before any of that: the first launch opens **Set Up Sunlight**, a short full-screen wizard, and after two
permissions the canvas opens in **preview mode**, where your windows are pictures. Live windows are the
real thing and much smoother; **Use Full Version**, on a small "Demo mode" card in the canvas's bottom-left corner, leads back into the wizard for them.

**You need:** a Mac with Apple silicon on macOS 15 or later, and an administrator account. An Intel Mac,
or an older macOS, gets the preview only; the wizard says so on its first page.

## 1. Install the app

Open `Sunlight-<version>.dmg` and drag Sunlight to Applications. With Homebrew, run
`brew install --cask spacefarm-digital/tap/sunlight` instead. Release builds are notarized, so they open without
a Gatekeeper warning. Updates come through **Check for Updates…** (the menu bar icon › More, or Settings › General). Opened from the disk image
or from Downloads instead, Sunlight offers to move itself to Applications first: its background helper
and login item register where the app lives, so a copy anywhere else stops working once it's moved or
ejected. Not Now is remembered for that copy.

## 2. The preview: two permissions

Open Sunlight. The wizard fills the screen, one step at a time, with the steps as dots above; each page
watches System Settings and moves on by itself the moment its step is done. While you're in System
Settings the wizard steps aside, and it comes back as soon as you return to Sunlight.

1. **Welcome.** Leave "Open Sunlight when I log in" on if you'd like Sunlight, and the wizard, back by
   themselves after the restart live windows need. Click **Get Started**.
2. **Accessibility.** This is how Sunlight moves, raises and focuses other apps' windows. **Allow
   Accessibility…** opens System Settings › Privacy & Security › Accessibility; turn Sunlight on there.
3. **Screen Recording.** This shows your windows as pictures in preview mode, and desktop widgets always.
   **Allow Screen Recording…** opens the pane; turn Sunlight on. macOS applies the permission to a fresh
   launch, so Sunlight relaunches itself and comes straight back to the wizard. **Skip for now** leaves it
   off: the canvas then shows window frames and titles only, and the preview page offers it again.
4. **The preview.** Click **Open the Canvas**. Sunlight is usable from here on. The rest turns the preview
   into live windows, and starts from **Use Full Version** on the "Demo mode" card in the canvas's bottom-left corner or from the preview page's
   **Set Up Live Windows**.

## 3. Live windows

Three things to do, then a restart; after the restart there is nothing to click.

5. **Why SIP goes partly off.** Live windows run inside the Dock, which macOS only allows with Filesystem
   Protections and Debugging Restrictions off (and NVRAM protection, so the boot argument can be set).
   The page says what stays on and what it costs. Tick the box and click **Continue**.
6. **Background helper.** Click **Turn On…**. System Settings › General › Login Items opens; switch Sunlight
   on under **Allow in the Background**. This lets Sunlight load its Dock add-on after the restart, and
   reload it after every Dock restart, without asking for your password. It comes before the restart on
   purpose: with it on, nothing afterwards asks for anything. (A build without a team signature, such as
   one built from source with no signing identity, has no helper: it asks for your password the first
   time instead, then sets up passwordless reloads itself, and the wizard skips this page.)
7. **Restart into Recovery.** The one step with Sunlight closed, designed to be read from a phone: scan the
   QR code to open the steps at [sunlight.software/recovery](https://sunlight.software/recovery), or
   **Send to iPhone…** by AirDrop or Messages, which needs no internet on the phone. **Shut Down…** shuts the Mac down; Sunlight
   notes where you were and comes back to the next page afterwards. The steps:
   1. Press and hold the power button until "Loading startup options" appears, then choose **Options**.
   2. Choose **Utilities › Terminal**, pick your administrator account if asked, and type:
      ```
      csrutil enable --without fs --without debug --without nvram
      nvram boot-args=-arm64e_preview_abi
      ```
      The second line replaces any boot arguments already set. If it is refused, skip it: the next page
      sets the argument from macOS, with one more restart.
   3. Choose Apple menu › Restart.
8. **Welcome back.** The wizard checks SIP and the boot argument itself. If the boot argument is missing,
   **Set It and Restart** sets it through the helper (no password) and restarts once more.
9. **Loading live windows.** Nothing to click: the page starts the load as it opens. Sunlight installs its
   add-on as `/Library/ScriptingAdditions/Sunlight.osax`, restarts the Dock once, and switches the canvas
   to live windows the moment the add-on answers. Preview mode is over: from now on, the moment after a
   Dock restart while live windows reload shows windows as still pictures. (A build without the helper's
   daemon has a **Load Live Windows** button here instead, since its load may ask for your password; and
   if a load doesn't come through, **Try Again** appears.)
10. **Tour.** The handful of things to know, and the optional step of making Sunlight your Mission
    Control.

The wizard can be closed at any page and reopened from **Sunlight › Finish Setting Up Sunlight…**, the
rays icon in the menu bar (which fills one ray per step while setup is unfinished), or Settings › Live Windows.
The checkbox at the bottom of the live-windows pages, "Open this at launch until live windows are set up",
turns the reminder off.

## Checking it

Settings › Live Windows has the steps done (its ⓘ names the ones left) and a **Setup log** disclosure showing what the
wizard did and what the helper answered. **Diagnose…** there, or on the Welcome back and Load pages,
copies a plain-text report to the clipboard and saves it beside the log: the Mac's facts, every setup
step, the renderer, what the helper says about the add-on, and the log's tail. No window titles or
pictures, so it can go straight into an issue. Its Stability section lists how the last runs ended, the
stalls Sunlight's watchdog caught, and the newest crash reports of Sunlight and the Dock. The full log is
~/Library/Logs/Sunlight/Sunlight.log; it names apps and windows, so attach it only if you're happy to. From Terminal:

```
/Applications/Sunlight.app/Contents/MacOS/Sunlight --renderer-status
/Applications/Sunlight.app/Contents/MacOS/Sunlight --diagnose
```

Look for `Sunlight live-window protocol v1: available`. If the Dock restarts and windows don't come back
live, use **Reload Live Windows…** (the menu bar icon › More, or Settings › Live Windows › Reload…). `--setup-preview <scenario>` shows the wizard for a
made-up Mac (`--setup-preview list` names them), with ← and → paging through every screen.

## Undoing it

**Settings › General › Uninstall Sunlight…** walks the install backwards in one window, each step ticking as the
Mac confirms it: the add-on out of the Dock (your administrator password), the boot argument and the
password rule earlier builds wrote (two Terminal lines, shown with Copy; the page ticks when they've
run), the background helper and the login item off (and the Dock, Finder and Mission Control put back if
Sunlight had taken over), System Integrity Protection back on (the Recovery card again, with
`csrutil enable`, or **Leave It Off**), then **Move to Trash and Quit**, with a box for removing settings,
layouts and background pictures too. Afterwards, remove Sunlight from Accessibility and Screen Recording
in System Settings › Privacy & Security.

The same by hand:

1. Quit Sunlight, then in Terminal:
   ```
   sudo /Applications/Sunlight.app/Contents/Helpers/SunlightLiveWindows unload
   sudo rm -f /private/etc/sudoers.d/sunlight-live-windows
   sudo nvram -d boot-args
   ```
   The last line removes every boot argument; to keep others, set `boot-args` to them instead.
2. Turn Sunlight off in System Settings › General › Login Items, and drag it to the Trash (or run
   `brew uninstall --zap sunlight`, which also removes the add-on and the settings).
3. Start up in Recovery as in step 7, run `csrutil enable` in Terminal, and restart.

## Building from source

You need macOS 15 or later on Apple silicon and Xcode 16 or later (the command-line tools are enough:
`xcode-select --install`; with them the app gets a flat icon, and full Xcode 26 or later compiles the
Liquid Glass one with its dark, clear and tinted looks). Then:

```
git clone <this repo> && cd <it>
make run      # builds build/Sunlight.app and runs it with its log in the terminal
swift test    # the tests
```

`make app` builds the bundle without running it. Copy `build/Sunlight.app` to /Applications and open it
from there if you want the background helper and the login item: they register where the app lives.

The build is signed with the first identity it finds in your keychain, and what you get depends on it:

| Identity | How to get one | What changes |
|---|---|---|
| Developer ID Application | a paid Apple Developer account | Everything works as in a release, except notarization (see below) |
| Apple Development | free: sign in with your Apple ID in Xcode › Settings › Accounts, then Manage Certificates › + | Everything works on your own Mac, background helper included. Not for giving to other people |
| none (ad-hoc) | nothing to do, or `SIGN=-` to force it | No background helper: the first live-windows load asks for your administrator password, then adds a password rule pinned to the helper's hash so later Dock restarts reload silently. A changed helper asks once more. macOS may also forget the Accessibility and Screen Recording grants after a rebuild: if windows stop moving or capturing, remove Sunlight from both privacy panes and add it again |

`SIGN="Apple Development: Your Name (TEAMID)"` picks a particular identity. The bundle identifier is
`com.spacefarm.sunlight` either way; to keep your build apart from an installed release, change
`BUNDLE_ID` in the Makefile and `CFBundleIdentifier` in `Info.plist` together.

A build from source reads `packaging/release.conf` too, so it checks the official update feed and Sparkle
offers official releases, which replace it. To leave updates off, empty `SPARKLE_PUBLIC_KEY` there.

`make live-windows` builds just the helper and the Dock add-on into `build/live-windows/`. Live windows
need the same SIP setup as a release (section 3 above); a build from source changes nothing about that.

## Building a release (maintainers)

`make package` builds and signs `build/Sunlight.app`, a zip and a DMG. `make dist` builds a public release
in `build/release/`. It needs these:

- A **Developer ID Application** identity in the keychain. The app, the helper and Sparkle are signed
  with the hardened runtime and a secure timestamp, and the helper's launch daemon plist goes in.
- **NOTARY_PROFILE**, a notarytool profile: `xcrun notarytool store-credentials sunlight --apple-id <id>
  --team-id <team>`, with an app-specific password. Then use `make dist NOTARY_PROFILE=sunlight`. The app
  and the DMG are both notarized and stapled.
- **Sparkle keys**, made once: `make sparkle-keys` keeps the private key in the login keychain and prints
  the public one. Put the public key in `SPARKLE_PUBLIC_KEY` in `packaging/release.conf`. Builds without
  it leave updates off.
- A higher `CFBundleVersion` in `Info.plist` for each release, since Sparkle compares versions by it.

The DMG opens as a Finder window with the hill background and Sunlight next to an Applications shortcut.
The photo and the rendered background at 1x and 2x live in `packaging/dmg/` (`make dmg-background`
re-renders them from `scripts/make-dmg-background.swift`); the window's size and the icons' places are in
`scripts/make-dmg-layout.swift`, which writes the layout onto each disk image.

`make dist` writes the DMG, the zip, `appcast.xml` and the cask (`sunlight.rb`, with this version's
checksum), plus the same DMG as plain `Sunlight.dmg`, which the website's Download button fetches from
the latest release. `scripts/release.sh --publish` also creates the GitHub release in `RELEASES_REPO` using `gh`;
leave it a full release, not a pre-release, or GitHub's "latest" (and the Download button) skips it.
Then copy `sunlight.rb` to `Casks/` in `TAP_REPO`. Both repos are set in `packaging/release.conf`.
