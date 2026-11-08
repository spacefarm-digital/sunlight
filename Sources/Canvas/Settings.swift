import AppKit
import SwiftUI

/// User preferences, persisted in UserDefaults.
@MainActor
enum Settings {
    enum Renderer: String, CaseIterable {
        case capture, realWindows
        var title: String { self == .capture ? "Capture proxies" : "Scaled real windows" }
    }
    /// Without `screenCapture`, always scaled real windows: capture proxies are a feature behind that flag.
    static var renderer: Renderer {
        get {
            if previewForced { return .capture }
            guard screenCapture else { return .realWindows }
            let value = ProcessInfo.processInfo.environment["CANVAS_RENDERER"]
                ?? UserDefaults.standard.string(forKey: "CanvasRenderer") ?? "capture"
            return Renderer(rawValue: value) ?? .capture
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "CanvasRenderer") }
    }
    /// The near-black graphite the canvas starts with when the Mac is dark.
    static let defaultDarkBackground = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
    /// The pale grey it starts with when the Mac is light.
    static let defaultLightBackground = NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    /// The grid spacings on offer, in points at 1:1. The grid is also the gap the alignment guides leave
    /// between windows side by side.
    static let gridSizes: [CGFloat] = [20, 40, 80]

    /// Which of the two canvas colours is used: the one the Mac's appearance calls for, or one of them always.
    enum Appearance: String, CaseIterable {
        case system, light, dark

        var title: String {
            switch self {
            case .system: return "Match the Mac"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    /// What restoring a layout does with the windows on the canvas that aren't in it.
    enum OtherWindows: String, CaseIterable {
        case ask, leave, moveAside, close

        var title: String {
            switch self {
            case .ask: return "Ask Each Time"
            case .leave: return "Leave Them"
            case .moveAside: return "Move Them Aside"
            case .close: return "Close Them"
            }
        }
    }

    private static let appearanceKey = "CanvasAppearance"
    private static let lightBackgroundKey = "CanvasBackgroundLight"
    private static let darkBackgroundKey = "CanvasBackgroundDark"
    private static let legacyBackgroundKey = "CanvasBackground"
    private static let snapToGridKey = "CanvasSnapToGrid"
    private static let gridSizeKey = "CanvasGridSize"
    private static let alignmentGuidesKey = "CanvasAlignmentGuides"
    private static let magnetismKey = "CanvasMagnetism"
    private static let magnetismStrengthKey = "CanvasMagnetismStrength"
    private static let magneticPolarityKey = "CanvasMagneticPolarity"
    private static let hapticsKey = "CanvasHaptics"
    private static let windowEffectKey = "CanvasWindowEffect"
    private static let tileGapKey = "CanvasTileGap"
    private static let tidyColumnsKey = "TidyColumns"
    private static let tidySizingKey = "TidySizing"
    private static let tidySpacingKey = "TidySpacing"
    private static let tidyOrderKey = "TidyOrder"
    private static let panInertiaKey = "CanvasPanInertia"
    private static let seeAllGestureKey = "CanvasSeeAllGesture"
    private static let zoomInertiaKey = "CanvasZoomInertia"
    private static let snapToWindowsKey = "CanvasSnapToWindows"
    private static let rememberCanvasKey = "CanvasRemember"
    private static let otherWindowsKey = "CanvasOtherWindowsOnRestore"
    private static let switcherEdgeKey = "SwitcherEdge"
    private static let switcherOnKey = "SwitcherOn"

    private static var defaults: UserDefaults { .standard }

    /// Posted when Settings › Windows › Magnetic polarity is switched, so the canvas redoes its chrome.
    static let magneticPolarityDidChange = Notification.Name("CanvasMagneticPolarityDidChange")

    static var appearance: Appearance {
        get {
            migrateLegacyBackground()
            return defaults.string(forKey: appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: appearanceKey) }
    }

    /// The canvas colour while the Mac is light, or always, as `appearance` says (always opaque; the
    /// canvas applies its own alpha).
    static var lightBackground: NSColor {
        get {
            migrateLegacyBackground()
            return color(forKey: lightBackgroundKey) ?? defaultLightBackground
        }
        set { set(newValue, forKey: lightBackgroundKey) }
    }

    /// The canvas colour while the Mac is dark, or always.
    static var darkBackground: NSColor {
        get {
            migrateLegacyBackground()
            return color(forKey: darkBackgroundKey) ?? defaultDarkBackground
        }
        set { set(newValue, forKey: darkBackgroundKey) }
    }

    /// The canvas colour under `appearance` — the view's effective one, which follows System Settings ›
    /// Appearance, Auto's schedule included — or the one chosen regardless.
    static func background(for appearance: NSAppearance) -> NSColor {
        switch self.appearance {
        case .light: return lightBackground
        case .dark: return darkBackground
        case .system:
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkBackground : lightBackground
        }
    }

    /// Both colours back to the defaults; the appearance setting stays.
    static func resetBackgrounds() {
        defaults.removeObject(forKey: lightBackgroundKey)
        defaults.removeObject(forKey: darkBackgroundKey)
    }

    private static var migratedLegacyBackground = false

    /// Before there were two colours there was one, `CanvasBackground`. The first time it's met it becomes
    /// the light or the dark colour, whichever it is, and the other side keeps its default: the colour
    /// chosen is still there, and the canvas matches the Mac from then on unless the setting says otherwise.
    private static func migrateLegacyBackground() {
        guard !migratedLegacyBackground else { return }
        migratedLegacyBackground = true
        guard let legacy = color(forKey: legacyBackgroundKey) else { return }
        set(legacy, forKey: legacy.isLight ? lightBackgroundKey : darkBackgroundKey)
        defaults.removeObject(forKey: legacyBackgroundKey)
    }

    /// Colours are stored as sRGB components so they stay legible in `defaults read com.spacefarm.sunlight`.
    private static func color(forKey key: String) -> NSColor? {
        guard let c = defaults.array(forKey: key) as? [Double], c.count == 3 else { return nil }
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
    }

    private static func set(_ color: NSColor, forKey key: String) {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        defaults.set([c.redComponent, c.greenComponent, c.blueComponent].map(Double.init), forKey: key)
    }

    /// A window let go after a drag settles onto the grid.
    static var snapToGrid: Bool {
        get { defaults.object(forKey: snapToGridKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: snapToGridKey) }
    }

    static var gridSize: CGFloat {
        get {
            let size = CGFloat(defaults.double(forKey: gridSizeKey))
            return gridSizes.contains(size) ? size : 40
        }
        set { defaults.set(Double(newValue), forKey: gridSizeKey) }
    }

    /// The space around a tiled window: from the screen's edges, and between two windows side by side
    /// (Settings › Windows › Tiling › Gap). Also how far a Firm push reaches and how close bonded windows
    /// sit, and the unit Tidy's spacing is counted in. `defaults write <app> CanvasTileGap -float 12` for
    /// a value the menu doesn't offer.
    static var tileGap: CGFloat {
        get { (defaults.object(forKey: tileGapKey) as? Double).map { CGFloat(max(0, min(40, $0))) } ?? 8 }
        set { defaults.set(Double(newValue), forKey: tileGapKey) }
    }

    /// The gaps on offer in Settings.
    static let tileGaps: [CGFloat] = [0, 4, 8, 16, 24]

    // MARK: Tidy

    /// Settings › Experimental › Arranging › Columns: 0 for auto (see `Tidy.columns`).
    static var tidyColumns: Int {
        get { max(0, min(6, defaults.integer(forKey: tidyColumnsKey))) }
        set { defaults.set(newValue, forKey: tidyColumnsKey) }
    }

    static var tidySizing: Tidy.Sizing {
        get { defaults.string(forKey: tidySizingKey).flatMap(Tidy.Sizing.init(rawValue:)) ?? .keep }
        set { defaults.set(newValue.rawValue, forKey: tidySizingKey) }
    }

    static var tidySpacing: Tidy.Spacing {
        get { defaults.string(forKey: tidySpacingKey).flatMap(Tidy.Spacing.init(rawValue:)) ?? .normal }
        set { defaults.set(newValue.rawValue, forKey: tidySpacingKey) }
    }

    /// Window › Tidy By, remembered.
    static var tidyOrder: Tidy.Order {
        get { defaults.string(forKey: tidyOrderKey).flatMap(Tidy.Order.init(rawValue:)) ?? .position }
        set { defaults.set(newValue.rawValue, forKey: tidyOrderKey) }
    }

    /// Everything Tidy needs from here, in one value.
    static var tidyOptions: Tidy.Options {
        Tidy.Options(columns: tidyColumns, sizing: tidySizing, order: tidyOrder, spacing: tidySpacing.points(gap: tileGap))
    }

    /// Settings › Motion › Opening and closing: how windows open onto the canvas and leave it
    /// (`WindowEffect`). Automatic picks per window from where it came from.
    static var windowEffect: WindowEffect {
        get { defaults.string(forKey: windowEffectKey).flatMap(WindowEffect.init(rawValue:)) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: windowEffectKey) }
    }

    /// A dragged window's edges and centre stick to its neighbours', with a guide drawn while they do.
    static var alignmentGuides: Bool {
        get { defaults.object(forKey: alignmentGuidesKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: alignmentGuidesKey) }
    }

    /// A dragged or resized window pushes its neighbours out of the way instead of covering them (see
    /// `Magnetism`). Off, they overlap as they always did. ⌘ overlaps either way. On, a window that opens
    /// over others from inside a window, or back at a last-run place that's been taken, goes to the
    /// nearest free spot too (`CanvasController.placeInFront`, `placeNewWindows`).
    static var magnetism: Bool {
        get { defaults.object(forKey: magnetismKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: magnetismKey) }
    }

    /// Gentle (0) to Firm (1): how far before touching the push starts, and how quickly pushed windows
    /// follow. See `Magnetism.Strength`.
    static var magnetismStrength: CGFloat {
        get { (defaults.object(forKey: magnetismStrengthKey) as? Double).map { CGFloat(max(0, min(1, $0))) } ?? 0.5 }
        set { defaults.set(Double(max(0, min(1, newValue))), forKey: magnetismStrengthKey) }
    }

    /// Settings › Windows › "Magnetic polarity", experimental: with magnetism on, every window is + or −.
    /// Like poles push as above; opposite poles pull together and bond into a group that moves as one
    /// (see `Polarity`). Nothing happens while magnetism itself is off.
    static var magneticPolarity: Bool {
        get { defaults.object(forKey: magneticPolarityKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: magneticPolarityKey) }
    }

    /// Whether poles act and show: magnetism and polarity both on.
    /// (Strip mode has no pushing or bonding; groups wait, inert, until it's off.)
    static var polarityActive: Bool { magnetism && magneticPolarity && !stripMode }

    /// Settings › Motion › "Trackpad haptics": a tap under the finger as a dragged window catches a
    /// guide, bumps a neighbour, repels or draws in a pole, bonds, or is prised off its group (see
    /// `Haptics`). On by default; nothing is felt without a Force Touch trackpad under the hand, or
    /// with haptic feedback off in the Mac's trackpad settings.
    static var haptics: Bool {
        get { defaults.object(forKey: hapticsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: hapticsKey) }
    }

    // MARK: Trackpad

    /// The four-finger gesture that shows everything (and, done again on the canvas, goes back into
    /// the last window), as the Mission Control key does. A tap leaves every four-finger drag a pan; a
    /// swipe up, Mission Control's own gesture, takes the quick upward stroke from panning.
    enum SeeAllGesture: String, CaseIterable, Identifiable {
        case tap, swipeUp
        var id: Self { self }
        var title: String { self == .tap ? "Four-finger tap" : "Four-finger swipe up" }
        var how: String { self == .tap ? "Tap with four fingers" : "Swipe up with four fingers" }
    }
    static let seeAllGestureDidChange = Notification.Name("SunlightSeeAllGestureDidChange")
    static var seeAllGesture: SeeAllGesture {
        get { SeeAllGesture(rawValue: defaults.string(forKey: seeAllGestureKey) ?? "") ?? .tap }
        set {
            defaults.set(newValue.rawValue, forKey: seeAllGestureKey)
            NotificationCenter.default.post(name: seeAllGestureDidChange, object: nil)
        }
    }

    // MARK: Inertia

    /// A four-finger or scroll pan keeps going after the fingers lift, slowing as a scroll does (see
    /// `Motion.PanCoast`). Off, the canvas stops dead when the fingers do, and the Mac's own scroll
    /// momentum is ignored too. On by default. Reduce Motion turns both inertias off either way.
    static var panInertia: Bool {
        get { defaults.object(forKey: panInertiaKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: panInertiaKey) }
    }

    /// A pinch tails off for a moment after the fingers lift (see `Motion.ZoomCoast`). On by default.
    static var zoomInertia: Bool {
        get { defaults.object(forKey: zoomInertiaKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: zoomInertiaKey) }
    }

    /// Coming to rest almost exactly on a screen-sized window (near 1:1, its edges nearly where they'd be
    /// on the screen) nudges the canvas the rest of the way and enters it (see `WindowSnap`). On by default.
    static var snapToWindows: Bool {
        get { defaults.object(forKey: snapToWindowsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: snapToWindowsKey) }
    }

    /// The canvas is written down as it changes and put back at the next launch (see `LayoutStore`).
    static var rememberCanvas: Bool {
        get { defaults.object(forKey: rememberCanvasKey) == nil || defaults.bool(forKey: rememberCanvasKey) }
        set { defaults.set(newValue, forKey: rememberCanvasKey) }
    }

    private static let sunlightOnKey = "SunlightOn"

    /// The menu bar's Sunlight switch. Off, the canvas is away and the keys are the Mac's own, until
    /// it's on again; remembered, so a Sunlight switched off stays off through a relaunch. On by default.
    static var sunlightOn: Bool {
        get { defaults.object(forKey: sunlightOnKey) == nil || defaults.bool(forKey: sunlightOnKey) }
        set { defaults.set(newValue, forKey: sunlightOnKey) }
    }

    static var otherWindows: OtherWindows {
        get { defaults.string(forKey: otherWindowsKey).flatMap(OtherWindows.init(rawValue:)) ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: otherWindowsKey) }
    }

    /// The ⌘Tab icon strip over the canvas (menu bar panel, Settings › Canvas). Off, only the strip
    /// goes: ⌘Tab still flies the canvas from window to window. On by default.
    static var switcherOn: Bool {
        get { defaults.object(forKey: switcherOnKey) == nil || defaults.bool(forKey: switcherOnKey) }
        set { defaults.set(newValue, forKey: switcherOnKey) }
    }

    /// Where the ⌘Tab icon strip shows while ⌘ is held.
    static var switcherEdge: SwitcherEdge {
        get { defaults.string(forKey: switcherEdgeKey).flatMap(SwitcherEdge.init(rawValue:)) ?? .bottom }
        set { defaults.set(newValue.rawValue, forKey: switcherEdgeKey) }
    }

    // MARK: Strip mode

    private static let stripModeKey = "CanvasStripMode"

    /// Window › Strip Mode (⌃⌥S), also Settings › Canvas: every window on one horizontal strip, one
    /// column per app, the one used last on the left (see `Strip`). While it's on, dragging has no guides,
    /// grid or pushing, and the ⌃⌥ arrows step along the strip. Off by default.
    /// Never on while the feature is off (`stripModeEnabled`), whatever was stored before.
    static var stripMode: Bool {
        get { stripModeEnabled && defaults.bool(forKey: stripModeKey) }
        set { defaults.set(newValue, forKey: stripModeKey) }
    }

    /// Posted by the Settings toggle with the wanted state as the object (an `NSNumber`): the canvas
    /// does the switch, animated and undoable, as the menu item does.
    static let stripModeRequested = Notification.Name("CanvasStripModeRequested")

    // MARK: The minimap

    private static let minimapKey = "Minimap"

    /// Whether the minimap is shown. On until it's hidden.
    static var showMinimap: Bool {
        get { UserDefaults.standard.object(forKey: minimapKey) == nil || UserDefaults.standard.bool(forKey: minimapKey) }
        set { UserDefaults.standard.set(newValue, forKey: minimapKey) }
    }

    // MARK: Window names

    private static let windowLabelsKey = "WindowLabels"
    private static var windowLabelsCache: Bool?

    /// Whether each window's name is shown above it on the canvas, zoomed out. On until it's turned
    /// off. Read on every zoom step for every window in view, so it's kept in memory after the first read.
    static var showWindowLabels: Bool {
        get {
            if let cached = windowLabelsCache { return cached }
            let on = UserDefaults.standard.object(forKey: windowLabelsKey) == nil || UserDefaults.standard.bool(forKey: windowLabelsKey)
            windowLabelsCache = on
            return on
        }
        set {
            windowLabelsCache = newValue
            UserDefaults.standard.set(newValue, forKey: windowLabelsKey)
            NotificationCenter.default.post(name: windowLabelsDidChange, object: nil)
        }
    }

    /// Posted when Settings › Canvas › Window names is switched: the canvas shows or hides the labels.
    static let windowLabelsDidChange = Notification.Name("CanvasWindowLabelsDidChange")

    // MARK: Zoom level

    private static let zoomReadoutKey = "ZoomReadout"

    /// Whether the zoom level ("41%") is shown in the canvas's top-left corner, with the `PerfLog` line
    /// under it when that's on. On until it's turned off.
    static var showZoomReadout: Bool {
        get { UserDefaults.standard.object(forKey: zoomReadoutKey) == nil || UserDefaults.standard.bool(forKey: zoomReadoutKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: zoomReadoutKey)
            NotificationCenter.default.post(name: zoomReadoutDidChange, object: nil)
        }
    }

    /// Posted when Settings › Canvas › Zoom level is switched: the canvas shows or hides the readout.
    static let zoomReadoutDidChange = Notification.Name("CanvasZoomReadoutDidChange")

    // MARK: The desktop

    private static let desktopFloorKey = "DesktopFloor"

    /// Whether Finder's desktop is drawn under the windows (`DesktopFloor`). On until it's turned off.
    static var showDesktopFloor: Bool {
        get { UserDefaults.standard.object(forKey: desktopFloorKey) == nil || UserDefaults.standard.bool(forKey: desktopFloorKey) }
        set { UserDefaults.standard.set(newValue, forKey: desktopFloorKey) }
    }

    private static let desktopFilesPlacementKey = "DesktopFilesSpot"
    private static let widgetsPlacementKey = "WidgetsSpot"

    /// Where the desktop's files sit on the canvas (`DesktopPlacement`): right of the windows until
    /// it's changed.
    static var desktopFilesPlacement: DesktopPlacement {
        get { UserDefaults.standard.string(forKey: desktopFilesPlacementKey).flatMap(DesktopPlacement.init(stored:)) ?? .filesDefault }
        set {
            UserDefaults.standard.set(newValue.stored, forKey: desktopFilesPlacementKey)
            NotificationCenter.default.post(name: desktopPlacementDidChange, object: nil)
        }
    }

    /// Where the desktop's widgets sit on the canvas: left of the windows until it's changed.
    static var widgetsPlacement: DesktopPlacement {
        get { UserDefaults.standard.string(forKey: widgetsPlacementKey).flatMap(DesktopPlacement.init(stored:)) ?? .widgetsDefault }
        set {
            UserDefaults.standard.set(newValue.stored, forKey: widgetsPlacementKey)
            NotificationCenter.default.post(name: desktopPlacementDidChange, object: nil)
        }
    }

    /// Settings › Canvas › Desktop: a position was changed; the canvas puts the files and widgets there.
    static let desktopPlacementDidChange = Notification.Name("SunlightDesktopPlacementDidChange")

    // MARK: Experimental features

    private static let arrangingKey = "ArrangingEnabled"
    private static let stripModeEnabledKey = "StripModeEnabled"
    private static let multipleDisplaysKey = "MultipleDisplaysEnabled"
    private static let useScaledWindowsKey = "UseScaledWindowsEnabled"
    private static let scaledClickZoomsKey = "UseScaledWindowsClickZooms"
    private static let scaledHoverFocusKey = "UseScaledWindowsHoverFocus"
    private static let scaledHoverScrollKey = "UseScaledWindowsHoverScroll"

    /// The feature flag for arranging: Arrange (⌃⌥2/3/4, 2×2, 3×2, the windows of one screen) and Tidy
    /// (⌃⌥A, Tidy By, everything). Off by default: no menu items, keys, panel tile or Settings rows, and
    /// the ⌃⌥ digits and A stay with other apps. Move & Resize (one window) isn't behind it.
    /// Settings › Experimental, or `defaults write com.spacefarm.sunlight ArrangingEnabled -bool YES`.
    static var arranging: Bool {
        get { defaults.bool(forKey: arrangingKey) }
        set {
            defaults.set(newValue, forKey: arrangingKey)
            NotificationCenter.default.post(name: experimentalFeaturesDidChange, object: nil)
        }
    }

    /// The feature flag for strip mode (⌃⌥S). Off by default, the same way: no Strip Mode item, key,
    /// panel switch or Settings row, and `stripMode` reads off.
    /// Settings › Experimental, or `defaults write com.spacefarm.sunlight StripModeEnabled -bool YES`.
    static var stripModeEnabled: Bool {
        get { defaults.bool(forKey: stripModeEnabledKey) }
        set {
            defaults.set(newValue, forKey: stripModeEnabledKey)
            NotificationCenter.default.post(name: experimentalFeaturesDidChange, object: nil)
        }
    }

    /// The feature flag for a canvas on every display. Off by default: one canvas, on the main display,
    /// with windows on the others shown where they are, and no Move to Display items or ⌃⌥⇧ keys.
    /// Settings › Experimental, or `defaults write com.spacefarm.sunlight MultipleDisplaysEnabled -bool YES`.
    static var multipleDisplays: Bool {
        get { defaults.bool(forKey: multipleDisplaysKey) }
        set {
            defaults.set(newValue, forKey: multipleDisplaysKey)
            NotificationCenter.default.post(name: experimentalFeaturesDidChange, object: nil)
        }
    }

    /// The feature flag for using windows at any zoom: with live windows, the pointer over a scaled
    /// window's content goes straight through the canvas to it, so clicks, scrolls and typing reach the
    /// app where the window is drawn (the window server hit-tests through the scale). Off by default.
    /// Settings › Experimental, or `defaults write com.spacefarm.sunlight UseScaledWindowsEnabled -bool YES`.
    static var useScaledWindows: Bool {
        get { defaults.bool(forKey: useScaledWindowsKey) }
        set {
            defaults.set(newValue, forKey: useScaledWindowsKey)
            NotificationCenter.default.post(name: experimentalFeaturesDidChange, object: nil)
        }
    }

    /// With windows used at any zoom: single and double click swapped. Off, a click focuses the window
    /// where it is and a double-click zooms it in; on, a click zooms in and a double-click focuses.
    static var scaledClickZooms: Bool {
        get { defaults.bool(forKey: scaledClickZoomsKey) }
        set { defaults.set(newValue, forKey: scaledClickZoomsKey) }
    }

    /// With windows used at any zoom: resting the pointer on a window focuses it, no click.
    static var scaledHoverFocus: Bool {
        get { defaults.bool(forKey: scaledHoverFocusKey) }
        set { defaults.set(newValue, forKey: scaledHoverFocusKey) }
    }

    /// With windows used at any zoom: a two-finger scroll or mouse wheel over any window scrolls it,
    /// clicked into or not, as scrolling does on the Mac (public issue #6). The canvas pans by scrolling
    /// over empty space; ⌥- or ⌘-scroll over a window still zooms the canvas.
    static var scaledHoverScroll: Bool {
        get { defaults.bool(forKey: scaledHoverScrollKey) }
        set { defaults.set(newValue, forKey: scaledHoverScrollKey) }
    }

    private static let tellSunlightKey = "TellSunlightEnabled"

    /// The feature flag for Tell Sunlight: a bar on ⌃⌥Space where a request in words is carried out by
    /// Claude with the canvas's own commands (`AgentBar`). Off by default: no key, nothing sent anywhere.
    /// Needs an Anthropic API key, kept in the keychain (`AgentKey`).
    /// Settings › Experimental, or `defaults write com.spacefarm.sunlight TellSunlightEnabled -bool YES`.
    static var tellSunlight: Bool {
        get { defaults.bool(forKey: tellSunlightKey) }
        set {
            defaults.set(newValue, forKey: tellSunlightKey)
            NotificationCenter.default.post(name: experimentalFeaturesDidChange, object: nil)
        }
    }

    private static let tellSunlightPresenceKey = "TellSunlightPresence"

    /// Tell Sunlight shows what it does: its own pointer moving to each control it presses, a ripple on
    /// the press, a glow along the screen edges while a request runs (`AgentPresence`). On unless turned
    /// off; the user's own pointer is never moved either way.
    static var tellSunlightPresence: Bool {
        get { defaults.object(forKey: tellSunlightPresenceKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: tellSunlightPresenceKey) }
    }

    /// A flag above changed: the menus, the hotkeys and the menu bar panel follow.
    static let experimentalFeaturesDidChange = Notification.Name("SunlightExperimentalFeaturesDidChange")

    // MARK: Screen capture mode

    private static let screenCaptureKey = "ScreenCaptureMode"

    /// The feature flag for screen capture mode (capture proxies, streamed with ScreenCaptureKit). Off by
    /// default: Sunlight runs on scaled real windows, and a stream holds frames the size of the window and
    /// is work for the window server on every change. Off, nothing is ever streamed: while the live-window
    /// add-on is being (re)loaded, and for desktop widgets, the canvas shows stills renewed one at a time.
    static var screenCapture: Bool {
        get { defaults.bool(forKey: screenCaptureKey) }
        set { defaults.set(newValue, forKey: screenCaptureKey) }
    }

    // MARK: Preview mode

    private static let liveWindowsEverLoadedKey = "LiveWindowsEverLoaded"

    /// Whether live windows have ever answered on this Mac. The canvas sets it the first time the add-on
    /// answers; launch sets it on a Mac already set up for them (SIP partly off, boot argument set), so an
    /// upgrade doesn't start in preview mode.
    static var liveWindowsEverLoaded: Bool {
        get { defaults.bool(forKey: liveWindowsEverLoadedKey) }
        set { defaults.set(newValue, forKey: liveWindowsEverLoadedKey) }
    }

    /// Preview mode: a fresh install, before live windows have ever loaded. The canvas streams windows
    /// with ScreenCaptureKit as screen capture mode does, so Sunlight can be tried with nothing but
    /// Accessibility and Screen Recording granted, and a badge on the canvas leads to live windows, the
    /// real thing. It ends by itself the first time live windows load, and never applies once screen
    /// capture mode is on by choice: that person chose capture and gets no badge.
    static var previewMode: Bool {
        previewForced || previewMode(liveWindowsEverLoaded: liveWindowsEverLoaded, screenCapture: screenCapture)
    }

    /// `Sunlight --preview-mode`: preview mode for this launch whatever the Mac, so it can be looked at
    /// on one already set up for live windows. Capture renderer; nothing is saved.
    static var previewForced = false

    /// The rule, for the tests.
    static func previewMode(liveWindowsEverLoaded: Bool, screenCapture: Bool) -> Bool {
        !liveWindowsEverLoaded && !screenCapture
    }

    /// Whether the capture renderer streams at all: in screen capture mode and in preview mode. Otherwise
    /// it's only the stand-in while live windows come back, and every window and widget is a still.
    static var capturesStream: Bool { screenCapture || previewMode }

    // MARK: Capture method

    private static let captureMethodKey = "CanvasCaptureMethod"

    /// Which one-shot path refreshes windows in front of the canvas (see `OneShotCapture`). With nothing
    /// chosen it defaults to the private SkyLight path when that resolved — faster, and no capture pill —
    /// and otherwise to ScreenCaptureKit, so an unavailable private path leaves today's behaviour intact.
    static var captureMethod: CaptureMethod {
        get {
            if let raw = defaults.string(forKey: captureMethodKey), let method = CaptureMethod(rawValue: raw) {
                return method
            }
            return OneShotCapture.skyLightAvailable ? .skyLight : .screenCaptureKit
        }
        set { defaults.set(newValue.rawValue, forKey: captureMethodKey) }
    }

    // MARK: The settings window

    private static let settingsPaneKey = "SettingsPane"

    /// The pane the settings window showed last, which it opens on next time.
    static var settingsPane: String? {
        get { defaults.string(forKey: settingsPaneKey) }
        set { defaults.set(newValue, forKey: settingsPaneKey) }
    }
}

