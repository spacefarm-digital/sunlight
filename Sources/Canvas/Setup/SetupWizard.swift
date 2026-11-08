import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Set Up Sunlight: one step to a screen, full-screen on the canvas's screen, over a field of slow light
/// that rises as the steps are done. `SetupFlow` picks the page from the Mac's state (`SetupStatus`),
/// what the person has done so far (`SetupRecord`) and the Mac's fixed facts; this controller builds
/// each page's words and buttons (`SetupPageSpec`), runs them, and checks the Mac once a second while the
/// window is open, so a page moves on by itself the moment its step is done in System Settings.
///
/// Two phases. The permissions make the preview work, and the canvas opens. Live windows, the real
/// thing, start from the demo mode card on the canvas (or the preview page): consent, the background helper, then
/// the one step that happens with Sunlight closed, the Recovery restart. The wizard notes where it sent
/// the person and resumes there at the next launch (`SetupRecord.setResume`); with the helper already
/// on, the load page that follows starts the load by itself, so the way back needs nothing clicked.
///
/// A floating window of an inactive app stays over other apps' windows, so the window floats only while
/// Sunlight is the active app (`float`), is never ordered over another app, and gets out of the way
/// whenever setup sends the person to System Settings or a system prompt (`stepAside`): it comes back,
/// re-checked, once the step is done or Sunlight is in front again.
@MainActor
final class SetupWizardController: NSWindowController, NSWindowDelegate {
    /// The load page's button: switch the canvas to live windows and load the add-on, asking if need be.
    var onLoadLiveWindows: (() -> Void)?
    /// The tour's optional last step: takeover mode's own consent, asked once the window is away.
    var onTakeOver: (() -> Void)?
    /// Whether takeover mode is on already, for the tour's button.
    var isTakenOver: (() -> Bool)?
    /// Every fresh look at the Mac, whether or not the window is open: the menu bar's rays follow it.
    var onStatus: ((SetupStatus) -> Void)?
    /// The window came up or went away, for the canvas to hold its own activations while it's up.
    var onVisibilityChanged: ((Bool) -> Void)?
    /// The window went away: what waited on it can happen.
    var onClose: (() -> Void)?

    private static let showAtLaunchKey = "SunlightSetupAtLaunch"
    /// Past preview mode: whether the window opens at launch while a live-windows step is missing.
    static var showsAtLaunch: Bool {
        get { UserDefaults.standard.object(forKey: showAtLaunchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showAtLaunchKey) }
    }

    let mac: SetupFlow.Mac
    private let statusProvider: @Sendable () -> SetupStatus
    /// `--setup-preview`: faked state, arrow keys page through, and nothing relaunches or shuts down.
    private let review: Bool
    /// `SUNLIGHT_SETUP_TOUR` with `--setup-preview`: the window below every other, never in front or
    /// key, paging through by itself and quitting at the end, so it can be captured by its number while
    /// the Mac is in use.
    private let isTour: Bool
    private(set) var status: SetupStatus?
    private(set) var page: SetupFlow.Page?
    private(set) var isShowing = false
    /// A page chosen by hand (Show the Recovery Steps; review mode's arrow keys) over the routed one.
    private var manual: SetupFlow.Page?
    /// The tutorial played again from Settings › How to use: its last button closes the window.
    private var replaying = false
    private let resumeHint: SetupFlow.Page?
    /// Review mode's fixed record, in place of what's stored.
    private let reviewRecord: SetupFlow.Record?
    private var timer: Timer?
    private var tourTimer: Timer?
    private var checking = false
    private var busy: Set<SetupFlow.Page> = []
    private var askedForScreenRecording = false
    private var relaunching = false
    private var loadingSince: Date?
    /// The load page has started the load by itself once this launch (`SetupFlow.loadsByItself`): a
    /// load that doesn't come through isn't retried every second, the button does that.
    private var loadedByItself = false
    private var lastRouted: SetupFlow.Page?
    private var appliedStatus: SetupStatus?
    private var appliedKey = ""
    private var lastDone = -1

    let model: SetupWizardModel
    private let backdrop: SetupBackdropView
    private let hosting: NSHostingView<SetupWizardView>
    private let screen: NSScreen
    private var observers: [NSObjectProtocol] = []
    private var fade = 0
    private var hideWork: DispatchWorkItem?
    /// Faded away while another app (System Settings, for a step) is in front.
    private var steppedAside = false
    /// When `comeForward` last asked LaunchServices, so a reopen it causes can't ask again.
    private var lastReopen: Date?
    /// Ten seconds of welcome, the first time the window opens on its welcome page (`WelcomeMusic`).
    private let music = WelcomeMusic.Player()

    init(mac: SetupFlow.Mac, statusProvider: @escaping @Sendable () -> SetupStatus, reviewRecord: SetupFlow.Record? = nil) {
        self.mac = mac
        self.statusProvider = statusProvider
        review = reviewRecord != nil
        self.reviewRecord = reviewRecord
        isTour = review && ProcessInfo.processInfo.environment["SUNLIGHT_SETUP_TOUR"] != nil
        resumeHint = reviewRecord == nil ? SetupRecord.takeResume() : nil
        let screen = NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0]
        self.screen = screen
        model = SetupWizardModel(review: review)
        backdrop = SetupBackdropView(frame: NSRect(origin: .zero, size: screen.frame.size))
        hosting = NSHostingView(rootView: SetupWizardView(model: model, metrics: SetupMetrics.fit(screen: screen), onLater: {}))

