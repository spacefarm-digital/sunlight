import AppKit

/// Uninstall Sunlight…: the install walked backwards, one step at a time, each ticking as the Mac
/// confirms it's undone. The add-on out of the Dock, the boot argument and the password rule earlier
/// builds wrote, the background helper and the login item, System Integrity Protection back on (the one
/// step in Recovery, with setup's card turned around), then Sunlight itself to the Trash. This is the
/// pure part: what's still installed, which step is next, the Terminal lines. `UninstallController`
/// draws it and runs the buttons.
enum UninstallFlow {
    enum Step: String, CaseIterable, Sendable {
        case addOn, bootArgument, helper, protection, trash

        var title: String {
            switch self {
            case .addOn: return "Live windows out of the Dock"
            case .bootArgument: return "Boot argument and password rule"
            case .helper: return "Background helper and login item"
            case .protection: return "System Integrity Protection back on"
            case .trash: return "Sunlight to the Trash"
            }
        }
    }

    static let bootArgument = "-arm64e_preview_abi"
    static let addOnPath = "/Library/ScriptingAdditions/Sunlight.osax"

    /// What's still in place, read from the Mac.
    struct Status: Equatable, Sendable {
        /// Sunlight.osax in /Library/ScriptingAdditions, or the add-on answering in the Dock.
        var addOnPresent: Bool
        /// The boot arguments as stored in NVRAM (not this boot's), for the line that removes only Sunlight's.
        var bootArguments: [String]
        /// The launch daemon is registered: on, or waiting for approval in Login Items.
        var helperRegistered: Bool
        /// Sunlight opens at login.
        var loginItem: Bool
        /// Takeover mode's changes to the Dock, Finder and Mission Control are in place.
        var takeoverApplied: Bool
        /// Filesystem Protections and Debugging Restrictions off.
        var sipPartlyOff: Bool

        var bootArgumentStored: Bool { bootArguments.contains(UninstallFlow.bootArgument) }

        /// Nothing of the install left but the app itself.
        static let clean = Status(addOnPresent: false, bootArguments: [], helperRegistered: false, loginItem: false,
                                  takeoverApplied: false, sipPartlyOff: false)
    }

    static func isDone(_ step: Step, status: Status) -> Bool {
        switch step {
        case .addOn: return !status.addOnPresent
        case .bootArgument: return !status.bootArgumentStored
        case .helper: return !status.helperRegistered && !status.loginItem && !status.takeoverApplied
        case .protection: return !status.sipPartlyOff
        case .trash: return false
        }
    }

    /// The step to do now: the first that isn't done or skipped. The Trash comes last whatever was skipped.
    static func current(for status: Status, skipped: Set<Step>) -> Step {
        Step.allCases.first { !isDone($0, status: status) && !skipped.contains($0) } ?? .trash
    }

    struct Entry: Equatable, Sendable {
        enum State: Equatable, Sendable { case done, current, skipped, todo }
        var step: Step
        var state: State
    }

    static func entries(for status: Status, skipped: Set<Step>) -> [Entry] {
        let now = current(for: status, skipped: skipped)
        return Step.allCases.map { step in
            let state: Entry.State = step == now ? .current
                : isDone(step, status: status) ? .done
                : skipped.contains(step) ? .skipped
                : .todo
            return Entry(step: step, state: state)
        }
    }

    // MARK: The boot argument