/// The one-shot capture path for windows in front of the canvas (see `OneShotCapture`). Top-level and
/// non-isolated on purpose, so the capture queue and the metrics can name it off the main thread.
enum CaptureMethod: String, CaseIterable {
    case screenCaptureKit
    case skyLight

    var title: String {
        switch self {
        case .screenCaptureKit: return "ScreenCaptureKit"
        case .skyLight: return "SkyLight (Private)"
        }
    }
}

/// ⌘, — the settings window as the Mac's own apps have it: a toolbar of panes across the top, each a
/// one-colour symbol over its name, and under it the chosen pane as a grouped form. A pane is one
/// idea (what's on the canvas, placing windows, how things move) and opens with a stage that acts its
/// settings out and follows them as they change, the way System Settings › Trackpad shows the Mac's
/// gestures; choices that are visual are tiles that draw the choice (`SettingsPictures`). The window
/// takes the pane's name, fits the pane's height and reopens on the pane shown last. It floats over
/// the canvas and opens at the screen's top-right rather than the middle, so most of the canvas stays
/// in view: every change shows on the canvas itself.
@MainActor
final class SettingsWindowController: NSWindowController {
    /// The panes, in toolbar order.
    enum Tab: String, CaseIterable, Identifiable {
        case general, canvas, background, windows, motion, howToUse, liveWindows, experimental

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .canvas: return "Canvas"
            case .background: return "Background"
            case .windows: return "Windows"
            case .motion: return "Motion"
            case .howToUse: return "How to use"
            case .liveWindows: return "Live Windows"
            case .experimental: return "Experimental"
            }
        }

        /// The toolbar's symbol: drawn in one colour, the accent while selected, as in Safari's or Mail's settings.
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .canvas: return "rectangle.3.group"
            case .background: return "photo"
            case .windows: return "macwindow"
            case .motion: return "sparkles"
            case .howToUse: return "questionmark.circle"
            case .liveWindows: return "bolt"
            case .experimental: return "flask"
            }
        }

        /// Panes that used to exist, from an older build's remembered pane: Arrange's rows are under
        /// Experimental now, Trackpad and Shortcuts are How to use.
        init?(remembered: String) {
            switch remembered {
            case "arrange": self = .experimental
            case "trackpad", "shortcuts": self = .howToUse
            default: self.init(rawValue: remembered)
            }
        }
    }

    /// The window's size before a pane has measured itself. Every pane is this wide; the height then
    /// follows the pane, as Apple's settings windows do, up to `maxPaneHeight`, past which it scrolls.
    static let paneSize = NSSize(width: 640, height: 600)
    static let minPaneHeight: CGFloat = 240
    static let maxPaneHeight: CGFloat = 720

    private let model: SettingsModel
    private let tabs: SettingsTabController

    /// Settings › How to use › Placing › Try: the command, on the canvas behind.
    var onTryPlacing: ((PlacementGuide.Scope) -> Void)? {
        get { model.onTryPlacing }
        set { model.onTryPlacing = newValue }
    }
    /// Settings › How to use › Basics › Play the Tutorial.
    var onTutorial: (() -> Void)? {
        get { model.onTutorial }
        set { model.onTutorial = newValue }
    }
    /// Settings › Live Windows › Reload…, and whether it has anything to do.
    var onReloadLiveWindows: (() -> Void)? {
        get { model.onReloadLiveWindows }
        set { model.onReloadLiveWindows = newValue }
    }
    var canReloadLiveWindows: (() -> Bool)? {
        get { model.canReloadLiveWindows }
        set { model.canReloadLiveWindows = newValue }
    }
    /// Settings › General › Take over the Mac: on asks for consent (a sheet on the canvas), off releases
    /// and quits, as the menu's Release the Mac… does.
    var isTakenOver: (() -> Bool)? {
        get { model.isTakenOver }
        set { model.isTakenOver = newValue }
    }
    var onTakeOver: (() -> Void)? {
        get { model.onTakeOver }
        set { model.onTakeOver = newValue }
    }
    var onRelease: (() -> Void)? {
        get { model.onRelease }
        set { model.onRelease = newValue }
    }
    /// Settings › General › Uninstall Sunlight…
    var onUninstall: (() -> Void)? {
        get { model.onUninstall }
        set { model.onUninstall = newValue }
    }
    /// Settings › Canvas › Minimap, Desktop files: the canvas shows or hides them.
    var onMinimapChange: ((Bool) -> Void)? {
        get { model.onMinimapChange }
        set { model.onMinimapChange = newValue }
    }
    var onDesktopFilesChange: ((Bool) -> Void)? {
        get { model.onDesktopFilesChange }
        set { model.onDesktopFilesChange = newValue }
    }
    /// Settings › Canvas › Desktop's map: the canvas as it is now.
    var desktopMap: (() -> DesktopMapSnapshot?)? {
        get { model.desktopMap }
        set { model.desktopMap = newValue }
    }
    /// Settings › General › Check for Updates…; nil hides the row (a build without a Sparkle feed).
    var onCheckForUpdates: (() -> Void)? {
        get { model.onCheckForUpdates }
        set { model.onCheckForUpdates = newValue }
    }

    init(background: BackgroundModel, onRendererChange: @escaping (Settings.Renderer) -> Void, onSetup: @escaping () -> Void) {
        // Read before the tabs exist: adding the first one selects it, which records it as the last pane.
        let last = Settings.settingsPane.flatMap(Tab.init(remembered:)) ?? .general
        let model = SettingsModel(background: background, onRendererChange: onRendererChange, onSetup: onSetup)
        self.model = model
        let tabs = SettingsTabController(model: model)
        self.tabs = tabs

        // Neither zoom nor minimise: the window fits each pane itself, and ⌘, brings it back at once.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.paneSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.toolbarStyle = .preference
        // The canvas is a full-screen window at normal level: a normal-level window would drop behind it the
        // moment you click the canvas to see the change. Floating keeps it on top while Canvas is active, and
        // hiding on deactivate keeps it from lingering over a window you've entered.
        window.level = .floating
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = tabs
        window.setContentSize(Self.paneSize)
        model.window = window
        model.selectTab = { [weak tabs] in tabs?.select($0) }
        tabs.select(last)
        model.refresh()
        placeAtTopRight()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Top-right of the screen, under the menu bar, so the canvas shows beside and below it.
    private func placeAtTopRight() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 24, y: visible.maxY - frame.height - 24))
    }

    /// Opens on a pane (Settings › Background from the canvas's menu, Settings › Windows from the guide).
    func show(tab: Tab) {
        tabs.select(tab)
        showWindow(nil)
    }

    /// Opens on How to use, on a chapter or where it was left.
    func showHowToUse(_ chapter: Manual.Chapter?) {
        if let chapter { model.howToUseChapter = chapter }
        show(tab: .howToUse)
    }

    /// The controls as the settings are now: an alert's "do this every time" can change one meanwhile.
    override func showWindow(_ sender: Any?) {
        model.refresh()
        if window?.isVisible != true { placeAtTopRight() }
        // No Dock icon: opened from the menu bar icon, Sunlight isn't the active app until it says so.
        NSApp.activate()
        super.showWindow(sender)
        // ⌘? through the key tap comes from inside another app's window, where cooperative activation
        // refuses Sunlight and the window, hidden on deactivate, never shows: come forward regardless.
        if !NSApp.isActive {
            forceSunlightFront()
            window?.orderFrontRegardless()
            window?.makeKey()
        }
    }
}