        let window = SetupWizardWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Set Up Sunlight"
        // Above the canvas while Sunlight is active, as Settings is (`float`); at the normal level, and
        // faded away, while another app is in front (`hideSoon`, `stepAside`).
        window.level = isTour ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow))) : .normal
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = true
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.alphaValue = 0
        window.backgroundColor = backdrop.backdrop?.groundColor ?? .black
        if isTour, ProcessInfo.processInfo.environment["SUNLIGHT_SETUP_TOUR_DARK"] != nil {
            window.appearance = NSAppearance(named: .darkAqua)
        }
        super.init(window: window)
        window.delegate = self
        window.onKey = { [weak self] key in self?.handle(key) ?? false }
        window.onClose = { [weak self] in self?.close() }

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true
        backdrop.autoresizingMask = [.width, .height]
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        container.addSubview(backdrop)
        container.addSubview(hosting)
        window.contentView = container
        hosting.rootView = SetupWizardView(model: model, metrics: SetupMetrics.fit(screen: screen), onLater: { [weak self] in self?.close() })

        backdrop.setReduceMotion(BackgroundSources.reduceMotion)
        backdrop.setHighContrast(BackgroundSources.increaseContrast)
        backdrop.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
        backdrop.isPaused = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// To the setup journal, except in review mode, whose made-up Mac would only muddle it.
    private func journal(_ line: String) {
        if !review { SetupJournal.note(line) }
    }

    /// What the person has done, with the resume page taken at launch.
    private var record: SetupFlow.Record {
        if let reviewRecord { return reviewRecord }
        var record = SetupRecord.current
        record.resume = resumeHint
        return record
    }

    // MARK: Showing

    /// At launch. Opens when `SetupFlow.opensAtLaunch` says so; either way reports the status, and
    /// whether the window opened, so the caller can fall back to the system's own permission prompt.
    func showIfNeeded(_ completion: @escaping (_ shown: Bool, _ status: SetupStatus) -> Void) {
        check { [weak self] status in
            guard let self else { return }
            let opens = SetupFlow.opensAtLaunch(status: status, record: self.record, mac: self.mac,
                                                previewMode: Settings.previewMode, showsAtLaunch: Self.showsAtLaunch,
                                                quietReloadPaused: AdditionReloader.pausedAfterDockCrashes)
            if !opens, !Settings.previewMode, SetupFlow.onlyTheAddOnIsMissing(status) {
                journal("Live windows not answering at launch; the canvas reloads them by itself")
            }
            if opens { self.showWindow(nil) }
            completion(opens, status)
        }
    }

    /// Asks the Mac again while the window is closed, so the menu bar's rays and its Set Up item follow,
    /// e.g. once the canvas has reloaded the add-on by itself after launch (public issue #10). While
    /// the window is up, its own timer checks every second.
    func recheck() {
        guard !isShowing else { return }
        // A check already under way may have asked before the add-on answered: ask once more after it.
        if checking { recheckAfterCheck = true } else { check() }
    }
    private var recheckAfterCheck = false

    /// Settings › How to use › Basics › Play the Tutorial: the basics page from its first step, whatever else is left
    /// to set up; finishing it closes the window.
    func showBasics() {
        replaying = true
        manual = .basics
        model.tutorialInput = nil
        model.lesson = 0
        if page == .basics, let status { refresh(status) }
        showWindow(nil)
    }

    /// From the menu, Settings or the demo mode card. `startingLive`: the card, so the live-windows phase begins
    /// rather than the preview page saying everything's fine.
    func show(startingLive: Bool) {
        if startingLive, !SetupRecord.startedLive {
            SetupRecord.startedLive = true
            journal("Live windows setup started")
        }
        replaying = false
        manual = nil
        showWindow(nil)
    }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }
        if isShowing {
            // The reopen `comeForward` asked LaunchServices for: the activation it brings raises the window
            // (`returned`); asking again from here would only loop while macOS holds the activation back.
            if let lastReopen, Date().timeIntervalSince(lastReopen) < 2 {
                check()
                return
            }
            if isTour { bringForward() } else { comeBack() }
            check()
            return
        }
        isShowing = true
        window.setFrame(screen.frame, display: false)
        window.backgroundColor = backdrop.backdrop?.groundColor ?? window.backgroundColor
        backdrop.isPaused = false
        backdrop.drawNow()
        dockIcon(true)
        bringForward()
        if let resume = record.resume, !review { journal("Back in front after the relaunch, at \(resume.rawValue)") }
        fadeIn(duration: 0.45)
        // At launch the page was routed before the window opened; otherwise the check below routes it.
        if let page { welcome(page) }
        check()
        if timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            t.tolerance = 0.25
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        observe()
        onVisibilityChanged?(true)
        if isTour, tourTimer == nil {
            let t = Timer(timeInterval: 3.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tourStep() }
            }
            RunLoop.main.add(t, forMode: .common)
            tourTimer = t
        }
        Log.note("Setup: opened, window \(window.windowNumber)")
    }

    private func bringForward() {
        guard let window else { return }
        if isTour {
            window.orderFront(nil)
            return
        }
        comeForward()
    }

    /// Sunlight and the wizard to the front. With no Dock icon there's nothing to click back to, and
    /// macOS often turns down an activation from the background, so: ask, and if the app still isn't
    /// active a moment later, have LaunchServices open our own bundle, which activates the running copy.
    /// The window goes over other apps only once Sunlight is active (`returned`), never regardless:
    /// ordered over an app that kept the front, it would cover System Settings, or a system prompt,
    /// with nothing to make it step aside again.
    private func comeForward() {
        guard let window else { return }
        NSApp.activate()
        if NSApp.isActive { float(true) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.isShowing, !NSApp.isActive else { return }
            let bundle = Bundle.main.bundleURL
            guard bundle.pathExtension == "app", self.lastReopen.map({ Date().timeIntervalSince($0) > 2 }) ?? true else { return }
            self.lastReopen = Date()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
                if let error { Log.note("Setup: couldn't bring Sunlight forward: \(error.localizedDescription)") }
            }
        }
    }

    /// Open the Canvas, Done, Set Up Later, Esc, ⌘W: fades away and tells the app.
    override func close() {
        guard let window, isShowing else { return }
        isShowing = false
        PermissionDragPanel.shared.hide()
        stopWatching()
        dockIcon(false)
        music.fadeOut()
        fadeOut(duration: 0.3) {
            window.orderOut(nil)
            self.backdrop.isPaused = true
        }
        onVisibilityChanged?(false)
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        guard isShowing else { return }
        isShowing = false
        PermissionDragPanel.shared.hide()
        stopWatching()
        dockIcon(false)
        music.fadeOut(duration: 0.2)
        backdrop.isPaused = true
        onVisibilityChanged?(false)
        onClose?()
    }

    /// A Dock icon while the window is up, and only then: something to click to get back to setup from
    /// System Settings, where the menu bar icon is easy to miss. The click arrives as a reopen, which
    /// brings the window forward (`showWindow`). Not in the tour, which stays out of sight.
    private func dockIcon(_ shown: Bool) {
        guard !isTour else { return }
        let policy: NSApplication.ActivationPolicy = shown ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let wasActive = NSApp.isActive
        NSApp.setActivationPolicy(policy)
        // Going back to accessory can deactivate the app: the canvas the window closed onto stays in front.
        if !shown, wasActive { NSApp.activate() }
    }

    private func stopWatching() {
        // A replay of the tutorial ends with the window; next time it opens where setup is.
        if replaying {
            replaying = false
            manual = nil
        }
        timer?.invalidate()
        timer = nil
        tourTimer?.invalidate()
        tourTimer = nil
        unobserve()
    }

    /// The canvas couldn't load the add-on: said on the load page rather than on a sheet behind it.
    func reportLiveWindowsFailure(_ why: String) {
        loadingSince = nil
        journal("Load live windows failed: \(why)")
        notice("Live windows couldn’t be loaded.", "The live-window addition \(why). Sunlight keeps using capture proxies.")
        if let status { refresh(status) }
    }

    // MARK: Review and tour

    /// Review mode: the page before or after, wrapping.
    private func step(_ by: Int) {
        let all = SetupFlow.Page.allCases
        let current = all.firstIndex(of: manual ?? page ?? .welcome) ?? 0
        manual = all[(current + by + all.count) % all.count]
        if let status { apply(status) }
    }

    /// The tour walks every page from the welcome, a few seconds each, and quits after the last.
    private func tourStep() {
        guard manual != nil else {
            manual = .welcome
            if let status { apply(status) }
            return
        }
        if manual == .tour {
            tourTimer?.invalidate()
            tourTimer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
            return
        }
        step(1)
    }

    // MARK: Checking

    /// Asks the Mac, off the main thread, and applies the answer.
    private func check(then: ((SetupStatus) -> Void)? = nil) {
        guard !checking else { return }
        checking = true
        let provider = statusProvider
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = provider()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checking = false
                    self.apply(status)
                    then?(status)
                    if self.recheckAfterCheck {
                        self.recheckAfterCheck = false
                        self.recheck()
                    }
                }
            }
        }
    }

    private func apply(_ status: SetupStatus) {
        let previous = self.status
        self.status = status
        onStatus?(status)
        guard isShowing || page == nil else { return }
        // Screen Recording just went on: macOS applies it to a fresh launch, so relaunch and come back.
        if askedForScreenRecording, status.screenRecording, !relaunching, !review {
            relaunch(resumingAt: .screenRecording)
            return
        }
        // A step done in System Settings while the wizard waited out of the way: back in front for the next.
        if steppedAside, isShowing, let previous, let step = SetupFlow.stepFinished(from: previous, to: status) {
            journal("Back in front after \(step)")
            comeBack()
        }
        if status.liveWindowsLoaded, loadingSince != nil {
            loadingSince = nil
            journal("Live windows loaded")
        }
        let routed = SetupFlow.page(for: status, record: record, mac: mac)
        // A hand-picked page gives way once the Mac moves on to another step.
        if manual != nil, let lastRouted, lastRouted != routed, !review { manual = nil }
        lastRouted = routed
        let target = manual ?? routed
        // Back from Recovery with the helper on: nothing to click, the load starts as the page opens.
        if target == .load, !review, !loadedByItself, loadingSince == nil, isShowing, SetupFlow.loadsByItself(status) {
            loadedByItself = true
            journal("Load live windows: starting by itself")
            startLoad()
        }
        let key = "\(busy.count) \(relaunching) \(loadingSince != nil) \(loadingStalled) \(loadedByItself) \(askedForScreenRecording)"
        if target != page {
            let from = page
            page = target
            if target == .consent { model.consent = false }
            if target == .loginItem { model.loginItem = true }
            if target == .basics, !replaying {
                model.tutorialInput = nil
                model.lesson = 0
            }
            journal("Page: \(target.rawValue)")
            show(target, from: from, status: status)
            if from == nil { welcome(target) }
        } else if status != appliedStatus || key != appliedKey {
            refresh(status)
        }
        appliedStatus = status
        appliedKey = key
        model.rail = SetupFlow.rail(for: status, record: record, mac: mac, showing: target)
        model.showsOpenAtLaunch = !review && target.isLive && target != .tour
        mood(for: target, status: status)
    }

    /// The music, once ever, when the window first opens on its welcome page; every time in review
    /// mode, so it can be heard again. Not in the tour, which plays below everything for capturing.
    private func welcome(_ page: SetupFlow.Page) {
        guard page == .welcome, isShowing, !isTour, review || !WelcomeMusic.played else { return }
        if !review { WelcomeMusic.played = true }
        journal("Welcome music")
        // The screen follows the music: the light rises with it from dark, the sun with it, and the rest
        // of the page part by part on its chimes (`WelcomeReveal.moments`), Get Started on the closing
        // chord. If it can't play, all of it at once.
        model.reveal = .none
        backdrop.holdDark()
        music.play(cues: [(0, { [weak self] heard in self?.backdrop.sunrise(over: heard ? WelcomeMusic.climax : 0) })]
                   + WelcomeReveal.moments.map { moment in (moment.at, { [weak self] _ in self?.reveal(moment.reveal) }) })
        // In case rendering is slow (a debug build): nothing waits for long.
        DispatchQueue.main.asyncAfter(deadline: .now() + WelcomeMusic.climax + 1.5) { [weak self] in
            guard let self, self.model.reveal < .headline else { return }
            self.backdrop.sunrise(over: 0)
            self.reveal(.all)
        }
    }

    /// Brings the page in up to `part`; the light swells softly on the reveal chime and, more gently,
    /// on the closing chord.
    private func reveal(_ part: WelcomeReveal) {
        guard model.reveal < part else { return }
        let from = model.reveal
        model.reveal = part
        if from < .headline, part >= .headline { backdrop.swell(0.9, rise: 0.45, fall: 1.6) }
        if part == .start, from >= .headline { backdrop.swell(0.5, rise: 0.6, fall: 2.2) }
    }

    private var loadingStalled: Bool { loadingSince.map { Date().timeIntervalSince($0) > 45 } ?? false }

    /// The light: progress from the steps done, warmth from how far along the pages this one is. A step
    /// newly done flares it.
    private func mood(for page: SetupFlow.Page, status: SetupStatus) {
        let (done, total) = SetupFlow.progress(for: status, mac: mac)
        let all = SetupFlow.Page.allCases
        let index = Float(all.firstIndex(of: page) ?? 0)
        backdrop.mood = SetupMood(progress: total == 0 ? 1 : Float(done) / Float(total), warmth: index / Float(all.count - 1))
        if lastDone >= 0, done > lastDone { backdrop.flare() }
        lastDone = done
    }

    private func show(_ page: SetupFlow.Page, from: SetupFlow.Page?, status: SetupStatus) {
        let all = SetupFlow.Page.allCases
        let forward = (all.firstIndex(of: page) ?? 0) >= (from.flatMap { all.firstIndex(of: $0) } ?? -1)
        model.leaving = from == nil ? nil : model.spec
        model.direction = forward ? .forward : .backward
        model.notice = nil
        model.copied = false
        model.spec = spec(for: page, status: status)
        model.page = page
        model.transition += 1
    }

    /// The same page, the Mac having been looked at again: its words and buttons brought up to date.
    private func refresh(_ status: SetupStatus) {
        guard let page else { return }
        model.spec = spec(for: page, status: status)
    }

    // MARK: Pages

    /// Diagnose…, on the pages where something may have gone wrong: the report for an issue.
    private var diagnose: SetupPageSpec.Action {
        SetupPageSpec.Action(id: "diagnose", title: "Diagnose…") { [weak self] in SetupDiagnose.run(from: self?.window) }
    }

    private func action(_ id: String, _ title: String, enabled: Bool = true, _ run: @escaping () -> Void) -> SetupPageSpec.Action {
        SetupPageSpec.Action(id: id, title: title, enabled: enabled, run: run)
    }

    private func spec(for page: SetupFlow.Page, status: SetupStatus) -> SetupPageSpec {
        switch page {
        case .welcome:
            return SetupPageSpec(page: page, headline: "Welcome to Sunlight.",
                                 subheadline: "The first camera-based infinite canvas window manager for Mac.", paragraphs: [],
                                 primary: action("primary", "Get Started") { [weak self] in self?.getStarted() }, showsIcon: true)

        case .loginItem:
            var note: String?
            if !mac.liveWindowsSupported {
                note = "This Mac can show the preview only: live windows need Apple silicon and macOS 15 or later."
            } else if !mac.admin {
                note = "Live windows will need an administrator, since two of the steps change the Mac’s settings."
            }
            // A rough idea of what's ahead: the two permissions for the preview, then live windows.
            let estimate = mac.liveWindowsSupported
                ? "Setup takes about a minute to try Sunlight, and about five more, with one restart, for live windows."
                : "Setup takes about a minute."
            var paragraphs = ["Your canvas and your shortcuts, ready the moment you log in.", estimate]
            // Said before it happens: Continue turns Stage Manager off, which moves every window on screen.
            if StageManager.isOn() {
                paragraphs.append("Stage Manager is on, and Sunlight needs it off: it hides windows into a strip whenever an app comes forward. Continue turns it off, and it comes back on when you quit Sunlight.")
            }
            return SetupPageSpec(page: page, eyebrow: "Open at login", headline: "Start with Sunlight.",
                                 paragraphs: paragraphs, extra: .loginItem,
                                 primary: action("primary", "Continue") { [weak self] in self?.chooseLoginItem() }, note: note)

        case .accessibility:
            return SetupPageSpec(page: page, eyebrow: "Accessibility", headline: "Let Sunlight move your windows.",
                                 paragraphs: ["Accessibility is how Sunlight moves, raises and focuses other apps’ windows. Turn Sunlight on in the list that opens. Not there? Drag Sunlight in from the card beside the window."],
                                 primary: action("primary", "Allow Accessibility…") { [weak self] in
                                     self?.stepAside()
                                     Permissions.requestAccessibility()
                                     self?.openPrivacyPane("Privacy_Accessibility", dragging: .accessibility)
                                 },
                                 watching: true)

        case .screenRecording:
            var secondary: [SetupPageSpec.Action] = []
            if askedForScreenRecording, !review {
                secondary.append(action("relaunch", "Relaunch Sunlight") { [weak self] in self?.relaunch(resumingAt: .screenRecording) })
            }
            secondary.append(action("skip", "Skip for now") { [weak self] in
                guard let self, !self.review else { return }
                SetupRecord.skippedScreenRecording = true
                journal("Screen Recording skipped")
                self.check()
            })
            return SetupPageSpec(page: page, eyebrow: "Screen Recording", headline: "Let Sunlight see your screen.",
                                 paragraphs: ["Screen Recording is how the canvas shows your windows as pictures in preview mode, and your desktop widgets. macOS applies it to a fresh launch, so Sunlight relaunches itself once the switch is on and comes straight back here."],
                                 primary: action("primary", "Allow Screen Recording…", enabled: !relaunching) { [weak self] in
                                     self?.askedForScreenRecording = true
                                     self?.stepAside()
                                     CGRequestScreenCaptureAccess()
                                     self?.openPrivacyPane("Privacy_ScreenCapture", dragging: .screenRecording)
                                 },
                                 secondary: secondary,
                                 note: relaunching ? "Relaunching…" : nil, watching: !relaunching)

        case .preview:
            var paragraphs: [String] = []
            var secondary: [SetupPageSpec.Action] = []
            if !status.screenRecording {
                paragraphs.append("Without Screen Recording the canvas shows window frames and titles only. Allow it any time from here.")
                secondary.append(action("recording", "Allow Screen Recording…") { [weak self] in
                    guard let self, !self.review else { return }
                    SetupRecord.skippedScreenRecording = false
                    self.check()
                })
            }
            if mac.liveWindowsSupported {
                paragraphs.append("Your windows are on the canvas as pictures, refreshed as they change. Live windows are the real thing: smooth, instant, and with no Screen Recording needed. Setting them up takes about five minutes and one restart into Recovery. Start now, or any time from Use Full Version in the bottom-left corner of the canvas.")
                secondary.append(action("live", "Set Up Live Windows") { [weak self] in
                    guard let self, !self.review else { return }
                    SetupRecord.startedLive = true
                    journal("Live windows setup started")
                    self.check()
                })
            } else {
                paragraphs.append("Your windows are on the canvas as pictures, refreshed as they change. Live windows need Apple silicon and macOS 15 or later, so this Mac stays in preview mode.")
            }
            return SetupPageSpec(page: page, eyebrow: "Preview", headline: mac.liveWindowsSupported ? "You’re set. This is the preview." : "You’re set.",
                                 paragraphs: paragraphs,
                                 primary: action("primary", "Open the Canvas") { [weak self] in self?.close() },
                                 secondary: secondary, showsIcon: true)

        case .basics:
            let skip = action("skip", replaying ? "Close" : "Skip Tutorial") { [weak self] in self?.finishBasics(skipped: true) }
            // First the question: the steps differ for a trackpad and a mouse.
            guard let input = model.tutorialInput else {
                var choices: [Tutorial.Input: SetupPageSpec.Action] = [:]
                for input in Tutorial.Input.allCases {
                    choices[input] = action(input.rawValue, input.title) { [weak self] in self?.choose(input) }
                }
                return SetupPageSpec(page: page, eyebrow: "The basics", headline: "Trackpad or mouse?",
                                     paragraphs: ["A quick look at getting around, with the one you use. Both work all the time."],
                                     extra: .tutorial, secondary: [skip], choices: choices)
            }
            let index = model.lesson
            let step = Tutorial.step(index, for: input)
            let last = Tutorial.isLast(index, for: input)
            var secondary = [action("back", "Back") { [weak self] in self?.lesson(-1) }]
            if !last { secondary.append(skip) }
            return SetupPageSpec(page: page, eyebrow: "The basics  ·  \(index + 1) of \(input.steps.count)", headline: step.title,
                                 paragraphs: [step.line], extra: .tutorial,
                                 primary: last
                                     ? action("primary", replaying ? "Done" : "Continue") { [weak self] in self?.finishBasics(skipped: false) }
                                     : action("primary", "Next") { [weak self] in self?.lesson(1) },
                                 secondary: secondary, note: last ? Tutorial.rest : nil)

        case .consent:
            var paragraphs = [
                "Live windows run inside the Dock. macOS only allows that with two parts of System Integrity Protection off: Filesystem Protections and Debugging Restrictions. NVRAM protection goes off too, so the boot argument the add-on needs can be set.",
                "What stays on: the sealed system volume, kernel extension restrictions, Gatekeeper and notarization, and the privacy permissions you just granted.",
                "What it costs: a Mac that’s less protected against software changing system apps. It’s undone any time with one command in Recovery; Settings › General › Uninstall Sunlight… walks the whole setup back.",
            ]
            if !mac.admin { paragraphs.append("This step needs an administrator account.") }
            return SetupPageSpec(page: page, eyebrow: "System Integrity Protection", headline: "Live windows need part of SIP off.",
                                 paragraphs: paragraphs, extra: .consent,
                                 primary: action("primary", "Continue") { [weak self] in
                                     guard let self, !self.review else { return }
                                     SetupRecord.consentedAt = Date()
                                     journal("SIP consent given")
                                     self.check()
                                 })

        case .recovery:
            return SetupPageSpec(page: page, eyebrow: "Recovery", headline: "Restart into Recovery.",
                                 paragraphs: ["This is the one step that happens with Sunlight closed. Read it from your phone: scan the code, or send the commands to yourself."],
                                 extra: .recovery,
                                 primary: review ? nil : action("primary", "Shut Down…") { [weak self] in self?.shutDown() },
                                 note: "When the Mac starts again, Sunlight opens by itself, checks this step, and loads live windows.")

        case .welcomeBack:
            if !status.sipAllowsLiveWindows {
                return SetupPageSpec(page: page, eyebrow: "After the restart", headline: "Welcome back.",
                                     paragraphs: ["It looks like the Recovery step didn’t take: System Integrity Protection is still fully on. The steps are here again if you’d like another go."],
                                     secondary: [action("recovery", "Show the Recovery Steps") { [weak self] in
                                         self?.manual = .recovery
                                         if let status = self?.status { self?.apply(status) }
                                     }, diagnose])
            }
            if !status.bootArgument {
                var paragraphs = ["System Integrity Protection is partly off. The boot argument still needs setting; Sunlight does that from here, and it applies after one more restart."]
                if !mac.admin, status.helper != .daemonEnabled { paragraphs.append("This needs an administrator’s password.") }
                return SetupPageSpec(page: page, eyebrow: "After the restart", headline: "Welcome back.", paragraphs: paragraphs,
                                     primary: action("primary", "Set It and Restart", enabled: !busy.contains(.welcomeBack)) { [weak self] in self?.setBootArgumentAndRestart() },
                                     secondary: [diagnose], busy: busy.contains(.welcomeBack))
            }
            return SetupPageSpec(page: page, eyebrow: "After the restart", headline: "Welcome back.",
                                 paragraphs: ["System Integrity Protection is partly off and the boot argument is set. Checking the rest…"],
                                 secondary: [diagnose], watching: true)

        case .helper:
            let body: String
            switch status.helper {
            case .daemonNeedsApproval:
                body = "Sunlight is listed in System Settings › General › Login Items, under Allow in the Background. Turn it on there, and this page moves on by itself."
            case .missing:
                body = "This copy of Sunlight has no live-windows helper, so it can’t load live windows. Build it with make app, or use a release build."
            default:
                body = "The helper loads live windows into the Dock once the Mac is back from the restart, and reloads them whenever the Dock restarts, without ever asking for your password. Turning it on now is one switch in System Settings › General › Login Items, under Allow in the Background; after that, nothing on the way back needs a click."
            }
            var paragraphs = [body]
            if status.helper != .daemonNeedsApproval, status.helper != .missing, !mac.admin { paragraphs.append("The switch needs an administrator.") }
            return SetupPageSpec(page: page, eyebrow: "Background helper", headline: "Turn on the background helper.", paragraphs: paragraphs,
                                 primary: status.helper == .missing ? nil
                                     : action("primary", "Turn On…", enabled: !busy.contains(.helper)) { [weak self] in self?.turnOnHelper() },
                                 watching: status.helper != .missing, busy: busy.contains(.helper))

        case .load:
            // With the daemon on the page loads by itself and has nothing to click (in review, where
            // nothing loads, it shows itself mid-load); the button comes up only once that try has failed
            // or stalled. A build that would put up the administrator prompt has the button from the start.
            let byItself = SetupFlow.loadsByItself(status)
            let started = loadingSince != nil || review && byItself
            let loading = started && !loadingStalled
            let automatic = byItself && !loadingStalled && (loadingSince != nil || review || !loadedByItself)
            var paragraphs = [automatic
                ? "Sunlight is putting its add-on into the Dock and restarting the Dock once. Your Dock will blink, and the canvas switches to live windows as soon as the add-on answers. Nothing to click."
                : "Sunlight installs its add-on into the Dock and restarts the Dock once. Your Dock will blink, and the canvas switches to live windows as soon as the add-on answers."]
            if status.helper == .asksForPassword { paragraphs.append("This build asks for your administrator password the first time.") }
            var note: String?
            if started {
                note = loadingStalled
                    ? "Still not answering. Try Again loads once more; Reload Live Windows… in the menu bar icon's More does the same, with a password prompt if need be."
                    : "Loading… the Dock restarts once."
            }
            let title = loading ? "Loading…" : loadedByItself || loadingStalled ? "Try Again" : "Load Live Windows"
            return SetupPageSpec(page: page, eyebrow: "Live windows", headline: automatic ? "Loading live windows." : "Load live windows.",
                                 paragraphs: paragraphs,
                                 primary: automatic ? nil : action("primary", title, enabled: !loading) { [weak self] in
                                     self?.journal("Load live windows requested")
                                     self?.startLoad()
                                 },
                                 secondary: [diagnose], note: note, busy: loading)

        case .tour:
            let intro = "The canvas is a window manager you look at: everything on your Mac, live, at any zoom. Press the Mission Control key to come back to it from any window."
            // Taken over already: the canvas is all that's left.
            if isTakenOver?() == true {
                return SetupPageSpec(page: page, eyebrow: "Live windows are on", headline: "Here’s how it works.",
                                     paragraphs: [intro], extra: .tour,
                                     primary: action("primary", "Open the Canvas") { [weak self] in self?.close() })
            }
            // Otherwise taking over is the way on, and the only one: its own consent follows, on the canvas,
            // once the window is away.
            return SetupPageSpec(page: page, eyebrow: "Live windows are on", headline: "Here’s how it works.",
                                 paragraphs: [intro, "Last step: take over, and Sunlight becomes your Mac’s home. ⌘Tab, Mission Control and Show Desktop land on the canvas, and the Dock tucks away. Everything goes back when Sunlight quits."],
                                 extra: .tour,
                                 primary: action("primary", "Take Over…") { [weak self] in
                                     guard let self else { return }
                                     let takeOver = self.onTakeOver
                                     self.journal("Tour: take over")
                                     self.close()
                                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { takeOver?() }
                                 })
        }
    }

    private func notice(_ title: String, _ detail: String, isError: Bool = true) {
        model.notice = SetupWizardModel.Notice(title: title, detail: detail.trimmingCharacters(in: .whitespacesAndNewlines), isError: isError)
    }

    // MARK: Actions

    /// Switches the canvas to live windows and loads the add-on; the page watches for the answer.
    private func startLoad() {
        guard !review else { return }
        loadingSince = Date()
        model.notice = nil
        onLoadLiveWindows?()
        check()
    }

    /// Review mode has nothing to record: Get Started and Continue just turn the page.
    private func getStarted() {
        guard !review else { return step(1) }
        SetupRecord.welcomed = true
        SetupRecord.loginItemChosen = false
        journal("Welcome: get started")
        check()
    }

    /// Trackpad or mouse: the tutorial's first step for it.
    private func choose(_ input: Tutorial.Input) {
        journal("Tutorial: \(input.rawValue)")
        model.tutorialInput = input
        model.lesson = 0
        if let status { refresh(status) }
    }

    /// The tutorial's step before or after; back from the first, the question again.
    private func lesson(_ by: Int) {
        guard let input = model.tutorialInput else { return }
        if model.lesson + by < 0 {
            model.tutorialInput = nil
        } else {
            let next = min(model.lesson + by, input.steps.count - 1)
            guard next != model.lesson else { return }
            model.lesson = next
        }
        if let status { refresh(status) }
    }

    /// Continue on the last step, or Skip Tutorial: on to "You're set". A replay just closes.
    private func finishBasics(skipped: Bool) {
        journal(skipped ? "Tutorial skipped at step \(model.lesson + 1)" : "Tutorial finished")
        if replaying { return close() }
        guard !review else { return step(1) }
        SetupRecord.learnedBasics = true
        check()
    }

    private func chooseLoginItem() {
        guard !review else { return step(1) }
        SetupRecord.loginItemChosen = true
        journal("Open at login: \(model.loginItem ? "on" : "off")")
        StageManager.turnOff(why: "setup")
        if model.loginItem {
            DispatchQueue.global(qos: .utility).async { LoginItem.register() }
        }
        check()
    }

    /// The Privacy list for a step, with Sunlight’s icon standing beside System Settings to drag
    /// into it when macOS didn't put Sunlight there by itself (`PermissionDragPanel`).
    private func openPrivacyPane(_ anchor: String, dragging permission: PermissionDragPanel.Permission) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
        guard !review, !isTour else { return }
        PermissionDragPanel.shared.show(for: permission)
    }

    /// Opens a new copy once this one has quit (Screen Recording applies to a fresh launch), with the
    /// resume page noted so the new copy comes back here.
    private func relaunch(resumingAt page: SetupFlow.Page) {
        guard !relaunching, !review else { return }
        relaunching = true
        SetupRecord.setResume(page)
        if let status { refresh(status) }
        guard AppRelaunch.open(Bundle.main.bundleURL, afterQuitOf: ProcessInfo.processInfo.processIdentifier) else {
            Log.note("Setup: couldn't relaunch")
            relaunching = false
            return
        }
        NSApp.terminate(nil)
    }

    private func shutDown() {
        guard !review else { return }
        SetupRecord.setResume(.recovery)
        if let message = RecoveryCard.shutDown() {
            notice("Sunlight couldn’t shut the Mac down.", "Choose Apple menu › Shut Down instead. (\(message))")
        }
    }

    private func setBootArgumentAndRestart() {
        guard !review else { return }
        runInBackground(.welcomeBack) {
            LiveWindowsService.runPrivileged("bootarg", prompt: "Sunlight wants to set the boot argument live windows need.")
        } done: { [weak self] result in
            guard let self else { return }
            journal("Boot argument: \(result.status == 0 ? "set" : "failed: \(result.output)")")
            if result.output.contains("(-128)") { return }   // the administrator prompt was cancelled
            guard result.status == 0 else {
                self.notice("The boot argument couldn’t be set.", result.output)
                return
            }
            SetupRecord.setResume(.recovery)
            if let message = RecoveryCard.restart() {
                self.notice("The boot argument is set.", "Restart the Mac to apply it: choose Apple menu › Restart. Sunlight finishes setting up after that. (\(message))", isError: false)
            }
        }
    }

    private func turnOnHelper() {
        guard !review else { return }
        runInBackground(.helper) {
            let state = LiveWindowsService.register()
            return (state == .enabled || state == .needsApproval ? 0 : 1, "\(state)")
        } done: { [weak self] result in
            self?.journal("Helper: \(result.output)")
            // Waiting on its switch: System Settings › Login Items is opening, out of the way for it.
            if result.output == "\(LiveWindowsService.State.needsApproval)" { self?.stepAside() }
            if result.status != 0 { self?.notice("The background helper couldn’t be registered.", result.output) }
        }
    }

    private func runInBackground(_ page: SetupFlow.Page, _ work: @escaping @Sendable () -> (status: Int32, output: String),
                                 done: @escaping (_ result: (status: Int32, output: String)) -> Void) {
        guard !busy.contains(page) else { return }
        busy.insert(page)
        model.notice = nil
        if let status { refresh(status) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.busy.remove(page)
                    done(result)
                    self?.check()
                }
            }
        }
    }

    // MARK: Keys

    private func handle(_ key: SetupWizardWindow.Key) -> Bool {
        switch key {
        case .return:
            // Not before Get Started has started to appear.
            guard model.reveal >= .start, let primary = model.spec.primary, primary.enabled, !model.spec.busy,
                  model.spec.extra != .consent || model.consent else { return true }
            primary.run()
        case .escape:
            close()
        case .left:
            if page == .basics, model.tutorialInput != nil { lesson(-1); return true }
            guard review else { return false }
            step(-1)
        case .right:
            if page == .basics, let input = model.tutorialInput, !Tutorial.isLast(model.lesson, for: input) { lesson(1); return true }
            guard review else { return false }
            step(1)
        case .copy:
            guard page == .recovery else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SetupStatus.recoveryCommands + "\n", forType: .string)
            model.copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.model.copied = false }
        }
        return true
    }

    // MARK: Stepping aside

    /// Floating over the canvas while Sunlight is active; at the normal level otherwise, so any other
    /// app's window, System Settings and the system's prompts among them, is over it.
    private func float(_ on: Bool) {
        guard let window, !isTour else { return }
        let level: NSWindow.Level = on ? .floating : .normal
        if window.level != level { window.level = level }
    }

    /// A button that sends the person to System Settings, or puts up a system prompt: out of the way at
    /// once, not only when another app takes the front, since a prompt can come up without taking it and
    /// System Settings takes a moment to open. Back when the step is done (`comeBack`), or when Sunlight
    /// is brought to the front again (`returned`).
    private func stepAside() {
        guard let window, isShowing, !review, !isTour else { return }
        hideWork?.cancel()
        hideWork = nil
        steppedAside = true
        journal("Stepping aside for System Settings")
        float(false)
        music.fadeOut()
        fadeOut(duration: 0.25) {
            guard self.steppedAside else { return }
            window.orderOut(nil)
            self.backdrop.isPaused = true
        }
    }

    /// Another app came in front (System Settings, for a step): the window drops to the normal level
    /// at once, under that app, then fades away, and comes back when Sunlight does. The short wait
    /// skips the moment a permission prompt takes the front.
    private func hideSoon() {
        float(false)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isShowing, !NSApp.isActive, let window = self.window else { return }
                self.steppedAside = true
                self.music.fadeOut()
                self.fadeOut(duration: 0.3) {
                    guard !NSApp.isActive else { return }
                    window.orderOut(nil)
                    self.backdrop.isPaused = true
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Back from stepping aside, the window faded in again: Sunlight came back to the front.
    private func returned() {
        PermissionDragPanel.shared.hide()
        hideWork?.cancel()
        hideWork = nil
        steppedAside = false
        guard isShowing, let window else { return }
        float(true)
        backdrop.isPaused = false
        if !window.isVisible || window.alphaValue < 1 {
            backdrop.drawNow()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
            fadeIn(duration: 0.45)
        } else if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
        }
        check()
    }

    /// Back from stepping aside by itself, a step having finished: the window in again, then the app.
    private func comeBack() {
        PermissionDragPanel.shared.hide()
        guard let window else { return }
        steppedAside = false
        backdrop.isPaused = false
        backdrop.drawNow()
        comeForward()
        if window.alphaValue < 1 { fadeIn(duration: 0.45) }
    }

    private func fadeIn(duration: TimeInterval) {
        guard let window else { return }
        fade += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func fadeOut(duration: TimeInterval, then: @escaping @MainActor () -> Void) {
        guard let window else { return }
        fade += 1
        let token = fade
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard self.fade == token else { return }
                then()
            }
        })
    }

    // MARK: Watching the app

    private func observe() {
        guard observers.isEmpty, let window else { return }
        let center = NotificationCenter.default
        if !isTour {
            observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideSoon() }
            })
            observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.returned() }
            })
            // The canvas took key (a Dock click, the Mission Control key): the wizard is what the user sees, so keys stay here.
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, self.isShowing, let other = note.object as? NSWindow, other !== window,
                          other.isVisible, !(other is NSPanel), other.sheetParent == nil, other.attachedSheet == nil,
                          NSApp.isActive, window.isVisible, window.attachedSheet == nil else { return }
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(nil)
                }
            })
            observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isShowing else { return }
                    self.backdrop.isPaused = !window.occlusionState.contains(.visible)
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitScreen() }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.backdrop.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.backdrop.setReduceMotion(BackgroundSources.reduceMotion)
                self?.backdrop.setHighContrast(BackgroundSources.increaseContrast)
            }
        })
    }

    private func unobserve() {
        hideWork?.cancel()
        hideWork = nil
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers = []
    }

    private func fitScreen() {
        guard let window else { return }
        window.setFrame(screen.frame, display: true)
        hosting.rootView = SetupWizardView(model: model, metrics: SetupMetrics.fit(screen: screen), onLater: { [weak self] in self?.close() })
    }
}

/// Borderless and full-screen, so it takes key itself and covers the menu bar's strip; the keys the
/// wizard answers go to the controller, the rest are swallowed rather than beeped.
final class SetupWizardWindow: NSWindow {
    enum Key { case `return`, escape, left, right, copy }

    var onKey: ((Key) -> Bool)?
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func keyDown(with event: NSEvent) {
        let key: Key?
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: key = .return
        case kVK_Escape: key = .escape
        case kVK_LeftArrow: key = .left
        case kVK_RightArrow: key = .right
        default: key = nil
        }
        if let key, onKey?(key) == true { return }
        if Int(event.keyCode) == kVK_Tab { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "c": if onKey?(.copy) == true { return true }
            case "w":
                onClose?()
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