    /// The stored boot arguments from `nvram boot-args`, which prints "boot-args<tab>value" and fails
    /// when the variable isn't set.
    static func bootArguments(fromNvram output: String, status: Int32) -> [String] {
        guard status == 0, let tab = output.firstIndex(of: "\t") else { return [] }
        return output[output.index(after: tab)...].split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    /// The Terminal lines that take Sunlight's boot argument out of NVRAM, keeping any others, and remove
    /// the password rule a build without the background helper wrote (harmless when there's none).
    static func terminalCommands(bootArguments: [String]) -> String {
        let others = bootArguments.filter { $0 != bootArgument }
        let nvram = others.isEmpty
            ? "sudo nvram -d boot-args"
            : "sudo nvram boot-args=" + AdditionReloader.shellQuoted(others.joined(separator: " "))
        return nvram + "\nsudo rm -f " + AdditionReloader.sudoersPath
    }

    // MARK: Reading the Mac

    /// Several round trips (launchd, the add-on's socket, nvram): off the main thread.
    nonisolated static func readStatus() -> Status {
        let nvram = AdditionReloader.run("/usr/sbin/nvram", ["boot-args"])
        let daemon = LiveWindowsService.state
        let login = LoginItem.status
        return Status(addOnPresent: FileManager.default.fileExists(atPath: addOnPath) || LiveWindowsConnection.probe(),
                      bootArguments: bootArguments(fromNvram: nvram.output, status: nvram.status),
                      helperRegistered: daemon == .enabled || daemon == .needsApproval,
                      loginItem: login == .enabled || login == .requiresApproval,
                      takeoverApplied: UserDefaults.standard.bool(forKey: TakeoverMode.Keys.applied),
                      sipPartlyOff: SetupStatus.sipAllowsLiveWindows())
    }

    /// Settings, layouts, background pictures and caches: what the Homebrew cask's `zap` removes.
    nonisolated static func removeUserData() {
        let fm = FileManager.default
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            UserDefaults.standard.synchronize()
            if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
                try? fm.removeItem(at: caches.appendingPathComponent(id))
            }
            if let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
                try? fm.removeItem(at: library.appendingPathComponent("HTTPStorages/\(id)"))
            }
        }
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: support.appendingPathComponent("Sunlight"))
        }
    }
}

/// Whether an uninstall was under way when the Mac restarted for the Recovery step, so the window comes
/// back by itself at the next launch to finish.
@MainActor
enum UninstallRecord {
    private static let resumingKey = "UninstallInProgress"

    static var resuming: Bool {
        get { UserDefaults.standard.bool(forKey: resumingKey) }
        set { UserDefaults.standard.set(newValue, forKey: resumingKey) }
    }
}

/// The Uninstall Sunlight window: the steps in a list, the current one open with its explanation and
/// buttons, the Mac checked once a second so a step ticks the moment it's undone, Terminal included.
@MainActor
final class UninstallController: NSWindowController, NSWindowDelegate {
    /// Before the add-on goes: the canvas leaves live windows, so nothing loads the add-on back.
    var onLeaveLiveWindows: (() -> Void)?
    /// The Dock, Finder and Mission Control back as they were before takeover mode.
    var onReleaseTakeover: (() -> Void)?
    /// The last step: Sunlight to the Trash (its data too, when asked), then quit.
    var onTrash: ((_ removingData: Bool) -> Void)?

    static let width: CGFloat = 600

    private let statusProvider: @Sendable () -> UninstallFlow.Status
    private(set) var status: UninstallFlow.Status?
    private var skipped: Set<UninstallFlow.Step> = []
    private var busy: Set<UninstallFlow.Step> = []
    private var timer: Timer?
    private var checking = false
    private var appliedKey = ""
    private var actions: [String: () -> Void] = [:]
    private let removeData = NSSwitch()