extension SettingsWindowController: NSWindowDelegate {
    /// Close the colour panel with the settings, so it stops driving the canvas.
    func windowWillClose(_ notification: Notification) {
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
    }
}

/// The panes as toolbar tabs: `NSTabViewController` in toolbar style, the Mac's standard settings
/// toolbar, with each pane a SwiftUI form in a hosting controller of its own.
@MainActor
private final class SettingsTabController: NSTabViewController {
    typealias Tab = SettingsWindowController.Tab

    private let model: SettingsModel
    /// Each pane's content height, as its form last measured it.
    private var heights: [Tab: CGFloat] = [:]

    init(model: SettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        for tab in Tab.allCases { addTabViewItem(item(for: tab)) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ tab: Tab) {
        if let index = tabViewItems.firstIndex(where: { $0.identifier as? String == tab.rawValue }) {
            selectedTabViewItemIndex = index
        }
    }

    /// The window takes the pane's name, and the pane is remembered for next time.
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let tabViewItem, let id = tabViewItem.identifier as? String else { return }
        Settings.settingsPane = id
        view.window?.title = tabViewItem.label
        fitWindow()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if tabViewItems.indices.contains(selectedTabViewItemIndex) {
            view.window?.title = tabViewItems[selectedTabViewItemIndex].label
        }
    }

    private func item(for tab: Tab) -> NSTabViewItem {
        var presenter: () -> NSViewController? = { nil }
        let pane = SettingsPane(tab: tab, model: model, presenter: { presenter() },
                                onHeight: { [weak self] height in self?.measured(height, for: tab) })
        let hosting = NSHostingController(rootView: pane)
        presenter = { [weak hosting] in hosting }
        // The size is ours to set, from the height the pane measures (`measured`), not SwiftUI's.
        hosting.sizingOptions = []
        hosting.preferredContentSize = size(for: tab)
        hosting.title = tab.title
        let item = NSTabViewItem(viewController: hosting)
        item.identifier = tab.rawValue
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        return item
    }

    /// A pane's form measured its content: the window grows or shrinks to fit it if it's showing.
    private func measured(_ height: CGFloat, for tab: Tab) {
        guard height > 0, abs((heights[tab] ?? 0) - height) >= 1 else { return }
        heights[tab] = height
        tabViewItems.first { $0.identifier as? String == tab.rawValue }?.viewController?.preferredContentSize = size(for: tab)
        if selectedTab == tab { fitWindow() }
    }

    private var selectedTab: Tab? {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return nil }
        return (tabViewItems[selectedTabViewItemIndex].identifier as? String).flatMap(Tab.init(rawValue:))
    }

    /// The pane's content height, kept between the window's least and most, and inside the screen.
    private func size(for tab: Tab) -> NSSize {
        let defaults = SettingsWindowController.paneSize
        guard let height = heights[tab] else { return defaults }
        var most = SettingsWindowController.maxPaneHeight
        if let screen = (isViewLoaded ? view.window?.screen : nil) ?? NSScreen.main { most = min(most, screen.visibleFrame.height - 120) }
        let fitted = min(max(height, SettingsWindowController.minPaneHeight), max(most, SettingsWindowController.minPaneHeight))
        return NSSize(width: defaults.width, height: fitted.rounded())
    }

    /// The window to the selected pane's height, its top edge staying put as the bottom moves.
    private func fitWindow() {
        guard isViewLoaded, let window = view.window, let tab = selectedTab else { return }
        let size = size(for: tab)
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - size.height) >= 1 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: size))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}


/// The settings window's state: what the slow checks found (the live-window probe,
/// setup progress), and the callbacks into the app. The values themselves live in `Settings`; the
/// views bind to them through `bind`, which tells SwiftUI a change is coming so every row that depends
/// on the value (a slider that greys out, a picker that appears) follows.
@MainActor
final class SettingsModel: ObservableObject {
    typealias Tab = SettingsWindowController.Tab

    let background: BackgroundModel
    let onRendererChange: (Settings.Renderer) -> Void
    let onSetup: () -> Void
    var onTryPlacing: ((PlacementGuide.Scope) -> Void)?
    var onTutorial: (() -> Void)?
    /// Settings › How to use's chapter: the window's ⌘? and the ? in Settings › Windows pick one.
    @Published var howToUseChapter: Manual.Chapter = .basics
    /// Switches the window's pane, for the ? in Settings › Windows.
    var selectTab: ((Tab) -> Void)?
    var onMinimapChange: ((Bool) -> Void)?
    var onDesktopFilesChange: ((Bool) -> Void)?
    var onReloadLiveWindows: (() -> Void)?
    var canReloadLiveWindows: (() -> Bool)?
    var isTakenOver: (() -> Bool)?
    var onTakeOver: (() -> Void)?
    var onRelease: (() -> Void)?
    var onUninstall: (() -> Void)?
    /// The canvas as the desktop map draws it.
    var desktopMap: (() -> DesktopMapSnapshot?)?
    @Published var onCheckForUpdates: (() -> Void)?
    /// The settings window, for the sheets Diagnose… puts up.
    weak var window: NSWindow?