    init(statusProvider: @escaping @Sendable () -> UninstallFlow.Status = { UninstallFlow.readStatus() }) {
        self.statusProvider = statusProvider
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Uninstall Sunlight"
        // Over the canvas while Sunlight is active; at the normal level while another app is, since the
        // walk-back sends the person to Terminal and System Settings, and a floating window of an
        // inactive app would stay over them. Not hidden: its commands are what they're typing there.
        window.level = .normal
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated { window?.level = .floating }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak window] _ in
            MainActor.assumeIsolated { window?.level = .normal }
        }
        showChecking()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Before the first look at the Mac has come back.
    private func showChecking() {
        let title = NSTextField(labelWithString: "Uninstall Sunlight")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let stack = NSStackView(views: [title, Self.text("Checking what's installed…", secondary: true)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 22, right: 28)
        stack.frame = NSRect(x: 0, y: 0, width: Self.width, height: stack.fittingSize.height)
        window?.contentView = stack
        window?.setContentSize(stack.frame.size)
    }

    override func showWindow(_ sender: Any?) {
        if NSApp.isActive { window?.level = .floating }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate()
        check()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
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
                }
            }
        }
    }

    private func apply(_ status: UninstallFlow.Status) {
        self.status = status
        let entries = UninstallFlow.entries(for: status, skipped: skipped)
        let key = "\(entries) \(status.bootArguments) \(busy.map(\.rawValue).sorted()) \(status.takeoverApplied)"
        guard key != appliedKey else { return }
        appliedKey = key
        rebuild(entries, status: status)
    }

    // MARK: Layout

    private func rebuild(_ entries: [UninstallFlow.Entry], status: UninstallFlow.Status) {
        guard let window else { return }
        actions.removeAll()
        let title = NSTextField(labelWithString: "Uninstall Sunlight")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let body = Self.text("Everything setup changed, put back in order. Each step ticks as the Mac confirms it. Keep Sunlight stops here and leaves the rest as it is.", secondary: true)

        var views: [NSView] = [title, body]
        for entry in entries {
            views.append(row(for: entry))
            if entry.state == .current { views.append(detail(for: entry.step, status: status)) }
        }
        let keep = NSButton(title: "Keep Sunlight", target: self, action: #selector(keepSunlight))
        views.append(keep)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(18, after: body)
        if views.count >= 2 { stack.setCustomSpacing(20, after: views[views.count - 2]) }
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -56).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        let height = stack.fittingSize.height
        window.contentView = content
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func row(for entry: UninstallFlow.Entry) -> NSView {
        let (symbol, color, weight, textColor): (String, NSColor, NSFont.Weight, NSColor) = switch entry.state {
        case .done: ("checkmark.circle.fill", .labelColor, .regular, .labelColor)
        case .current: ("circle.fill", .controlAccentColor, .semibold, .labelColor)
        case .skipped: ("minus.circle", .tertiaryLabelColor, .regular, .secondaryLabelColor)
        case .todo: ("circle", .tertiaryLabelColor, .regular, .secondaryLabelColor)
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = color
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let label = NSTextField(labelWithString: entry.step.title + (entry.state == .skipped ? "  ·  left as it is" : ""))
        label.font = .systemFont(ofSize: 14, weight: weight)
        label.textColor = textColor
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// The open step: what it does, and its buttons. Indented under its row.
    private func detail(for step: UninstallFlow.Step, status: UninstallFlow.Status) -> NSView {
        var views: [NSView] = []
        var buttons: [NSButton] = []
        /// Under the buttons.
        var note: String?
        let inBundle = Bundle.main.bundleURL.pathExtension == "app"
        switch step {
        case .addOn:
            views.append(Self.text("Removes Sunlight's add-on from /Library/ScriptingAdditions and restarts the Dock once, which drops it: your Dock blinks. This asks for your administrator password."))
            buttons.append(button("Remove from the Dock…", id: "remove", enabled: !busy.contains(.addOn)) { [weak self] in self?.removeAddOn() })

        case .bootArgument:
            views.append(Self.text("Two lines in Terminal, as an administrator: the first takes Sunlight's boot argument out of NVRAM and keeps any others; the second removes the password rule a build without the background helper may have written (harmless when there's none)."))
            let commands = NSTextField(labelWithString: UninstallFlow.terminalCommands(bootArguments: status.bootArguments))
            commands.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            commands.isSelectable = true
            commands.maximumNumberOfLines = 2
            views.append(commands)
            buttons.append(button("Copy", id: "copy") { [weak self] in self?.copyCommands() })
            buttons.append(button("Open Terminal", id: "terminal") {
                _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
            })
            buttons.append(button("Skip for Now", id: "skip") { [weak self] in self?.skip(.bootArgument) })
            note = "This step ticks by itself once the boot argument is gone. If nvram says it isn't permitted, run the first line in Recovery's Terminal instead, where the next step takes you."

        case .helper:
            var text = "Turns Sunlight off in System Settings › General › Login Items: the background helper that loaded live windows, and opening at login."
            if status.takeoverApplied { text += " Puts the Dock, Finder and Mission Control back as they were before Sunlight took over the Mac." }
            if UserDefaults.standard.bool(forKey: TakeoverMode.Keys.merged) {
                text += " Desktops Sunlight merged into the canvas are not recreated: add them again in Mission Control if you want them."
            }
            views.append(Self.text(text))
            buttons.append(button("Turn Off", id: "turnoff", enabled: !busy.contains(.helper)) { [weak self] in self?.turnOffHelper() })

        case .protection:
            views.append(Self.text("Live windows needed part of System Integrity Protection off. Turning it fully back on takes one more restart into Recovery and one command there. Leave it off if something else on this Mac needs it."))
            views.append(RecoveryCard(.protectionBackOn))
            buttons.append(button("Shut Down…", id: "shutdown") { [weak self] in self?.shutDown() })
            buttons.append(button("Leave It Off", id: "leave") { [weak self] in self?.skip(.protection) })
            note = "When the Mac starts again, Sunlight opens by itself to finish this."

        case .trash:
            views.append(Self.text(inBundle
                ? "Moves Sunlight to the Trash and quits. System Settings › Privacy & Security keeps Sunlight listed under Accessibility and Screen Recording until you remove it there."
                : "This copy of Sunlight isn't in an app bundle, so there's nothing to move to the Trash: delete the build yourself. Quit finishes here."))
            views.append(NSSwitch.row("Also remove my settings, layouts and background pictures", removeData))
            buttons.append(button(inBundle ? "Move to Trash and Quit" : "Quit", id: "trash") { [weak self] in
                guard let self else { return }
                self.onTrash?(self.removeData.state == .on)
            })
        }
        if let first = buttons.first { first.keyEquivalent = "\r" }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 10
        if busy.contains(step) {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            row.addArrangedSubview(spinner)
        }
        views.append(row)
        if let note { views.append(Self.text(note, small: true)) }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 26, bottom: 6, right: 0)
        for view in views {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -26).isActive = true
        }
        return stack
    }

    private func button(_ title: String, id: String, enabled: Bool = true, _ action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(run(_:)))
        button.bezelStyle = .push
        button.isEnabled = enabled
        button.identifier = NSUserInterfaceItemIdentifier(id)
        actions[id] = action
        return button
    }

    private static func text(_ string: String, secondary: Bool = false, small: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = .systemFont(ofSize: small ? NSFont.smallSystemFontSize : NSFont.systemFontSize)
        label.textColor = secondary || small ? .secondaryLabelColor : .labelColor
        label.preferredMaxLayoutWidth = width - 56 - 26
        return label
    }

    @objc private func run(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let action = actions[id] else { return }
        action()
    }

    // MARK: Actions

    private func removeAddOn() {
        onLeaveLiveWindows?()
        SetupJournal.note("Uninstall: removing the add-on from the Dock")
        runInBackground(.addOn) {
            LiveWindowsService.runWithAdministratorPrompt("unload", prompt: "Sunlight wants to remove its add-on from the Dock.")
        } done: { [weak self] result in
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            SetupJournal.note("Uninstall: add-on \(result.status == 0 ? "removed" : "not removed: \(output)")")
            if output.contains("(-128)") { return }   // the administrator prompt was cancelled
            guard result.status == 0 else {
                self?.alert("The add-on couldn't be removed",
                            "\(output)\n\nIn Terminal: sudo rm -rf \(UninstallFlow.addOnPath); killall Dock")
                return
            }
        }
    }

    private func copyCommands() {
        guard let status else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(UninstallFlow.terminalCommands(bootArguments: status.bootArguments) + "\n", forType: .string)
    }

    private func skip(_ step: UninstallFlow.Step) {
        skipped.insert(step)
        SetupJournal.note("Uninstall: \(step.rawValue) left as it is")
        if let status { apply(status) }
    }

    private func turnOffHelper() {
        runInBackground(.helper) {
            LiveWindowsService.unregister()
            LoginItem.unregister()
            return (0, "")
        } done: { [weak self] _ in
            self?.onReleaseTakeover?()
            SetupJournal.note("Uninstall: helper and login item off")
        }
    }

    private func shutDown() {
        UninstallRecord.resuming = true
        SetupJournal.note("Uninstall: leaving for Recovery to turn System Integrity Protection back on")
        if let message = RecoveryCard.shutDown() {
            alert("Sunlight couldn't shut the Mac down", "Choose Apple menu › Shut Down instead. (\(message))")
        }
    }

    @objc private func keepSunlight() {
        UninstallRecord.resuming = false
        SetupJournal.note("Uninstall: stopped, keeping Sunlight")
        close()
    }

    private func runInBackground(_ step: UninstallFlow.Step, _ work: @escaping @Sendable () -> (status: Int32, output: String),
                                 done: @escaping (_ result: (status: Int32, output: String)) -> Void) {
        guard !busy.contains(step) else { return }
        busy.insert(step)
        if let status { apply(status) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.busy.remove(step)
                    done(result)
                    self?.check()
                }
            }
        }
    }

    private func alert(_ message: String, _ detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