    /// Live windows: answering, loadable, or not to be had, in a line.
    @Published var liveStatus = LiveStatus(state: .checking, text: "Checking live windows…")
    @Published var setupSummary = "Checking setup…"
    /// Whether setup's progress has come back from its first check: until then there are no steps to count.
    @Published var setupChecked = false
    @Published var setupDone = 0
    @Published var setupTotal = 1
    @Published var setupLog = ""
    @Published var showSetupLog = false {
        didSet { if showSetupLog { readSetupLog() } }
    }

    struct LiveStatus {
        enum State { case checking, live, preview, loadable, unavailable }
        var state: State
        var text: String
    }

    init(background: BackgroundModel, onRendererChange: @escaping (Settings.Renderer) -> Void, onSetup: @escaping () -> Void) {
        self.background = background
        self.onRendererChange = onRendererChange
        self.onSetup = onSetup
    }

    /// A binding onto a `Settings` value, with `objectWillChange` so dependent rows redraw.
    func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { [weak self] value in
            self?.objectWillChange.send()
            set(value)
        })
    }

    /// Everything that takes a round trip: the live-window probe and setup's progress, off the main
    /// thread, as before.
    func refresh() {
        objectWillChange.send()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = SetupStatus.current()
            let progress = SetupFlow.progress(for: status, mac: SetupFlow.Mac.current())
            DispatchQueue.main.async {
                guard let self else { return }
                self.setupSummary = status.summary
                self.setupTotal = max(1, progress.total)
                self.setupDone = progress.done
                self.setupChecked = true
                if self.showSetupLog { self.readSetupLog() }
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let available = LiveWindowsConnection.probe()
            // Not loaded but loadable: choosing live windows loads the addition, with a password prompt if need be.
            let loadable = AdditionReloader.helperPath != nil
            DispatchQueue.main.async {
                self?.liveStatus = Self.liveStatus(available: available, loadable: loadable,
                                                   preview: Settings.previewMode, capture: Settings.screenCapture)
            }
        }
    }

    static func liveStatus(available: Bool, loadable: Bool, preview: Bool, capture: Bool) -> LiveStatus {
        if available {
            return LiveStatus(state: .live, text: "Live windows are on. No Screen Recording needed.")
        }
        if loadable {
            return preview
                ? LiveStatus(state: .preview, text: "Preview mode: windows are pictures until setup is done.")
                : LiveStatus(state: .loadable, text: "Live windows aren't loaded yet. Set Up Sunlight loads them.")
        }
        let missing = "the helper is missing"
        if capture { return LiveStatus(state: .unavailable, text: "Live windows unavailable: \(missing). Using screen capture.") }
        if preview { return LiveStatus(state: .unavailable, text: "Preview mode: \(missing).") }
        return LiveStatus(state: .unavailable, text: "Live windows unavailable: \(missing).")
    }

    private func readSetupLog() {
        let text = SetupJournal.read()
        setupLog = text.isEmpty ? "Nothing yet. Set Up Sunlight writes here." : text
    }

    /// Whether live windows can be chosen as the renderer: loaded, or loadable on the way.
    var liveSelectable: Bool { liveStatus.state == .live || liveStatus.state == .loadable || liveStatus.state == .preview }

    /// Off while the strip is up: the canvas puts the free arrangement back first, then the flag goes.
    func setStripModeEnabled(_ on: Bool) {
        objectWillChange.send()
        if !on, Settings.stripMode {
            NotificationCenter.default.post(name: Settings.stripModeRequested, object: NSNumber(value: false))
        }
        Settings.stripModeEnabled = on
    }

    /// The pane's one choice: live windows, or screen capture. Screen capture is the mode with the capture
    /// renderer; live windows turns the mode off, so nothing streams while the add-on comes back either.
    func setRenderer(_ renderer: Settings.Renderer) {
        objectWillChange.send()
        Settings.screenCapture = renderer == .capture
        Settings.renderer = renderer
        onRendererChange(Settings.renderer)
        refresh()
    }

    func setMagnetism(_ on: Bool) {
        objectWillChange.send()
        Settings.magnetism = on
        // Polarity builds on the push: its chrome comes and goes with it.
        if Settings.magneticPolarity { NotificationCenter.default.post(name: Settings.magneticPolarityDidChange, object: nil) }
    }

    func setPolarity(_ on: Bool) {
        objectWillChange.send()
        Settings.magneticPolarity = on
        NotificationCenter.default.post(name: Settings.magneticPolarityDidChange, object: nil)
    }

    func setMinimap(_ on: Bool) {
        objectWillChange.send()
        onMinimapChange?(on)
        Settings.showMinimap = on
    }

    func setWindowLabels(_ on: Bool) {
        objectWillChange.send()
        Settings.showWindowLabels = on
    }

    func setZoomReadout(_ on: Bool) {
        objectWillChange.send()
        Settings.showZoomReadout = on
    }

    func setDesktopFiles(_ on: Bool) {
        objectWillChange.send()
        onDesktopFilesChange?(on)
        Settings.showDesktopFloor = on
    }
}


// MARK: - The panes

/// One pane, by its tab, at the window's width; the window's height follows the pane's content.
private struct SettingsPane: View {
    let tab: SettingsWindowController.Tab
    @ObservedObject var model: SettingsModel
    /// The view controller the pane's sheets (the Photos picker) hang from.
    let presenter: () -> NSViewController?
    /// The form's content height, whenever it changes, for the window to fit.
    let onHeight: (CGFloat) -> Void

    var body: some View {
        content
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom }) { _, height in
                onHeight(height)
            }
            .frame(width: SettingsWindowController.paneSize.width)
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general: GeneralPane(model: model)
        case .canvas: CanvasPane(model: model)
        case .background: BackgroundSettingsView(model: model.background, presenter: presenter)
        case .windows: WindowsPane(model: model)
        case .motion: MotionPane(model: model)
        case .howToUse: HowToUsePane(model: model)
        case .liveWindows: LiveWindowsPane(model: model)
        case .experimental: ExperimentalPane(model: model)
        }
    }
}

/// A section's title with a line or two under it saying what the section is for, as System Settings
/// heads its groups (Battery › Energy Mode). The longer explanations live here, not in the rows.
struct SectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 2)
    }
}

/// A row's title, a short line under it when the title alone doesn't say what the row does, and an ⓘ
/// beside the title for anything longer.
struct RowLabel: View {
    let title: String
    var subtitle: String? = nil
    var info: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(title)
                if let info { InfoButton(text: info) }
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// System Settings' ⓘ: the longer story behind a row, in a popover.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More Information")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(16)
        }
    }
}

/// A small coloured pill with a dot: a state at a glance, beside a title.
struct StatusPill: View {
    let text: String
    let colour: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text(text).font(.caption).fontWeight(.semibold)
        }
        .foregroundStyle(colour)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(colour.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - General

/// Sunlight itself: whether it's taken the Mac over, what comes back at launch, layouts, updates, and
/// the way out.
private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(versionTitle).font(.headline)
                            StatusPill(text: takenOver ? "Taking over the Mac" : "Not taking over", colour: takenOver ? .green : .secondary)
                        }
                        Text("Replaces the Dock, ⌘Tab and Mission Control. Off puts them back.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("Take over the Mac", isOn: model.bind({ model.isTakenOver?() == true }, { on in
                        if on { model.onTakeOver?() } else { model.onRelease?() }
                    }))
                    .labelsHidden()
                }
                .padding(.vertical, 4)
            }
            Section {
                Toggle(isOn: model.bind({ Settings.rememberCanvas }, { Settings.rememberCanvas = $0 })) {
                    RowLabel(title: "Remember the canvas",
                             subtitle: "Windows, zoom and background come back next launch.")
                }
                Picker(selection: model.bind({ Settings.otherWindows }, { Settings.otherWindows = $0 })) {
                    ForEach(Settings.OtherWindows.allCases, id: \.self) { Text($0.title) }
                } label: {
                    RowLabel(title: "Windows not in a layout",
                             subtitle: "What happens to windows a layout leaves out.",
                             info: "Restoring a layout reopens what’s missing. Windows it leaves out can stay, move aside or close.")
                }
            } header: {
                SectionHeader(title: "Between launches")
            }
            if model.onCheckForUpdates != nil {
                Section {
                    LabeledContent {
                        Button("Check Now…") { model.onCheckForUpdates?() }
                    } label: {
                        RowLabel(title: "Check for updates", subtitle: "Sunlight asks before installing.")
                    }
                } header: {
                    SectionHeader(title: "Updates")
                }
            }
            Section {
                LabeledContent {
                    Button("Uninstall…") { model.onUninstall?() }
                } label: {
                    RowLabel(title: "Uninstall Sunlight",
                             subtitle: "Undoes setup and moves Sunlight to the Trash.")
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    private var takenOver: Bool { model.isTakenOver?() == true }

    private var versionTitle: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        guard let version, !version.isEmpty else { return "Sunlight" }
        return "Sunlight \(version)"
    }
}

// MARK: - Canvas

/// What's on the canvas besides the windows: the minimap, the desktop's files, the ⌘Tab strip. The
/// stage shows the canvas as these have it.
private struct CanvasPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                SettingsStage(caption: caption) {
                    CanvasStage(minimap: Settings.showMinimap, files: Settings.showDesktopFloor,
                                strip: Settings.switcherOn, edge: Settings.switcherEdge)
                }
            }
            Section {
                Toggle(isOn: model.bind({ Settings.showMinimap }, { model.setMinimap($0) })) {
                    RowLabel(title: "Minimap",
                             subtitle: "A map of the canvas in the corner.")
                }
                Toggle(isOn: model.bind({ Settings.showWindowLabels }, { model.setWindowLabels($0) })) {
                    RowLabel(title: "Window names",
                             subtitle: "Each window’s name above it, zoomed out.")
                }
                Toggle(isOn: model.bind({ Settings.showZoomReadout }, { model.setZoomReadout($0) })) {
                    RowLabel(title: "Zoom level",
                             subtitle: "How far you’re zoomed, in the top corner.")
                }
                Toggle(isOn: model.bind({ Settings.showDesktopFloor }, { model.setDesktopFiles($0) })) {
                    RowLabel(title: "Desktop files",
                             subtitle: "Your desktop files, under the windows.")
                }
                DesktopMapRow(model: model)
            } header: {
                SectionHeader(title: "On the canvas")
            }
            Section {
                Toggle(isOn: model.bind({ Settings.switcherOn }, { Settings.switcherOn = $0 })) {
                    RowLabel(title: "Show the ⌘Tab strip",
                             subtitle: "⌘Tab still works when it’s off.")
                }
                TileRow {
                    ForEach(SwitcherEdge.allCases, id: \.self) { edge in
                        PictureTile(title: edge.title, selected: Settings.switcherEdge == edge) {
                            model.objectWillChange.send()
                            Settings.switcherEdge = edge
                        } picture: {
                            EdgePicture(edge: edge)
                        }
                    }
                }
                .disabled(!Settings.switcherOn)
                .accessibilityLabel("Edge of the screen the strip hugs")
            } header: {
                SectionHeader(title: "⌘ Tab",
                              detail: "The app strip shown while you hold ⌘.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    private var caption: String {
        var parts: [String] = []
        parts.append(Settings.switcherOn ? "⌘Tab strip on the \(Settings.switcherEdge.title.lowercased())." : "No ⌘Tab strip.")
        parts.append(Settings.showMinimap ? "Minimap on." : "No minimap.")
        if Settings.showDesktopFloor { parts.append("Desktop files on.") }
        if !Settings.showWindowLabels { parts.append("No window names.") }
        if !Settings.showZoomReadout { parts.append("No zoom level.") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Windows

/// Placing windows: what happens under the hand while one is dragged (guides, the grid, magnetism)
/// and the gap tiling leaves. The stage drags a window beside its neighbour with these on.
private struct WindowsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                SettingsStage(caption: caption) { DragStage(placing: placing) }
            }
            Section {
                Toggle(isOn: model.bind({ Settings.alignmentGuides }, { Settings.alignmentGuides = $0 })) {
                    RowLabel(title: "Alignment guides",
                             subtitle: "Edges line up with nearby windows.")
                }
                Toggle(isOn: model.bind({ Settings.snapToGrid }, { Settings.snapToGrid = $0 })) {
                    RowLabel(title: "Snap to grid")
                }
                Picker(selection: model.bind({ Settings.gridSize }, { Settings.gridSize = $0 })) {
                    ForEach(Settings.gridSizes, id: \.self) { Text("\(Int($0)) pt") }
                } label: {
                    RowLabel(title: "Grid step",
                             subtitle: "Also the gap between aligned windows.")
                }
                .pickerStyle(.segmented)
                .disabled(!Settings.snapToGrid && !Settings.alignmentGuides)
            } header: {
                SectionHeader(title: "Dragging",
                              detail: "Hold ⌘ while dragging to place freely.")
            }
            Section {
                Toggle("Windows push each other", isOn: model.bind({ Settings.magnetism }, { model.setMagnetism($0) }))
                LabeledContent {
                    HStack(spacing: 8) {
                        Text("Gentle").font(.caption).foregroundStyle(.secondary)
                        Slider(value: model.bind({ Double(Settings.magnetismStrength) }, { Settings.magnetismStrength = CGFloat($0) }), in: 0...1)
                            .frame(width: 150)
                        Text("Firm").font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    RowLabel(title: "Strength",
                             subtitle: "Firm keeps a gap and pushes whole rows.")
                }
                .disabled(!Settings.magnetism)
                Toggle(isOn: model.bind({ Settings.magneticPolarity }, { model.setPolarity($0) })) {
                    RowLabel(title: "Magnetic polarity",
                             subtitle: "Opposite poles stick together. Like poles repel.",
                             info: "Every window is ⊕ or ⊖. Click its pole or press P to flip it.")
                }
                .disabled(!Settings.magnetism)
            } header: {
                SectionHeader(title: "Magnetism",
                              detail: "Windows move aside instead of overlapping.")
            }
            Section {
                TileRow {
                    ForEach(Settings.tileGaps, id: \.self) { gap in
                        PictureTile(title: gap == 0 ? "None" : "\(Int(gap)) pt", selected: nearestGap == gap) {
                            model.objectWillChange.send()
                            Settings.tileGap = gap
                        } picture: {
                            GapPicture(gap: gap)
                        }
                    }
                }
                .accessibilityLabel("Gap")
            } header: {
                SectionHeader(title: "Tiling",
                              detail: tilingDetail)
            } footer: {
                HStack {
                    Spacer()
                    HelpLink {
                        model.howToUseChapter = .placing
                        model.selectTab?(.howToUse)
                    }
                        .help("How placing works")
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    private var placing: SettingsPictures.Placing {
        SettingsPictures.Placing(guides: Settings.alignmentGuides, grid: Settings.snapToGrid, step: Settings.gridSize,
                                 magnetism: Settings.magnetism, strength: Settings.magnetismStrength, polarity: Settings.magneticPolarity)
    }

    /// What the stage is showing, as the settings have it.
    static func caption(for s: SettingsPictures.Placing) -> String {
        var parts: [String] = []
        if s.guides { parts.append("edges line up") }
        if s.grid { parts.append("it snaps to a \(Int(s.step)) pt grid") }
        if s.magnetism {
            parts.append(s.strength > 0.5 ? "it pushes firmly" : "it pushes gently")
            if s.polarity { parts[parts.count - 1] += " by pole" }
        }
        guard !parts.isEmpty else { return "Nothing catches: a window lands where you drop it." }
        let line = parts.joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst() + "."
    }

    private var caption: String { Self.caption(for: placing) }

    private var tilingDetail: String {
        "⌃⌥ arrows tile halves, U I J K quarters, D F G thirds, ⏎ full screen."
    }

    /// The nearest of the gaps on offer: one set with `defaults write` needn't be among them.
    private var nearestGap: CGFloat {
        let gap = Settings.tileGap
        return Settings.tileGaps.min(by: { abs($0 - gap) < abs($1 - gap) }) ?? 8
    }
}

// MARK: - Motion

/// How things move: windows opening and closing, the camera's inertia, and what the trackpad says
/// back. The stage plays the chosen effect.
private struct MotionPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                SettingsStage(caption: Self.effectLine(Settings.windowEffect)) { EffectStage(effect: Settings.windowEffect) }
            }
            Section {
                TileRow {
                    ForEach(Array(WindowEffect.allCases.enumerated()), id: \.element) { i, effect in
                        PictureTile(title: effect.title, selected: Settings.windowEffect == effect, width: 84) {
                            model.objectWillChange.send()
                            Settings.windowEffect = effect
                        } picture: {
                            EffectStage(effect: effect, tile: true, phase: Double(i) * 0.45)
                        }
                    }
                }
                .accessibilityLabel("Effect")
            } header: {
                SectionHeader(title: "Opening and closing",
                              detail: "Reduce Motion turns every effect into a fade.")
            }
            Section {
                Toggle(isOn: model.bind({ Settings.panInertia }, { Settings.panInertia = $0 })) {
                    RowLabel(title: "Inertia when panning",
                             subtitle: "Pans glide on after you let go.")
                }
                Toggle(isOn: model.bind({ Settings.zoomInertia }, { Settings.zoomInertia = $0 })) {
                    RowLabel(title: "Inertia when zooming",
                             subtitle: "Zooms ease out after you let go.")
                }
                Toggle(isOn: model.bind({ Settings.snapToWindows }, { Settings.snapToWindows = $0 })) {
                    RowLabel(title: "Snap to full-screen windows",
                             subtitle: "Stop near one and you’re in it.")
                }
            } header: {
                SectionHeader(title: "The camera",
                              detail: "Reduce Motion turns inertia off.")
            }
            Section {
                Toggle(isOn: model.bind({ Settings.haptics }, { Settings.haptics = $0 })) {
                    RowLabel(title: "Trackpad haptics",
                             subtitle: "Feel guides catch and windows meet.",
                             info: "Needs a Force Touch trackpad with haptics on in System Settings › Trackpad.")
                }
            } header: {
                SectionHeader(title: "Feedback")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    /// The stage's caption: the effect in a line.
    static func effectLine(_ effect: WindowEffect) -> String {
        switch effect {
        case .automatic: return "Automatic: picks the effect that fits each window."
        case .sunrise: return "Sunrise: rises into place as it brightens."
        case .unfold: return "Unfold: rolls down from its top edge."
        case .bloom: return "Bloom: springs up with a ring of light."
        case .dissolve: return "Dissolve: fades in and out."
        case .none: return "None: no animation."
        }
    }
}

// MARK: - How to use

/// Everything Sunlight teaches, a chapter at a time (`Manual.Chapter`): the basics and the tutorial,
/// the gesture loops (`TrackpadPane`), placing windows acted out (`PlacingChapter`) and every key
/// (`ShortcutsPane`). A reference, not settings, apart from the See everything gesture.
private struct HowToUsePane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Group {
            switch model.howToUseChapter {
            case .basics: BasicsChapter { model.onTutorial?() }
            case .gestures: TrackpadPane()
            case .placing: PlacingChapter(onTry: { model.onTryPlacing?($0) }, arranging: Settings.arranging)
            case .shortcuts: ShortcutsPane()
            }
        }
        // Over the top of the list, as an inset, so the form's measured height counts it and the window fits.
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Chapter", selection: $model.howToUseChapter) {
                ForEach(Manual.Chapter.allCases) { Text($0.short).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

// MARK: - Shortcuts

/// What the canvas does with the pointer, trackpad and keys (`ShortcutReference`): a list to read, not
/// to change. Settings › How to use › Keyboard.
struct ShortcutsPane: View {

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutReference.canvasRows, id: \.title) { row in
                    LabeledContent(row.title) { Text(row.keys).foregroundStyle(.secondary) }
                }
            } header: {
                SectionHeader(title: "Canvas")
            }
            Section {
                ForEach(ShortcutReference.commandRows, id: \.title) { row in
                    LabeledContent(row.title) { Text(row.keys).foregroundStyle(.secondary) }
                }
            } header: {
                SectionHeader(title: "Sunlight",
                              detail: "⌃⌥ keys work inside windows too.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}

// MARK: - Live windows

/// How windows reach the canvas: the real ones through the Dock add-on, or pictures of them; how far
/// setup has come, drawn as the three stages of the way with a mark on each.
private struct LiveWindowsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 0) {
                        PipelineStage(title: "Your windows", line: "the real ones", mark: .done) {
                            MiniWindowsPicture(windows: [CGRect(x: 10, y: 10, width: 34, height: 26), CGRect(x: 40, y: 26, width: 34, height: 26)])
                        }
                        PipelineArrow()
                        PipelineStage(title: "Dock add-on", line: addOnLine, mark: addOnMark) {
                            DockPicture()
                        }
                        PipelineArrow()
                        PipelineStage(title: "The canvas", line: canvasLine, mark: canvasMark) {
                            MiniWindowsPicture(windows: [CGRect(x: 8, y: 8, width: 22, height: 16), CGRect(x: 34, y: 14, width: 26, height: 18),
                                                         CGRect(x: 14, y: 34, width: 20, height: 16), CGRect(x: 52, y: 36, width: 26, height: 18)],
                                               captured: Settings.renderer == .capture)
                        }
                    }
                    HStack(spacing: 8) {
                        StatusPill(text: statusTitle, colour: statusColor)
                        Text(model.liveStatus.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
            Section {
                TileRow {
                    PictureTile(title: "Live windows", selected: Settings.renderer == .realWindows, width: 200) {
                        model.setRenderer(.realWindows)
                    } picture: {
                        ModePicture(live: true)
                    }
                    // Can't load live windows here: screen capture stays, but a Mac showing stills may still pick it.
                    .disabled(!model.liveSelectable)
                    PictureTile(title: "Screen capture", selected: Settings.renderer == .capture, width: 200) {
                        model.setRenderer(.capture)
                    } picture: {
                        ModePicture(live: false)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityLabel("Mode")
            } header: {
                SectionHeader(title: "Mode", detail: rendererDetail)
            }
            Section {
                LabeledContent {
                    Button("Set Up…") { model.onSetup() }
                } label: {
                    RowLabel(title: "Set Up Sunlight", subtitle: setupSubtitle)
                }
                LabeledContent {
                    Button("Reload…") { model.onReloadLiveWindows?() }
                        .disabled(model.canReloadLiveWindows?() != true)
                } label: {
                    RowLabel(title: "Reload live windows", subtitle: "After a Dock restart.")
                }
                LabeledContent {
                    Button("Diagnose…") { SetupDiagnose.run(from: model.window) }
                } label: {
                    RowLabel(title: "Diagnose", subtitle: "Copies a report for a bug.")
                }
                DisclosureGroup(isExpanded: $model.showSetupLog) {
                    ScrollView {
                        Text(model.setupLog)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                } label: {
                    RowLabel(title: "Setup log", subtitle: "What setup did, and when.")
                }
            } header: {
                SectionHeader(title: "Setup",
                              detail: "Live windows need System Integrity Protection partly off.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }

    private var setupSubtitle: String {
        guard model.setupChecked else { return "Checking…" }
        return model.setupDone >= model.setupTotal ? "All done." : "\(model.setupDone) of \(model.setupTotal) steps done."
    }

    private var rendererDetail: String {
        if !model.liveSelectable {
            return Settings.renderer == .capture
                ? "Live windows can’t load on this Mac."
                : "Live windows can’t load here. Pick Screen capture."
        }
        if Settings.previewMode { return "Screen capture until setup is done." }
        return "Screen capture uses more memory and power."
    }

    private var addOnLine: String {
        switch model.liveStatus.state {
        case .checking: return "checking…"
        case .live: return "loaded"
        case .preview, .loadable: return "not loaded yet"
        case .unavailable: return "missing"
        }
    }

    private var addOnMark: PipelineMark {
        switch model.liveStatus.state {
        case .checking: return .pending
        case .live: return .done
        case .preview, .loadable: return .todo
        case .unavailable: return .failed
        }
    }

    private var canvasLine: String {
        if model.liveStatus.state == .live && Settings.renderer == .realWindows { return "live, scaled" }
        if Settings.capturesStream { return "pictures, streamed" }
        return model.liveStatus.state == .checking ? "checking…" : "still pictures"
    }

    private var canvasMark: PipelineMark {
        if model.liveStatus.state == .checking { return .pending }
        if model.liveStatus.state == .live && Settings.renderer == .realWindows { return .done }
        return Settings.capturesStream ? .todo : .failed
    }

    private var statusTitle: String {
        switch model.liveStatus.state {
        case .checking: return "Checking…"
        case .live: return "Live windows on"
        case .preview: return "Preview mode"
        case .loadable: return "Not loaded"
        case .unavailable: return "Unavailable"
        }
    }

    private var statusColor: Color {
        switch model.liveStatus.state {
        case .checking: return .secondary
        case .live: return .green
        case .preview, .loadable: return .orange
        case .unavailable: return .red
        }
    }
}

/// One stage on the way from real windows to the canvas: a picture with a mark on its corner, its
/// name and a line under it.
/// The mark on a stage's corner. Lives outside `PipelineStage` because a type nested in a generic
/// can't be named without the generic's argument.
enum PipelineMark { case done, todo, failed, pending }

struct PipelineStage<Picture: View>: View {
    let title: String
    let line: String
    let mark: PipelineMark
    @ViewBuilder let picture: () -> Picture

    var body: some View {
        VStack(spacing: 6) {
            picture()
                .frame(width: 120, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, colour)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)).padding(1))
                        .offset(x: 6, y: -6)
                }
            Text(title).font(.subheadline).fontWeight(.semibold)
            Text(line).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(line)")
    }

    private var symbol: String {
        switch mark {
        case .done: return "checkmark.circle.fill"
        case .todo: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .pending: return "ellipsis.circle.fill"
        }
    }

    private var colour: Color {
        switch mark {
        case .done: return .green
        case .todo: return .orange
        case .failed: return .red
        case .pending: return .gray
        }
    }
}

private struct PipelineArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(height: 64)
            .accessibilityHidden(true)
    }
}

/// A few windows on the sky, at the tile's size; captured ones under a film's scan lines.
struct MiniWindowsPicture: View {
    let windows: [CGRect]
    var captured = false

    var body: some View {
        Canvas { ctx, drawn in
            let screen = SettingsPictures.screen(in: &ctx, drawn: drawn, base: SettingsPictures.tileSize, bezel: 0)
            for r in windows { MiniCanvasPicture.drawWindow(r, acted: false, in: &ctx) }
            if captured {
                var y = screen.minY + 1
                while y < screen.maxY {
                    ctx.fill(Path(CGRect(x: screen.minX, y: y, width: screen.width, height: 1)), with: .color(.black.opacity(0.09)))
                    y += 3
                }
            }
        }
    }
}

/// The Dock, with Sunlight's rays among its icons.
struct DockPicture: View {
    var body: some View {
        Canvas { ctx, drawn in
            let base = SettingsPictures.tileSize
            let k = drawn.width / base.width
            ctx.scaleBy(x: k, y: k)
            let whole = CGRect(origin: .zero, size: base)
            ctx.fill(Path(whole), with: .linearGradient(Gradient(colors: [Color(white: 0.92), Color(white: 0.8)]),
                                                        startPoint: CGPoint(x: whole.midX, y: whole.minY), endPoint: CGPoint(x: whole.midX, y: whole.maxY)))
            let bar = CGRect(x: 14, y: base.height - 24, width: base.width - 28, height: 17)
            var shadowed = ctx
            shadowed.addFilter(.shadow(color: .black.opacity(0.2), radius: 3, y: 1))
            shadowed.fill(Path(roundedRect: bar, cornerRadius: 5, style: .continuous), with: .color(.white.opacity(0.7)))
            for i in 0..<4 {
                let r = CGRect(x: bar.minX + 5 + CGFloat(i) * 15, y: bar.minY + 3.5, width: 10, height: 10)
                let colour = i == 2 ? SettingsPictures.sun : SettingsPictures.apps[i]
                ctx.fill(Path(roundedRect: r, cornerRadius: 3, style: .continuous), with: .color(colour))
                if i == 2 { ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4), with: .color(.white), lineWidth: 1.2) }
            }
        }
    }
}

// MARK: - Experimental

/// Unfinished features, each a card with its picture, its switch, and its own settings under it while
/// it's on: Arrange and Tidy, strip mode, a canvas per display, using windows at any zoom.
private struct ExperimentalPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabCard(kind: .arranging, title: "Arranging",
                        line: "Arrange in columns (⌃⌥2–4) or tidy everything (⌃⌥A).",
                        on: model.bind({ Settings.arranging }, { Settings.arranging = $0 })) {
                    Picker(selection: model.bind({ Settings.tidyColumns }, { Settings.tidyColumns = $0 })) {
                        Text("Auto").tag(0)
                        ForEach(2...6, id: \.self) { Text("\($0)").tag($0) }
                    } label: {
                        RowLabel(title: "Tidy columns")
                    }
                    Picker(selection: model.bind({ Settings.tidySizing }, { Settings.tidySizing = $0 })) {
                        ForEach(Tidy.Sizing.allCases, id: \.self) { Text($0.title) }
                    } label: {
                        RowLabel(title: "Sizes",
                                 info: "Same size gives every window an equal cell.")
                    }
                    Picker(selection: model.bind({ Settings.tidySpacing }, { Settings.tidySpacing = $0 })) {
                        ForEach(Tidy.Spacing.allCases, id: \.self) { Text($0.title) }
                    } label: {
                        RowLabel(title: "Spacing", subtitle: "In tiling gaps.")
                    }
                    .pickerStyle(.segmented)
                    Picker(selection: model.bind({ Settings.tidyOrder }, { Settings.tidyOrder = $0 })) {
                        ForEach(Tidy.Order.allCases, id: \.self) { Text($0.title) }
                    } label: {
                        RowLabel(title: "Order", subtitle: "How windows are lined up.")
                    }
                }
                LabCard(kind: .strip, title: "Strip mode",
                        line: "Every app on one endless strip (⌃⌥S).",
                        on: model.bind({ Settings.stripModeEnabled }, { model.setStripModeEnabled($0) })) {
                    Toggle(isOn: model.bind({ Settings.stripMode }, { on in
                        NotificationCenter.default.post(name: Settings.stripModeRequested, object: NSNumber(value: on))
                    })) {
                        RowLabel(title: "On the strip now",
                                 subtitle: "⌃⌥ arrows step along it.")
                    }
                }
                LabCard(kind: .displays, title: "Multiple displays",
                        line: "A canvas on each display. ⌃⌥⇧ arrows move windows over.",
                        on: model.bind({ Settings.multipleDisplays }, { Settings.multipleDisplays = $0 })) {
                    EmptyView()
                }
                LabCard(kind: .anyZoom, title: "Use windows at any zoom",
                        line: "Click and type in windows while zoomed out.",
                        info: "Live windows only. A click focuses a window; until then a drag anywhere moves it. Once you’re in it, drags are the app’s own (select text, drag a file), the title bar or ⌘ moves it, and a double-click still brings it to the middle at 1:1. Scroll bars and sliders are always the app’s. Right-click opens Sunlight’s window menu anywhere on a window. Pinch and two-finger scroll over a window move the canvas until you’re in the window; then they’re the window’s. With Scroll the window under the pointer on, scrolling is the window’s from the start.",
                        on: model.bind({ Settings.useScaledWindows }, { Settings.useScaledWindows = $0 })) {
                    Toggle(isOn: model.bind({ Settings.scaledClickZooms }, { Settings.scaledClickZooms = $0 })) {
                        RowLabel(title: "Single click zooms in",
                                 subtitle: "Double-click to focus in place.")
                    }
                    Toggle(isOn: model.bind({ Settings.scaledHoverFocus }, { Settings.scaledHoverFocus = $0 })) {
                        RowLabel(title: "Focus follows the pointer",
                                 subtitle: "No click needed to focus.")
                    }
                    Toggle(isOn: model.bind({ Settings.scaledHoverScroll }, { Settings.scaledHoverScroll = $0 })) {
                        RowLabel(title: "Scroll the window under the pointer",
                                 subtitle: "No click needed to scroll. Scroll on empty space to move the canvas.")
                    }
                }
                LabCard(kind: .agent, title: "Tell Sunlight",
                        line: "Say what to do with your windows and apps (⌃⌥Space).",
                        info: "Each request sends what you typed and your window list (app names, titles, positions) to Anthropic’s API with your key, plus the text of a window it works inside. Nothing is sent until you press ⏎. Sending, deleting, paying or publishing waits for your Allow. Settings, passwords and terminal apps are never worked inside. The key stays in your keychain.",
                        on: model.bind({ Settings.tellSunlight }, { Settings.tellSunlight = $0 })) {
                    AgentKeyRow()
                    Toggle(isOn: model.bind({ Settings.tellSunlightPresence }, { Settings.tellSunlightPresence = $0 })) {
                        RowLabel(title: "Show what it’s doing",
                                 subtitle: "Its own pointer moves to each button it presses. Yours stays yours.")
                    }
                }
            } header: {
                SectionHeader(title: "Experimental",
                              detail: "Unfinished features. Off by default.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}

/// A feature's card: its picture, name and line beside its switch, and its own rows under them while
/// it's on, indented to the text.
struct LabCard<Rows: View>: View {
    let kind: LabPicture.Kind
    let title: String
    let line: String
    var info: String? = nil
    @Binding var on: Bool
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                LabPicture(kind: kind)
                RowLabel(title: title, subtitle: line, info: info)
                Spacer(minLength: 8)
                Toggle(title, isOn: $on).labelsHidden()
            }
            .padding(.vertical, 4)
            if on {
                VStack(alignment: .leading, spacing: 0) {
                    rows()
                        .padding(.vertical, 6)
                }
                .padding(.leading, 76)
                .padding(.top, 4)
            }
        }
    }
}

/// Where the desktop's files and widgets sit: a map of the whole canvas at true proportions, the
/// windows and both blocks to scale, and a dot for each block at its spot (`DesktopPlacement`).
private struct DesktopMapRow: View {
    @ObservedObject var model: SettingsModel
    /// The canvas, refreshed while the pane is open.
    @State private var canvas: DesktopMapSnapshot?
    /// The part of the world the map shows, held while a dot is dragged so it doesn't shift underfoot.
    @State private var frozen: CGRect?
    /// A dot on its way somewhere: shown there, saved when let go.
    @State private var draggingFiles: DesktopPlacement?
    @State private var draggingWidgets: DesktopPlacement?

    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private static let size = CGSize(width: 320, height: 192)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RowLabel(title: "Where they sit", subtitle: "Drag the dots to move files and widgets.")
            map.frame(maxWidth: .infinity)
            HStack {
                Spacer()
                Button("Reset") {
                    model.objectWillChange.send()
                    Settings.widgetsPlacement = .widgetsDefault
                    Settings.desktopFilesPlacement = .filesDefault
                }
                .disabled(Settings.widgetsPlacement == .widgetsDefault && Settings.desktopFilesPlacement == .filesDefault)
            }
        }
        .onAppear(perform: readCanvas)
        .onReceive(refresh) { _ in readCanvas() }
    }

    private func readCanvas() {
        guard frozen == nil, let now = model.desktopMap?() ?? nil, now != canvas else { return }
        canvas = now
    }

    private var isDragging: Bool { draggingFiles != nil || draggingWidgets != nil }

    /// Where the blocks land for the dots as they are, dragged ones included.
    private func blocks(_ c: DesktopMapSnapshot) -> (widgets: CGRect?, files: CGRect?) {
        DesktopPlacement.rects(widgets: c.widgets.map { ($0.size, draggingWidgets ?? Settings.widgetsPlacement) },
                               files: c.files.map { ($0.size, draggingFiles ?? Settings.desktopFilesPlacement) },
                               around: c.bounds)
    }

    private func world(_ c: DesktopMapSnapshot) -> CGRect {
        frozen ?? DesktopPlacement.mapWorld(around: c.bounds, blocks: [c.widgets, c.files].compactMap { $0 },
                                            aspect: Self.size.width / Self.size.height)
    }

    private var map: some View {
        let c = canvas ?? DesktopMapSnapshot(bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), windows: [])
        let w = world(c)
        let k = w.width > 0 ? Self.size.width / w.width : 1
        func toMap(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - w.minX) * k, y: (r.minY - w.minY) * k, width: r.width * k, height: r.height * k)
        }
        func toMap(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - w.minX) * k, y: (p.y - w.minY) * k) }
        func toWorld(_ q: CGPoint) -> CGPoint {
            CGPoint(x: w.minX + min(Self.size.width, max(0, q.x)) / k, y: w.minY + min(Self.size.height, max(0, q.y)) / k)
        }
        let placed = blocks(c)
        let box = toMap(c.bounds)
        let filesOn = Settings.showDesktopFloor
        let files = draggingFiles ?? Settings.desktopFilesPlacement
        let widgets = draggingWidgets ?? Settings.widgetsPlacement
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.secondary.opacity(0.08))
            if c.windows.isEmpty {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .overlay(Text("Screen").font(.caption).foregroundStyle(.secondary))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
            }
            ForEach(c.windows.indices, id: \.self) { i in
                let r = toMap(c.windows[i])
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.secondary.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5))
                    .frame(width: max(2, r.width), height: max(2, r.height))
                    .offset(x: r.minX, y: r.minY)
            }
            if let r = placed.widgets.map(toMap) { patch(r, color: .orange) }
            if let r = placed.files.map(toMap) { patch(r, color: .blue) }
            dot(title: "Desktop files", symbol: "folder.fill", color: .blue, at: toMap(files.world(around: c.bounds)), spot: files,
                enabled: filesOn,
                drag: { frozen = w; draggingFiles = DesktopPlacement(world: toWorld($0), around: c.bounds) },
                drop: { draggingFiles = nil; frozen = nil; model.objectWillChange.send()
                        Settings.desktopFilesPlacement = DesktopPlacement(world: toWorld($0), around: c.bounds) })
            dot(title: "Widgets", symbol: "square.text.square.fill", color: .orange, at: toMap(widgets.world(around: c.bounds)), spot: widgets,
                enabled: true,
                drag: { frozen = w; draggingWidgets = DesktopPlacement(world: toWorld($0), around: c.bounds) },
                drop: { draggingWidgets = nil; frozen = nil; model.objectWillChange.send()
                        Settings.widgetsPlacement = DesktopPlacement(world: toWorld($0), around: c.bounds) })
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
        .coordinateSpace(name: "desktopMap")
        .animation(isDragging ? nil : .easeInOut(duration: 0.3), value: w)
    }

    /// A block on the map, faint, at its real size.
    private func patch(_ r: CGRect, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color.opacity(0.15))
            .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(color.opacity(0.5), lineWidth: 0.5))
            .frame(width: max(2, r.width), height: max(2, r.height))
            .offset(x: r.minX, y: r.minY)
            .allowsHitTesting(false)
    }

    private func dot(title: String, symbol: String, color: Color, at c: CGPoint, spot: DesktopPlacement, enabled: Bool,
                     drag: @escaping (CGPoint) -> Void, drop: @escaping (CGPoint) -> Void) -> some View {
        let d: CGFloat = 22
        return Circle()
            .fill(enabled ? color : Color.secondary.opacity(0.5))
            .overlay(Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            .frame(width: d, height: d)
            .contentShape(Circle())
            .offset(x: c.x - d / 2, y: c.y - d / 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("desktopMap"))
                .onChanged { drag($0.location) }
                .onEnded { drop($0.location) })
            .allowsHitTesting(enabled)
            .help("\(title): \(spot.title)")
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue(spot.title)
    }
}

extension NSColor {
    /// True when black text out-contrasts white on this colour (WCAG relative luminance above ~0.18).
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent)
            + 0.0722 * linear(c.blueComponent)
        return luminance > 0.179
    }
}

// MARK: - Tell Sunlight's key

/// The Anthropic API key, typed or pasted once and kept in the keychain (`AgentKey`). Shown only as its
/// last four characters after that.
private struct AgentKeyRow: View {
    @State private var saved = AgentKey.stored.map(AgentKey.masked)
    @State private var typed = ""
    @State private var failed = false

    var body: some View {
        if let saved {
            LabeledContent {
                Button("Remove") {
                    AgentKey.remove()
                    self.saved = nil
                }
            } label: {
                RowLabel(title: "Anthropic API key", subtitle: "Saved in your keychain: \(saved)")
            }
        } else {
            LabeledContent {
                HStack {
                    SecureField("sk-ant-…", text: $typed)
                        .frame(width: 220)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } label: {
                RowLabel(title: "Anthropic API key",
                         subtitle: failed ? "The keychain didn’t take it. Try again." : "From console.anthropic.com › API keys.")
            }
        }
    }

    private func save() {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        failed = !AgentKey.save(key)
        typed = ""
        if !failed { saved = AgentKey.masked(key) }
    }
}
