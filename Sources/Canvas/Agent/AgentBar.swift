import AppKit
import SwiftUI

/// Tell Sunlight (⌃⌥Space, Settings › Experimental): a Spotlight-style bar to type a request
/// into. ⏎ sends it to Claude (`AgentRun`); the steps show under the field as they're taken, then the
/// answer. Esc stops a request in flight, or closes the bar. The bar stays up while a request runs, over
/// the canvas or a window, and never takes the user's place: it doesn't activate Sunlight.
@MainActor
final class AgentBar: NSPanel, NSTextFieldDelegate {
    /// Opens Settings › General, where the key goes.
    var onOpenSettings: (() -> Void)?

    private static let width: CGFloat = 620
    private static let fieldHeight: CGFloat = 64

    private let desk: Desk
    private var tools: CanvasTools
    /// The step waiting on the user's Allow, while one is.
    private var pendingConfirmation: CheckedContinuation<Bool, Never>?
    private let field = NSTextField()
    private let model = AgentBarModel()
    private var log: NSHostingView<AgentBarLog>!
    private var run: AgentRun?
    private var hideTimer: Timer?

    override var canBecomeKey: Bool { true }

    init(desk: Desk, onLayoutsChanged: (() -> Void)?) {
        self.desk = desk
        tools = CanvasTools(desk: desk, onLayoutsChanged: onLayoutsChanged)
        let size = NSSize(width: AgentBar.width, height: AgentBar.fieldHeight)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Over the live canvas, as Open Here's bar: the Dock add-on lifts the canvas above AppKit's levels.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
        contentView = buildContent(size: size)
        model.onOpenSettings = { [weak self] in
            self?.dismiss()
            self?.onOpenSettings?()
        }
        model.onStop = { [weak self] in
            self?.answerConfirmation(false)
            self?.run?.stop()
        }
        model.onAnswer = { [weak self] allowed in self?.answerConfirmation(allowed) }
    }

    // MARK: Showing

    /// Up in the middle of the screen with the pointer, the field ready. A request still running stays as it is.
    func show() {
        hideTimer?.invalidate()
        if run?.isWorking != true {
            model.reset(hasKey: AgentKey.isSet)
            field.stringValue = ""
        }
        layoutForContent()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let s = screen?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: s.midX - frame.width / 2, y: s.maxY - s.height * 0.18))
        }
        orderFrontRegardless()
        makeKey()
        makeFirstResponder(field)
    }

    func toggle() {
        if isVisible && isKeyWindow && run?.isWorking != true { dismiss() } else { show() }
    }

    /// Hidden: a question still open is answered "Don't", since nothing would be left to answer it.
    func dismiss() {
        answerConfirmation(false)
        hideTimer?.invalidate()
        orderOut(nil)
    }

    /// Tell Sunlight turned off: the request in flight stops too.
    func shutDown() {
        answerConfirmation(false)
        run?.stop()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) { escape() }

    private func escape() {
        if pendingConfirmation != nil {
            answerConfirmation(false)   // esc on a question is "Don't", not "stop everything"
        } else if let run, run.isWorking {
            run.stop()
        } else {
            dismiss()
        }
    }

    // MARK: Asking first

    /// A step that sends, deletes, pays or publishes: the bar asks, comes forward, and the run waits.
    private func ask(_ question: String) async -> Bool {
        answerConfirmation(false)
        hideTimer?.invalidate()
        model.confirmation = question
        layoutForContent()
        orderFrontRegardless()
        NSSound(named: "Tink")?.play()
        return await withCheckedContinuation { pendingConfirmation = $0 }
    }

    private func answerConfirmation(_ allowed: Bool) {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        model.confirmation = nil
        layoutForContent()
        NSLog("Tell Sunlight: a step was \(allowed ? "allowed" : "declined")")
        pending.resume(returning: allowed)
    }

    // MARK: Running

    private func send() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, run?.isWorking != true else { return }
        guard let key = AgentKey.stored else {
            model.reset(hasKey: false)
            layoutForContent()
            return
        }
        model.begin(request: text)
        let apps = AppTools(desk: desk)
        apps.confirm = { [weak self] question in await self?.ask(question) ?? false }
        apps.onWindow = { [weak self] line in
            self?.model.steps.append(line)
            self?.layoutForContent()
        }
        let run = AgentRun(request: text, key: key, tools: tools, apps: apps)
        run.onStep = { [weak self] step in
            self?.model.steps.append(step)
            self?.layoutForContent()
        }
        run.onState = { [weak self] state in
            guard let self else { return }
            self.model.state = state
            self.layoutForContent()
            if case .working = state { return }
            // Finished behind a window it went into: the bar steps aside after a moment.
            if !self.isKeyWindow { self.dismissSoon() }
        }
        self.run = run
        layoutForContent()
        run.start()
    }

    private func dismissSoon() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.run?.isWorking != true, !self.isKeyWindow else { return }
                self.dismiss()
            }
        }
    }

    override func resignKey() {
        super.resignKey()
        // Clicked away from with nothing running: gone, as Spotlight; with an answer showing, after a
        // moment to read it. A running request keeps it up.
        guard run?.isWorking != true else { return }
        if model.state == nil { dismiss() } else { dismissSoon() }
    }

    // MARK: Text field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): send()
        case #selector(NSResponder.cancelOperation(_:)): escape()
        default: return false
        }
        return true
    }

    // MARK: Building

    /// The bar grows down to fit the steps and the answer, its top staying put. On the next turn of the
    /// run loop: SwiftUI takes the model's change in before it can be measured.
    private func layoutForContent() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.fitContent() }
        }
    }

    private func fitContent() {
        let logHeight = model.isEmpty ? 0 : ceil(log.fittingSize.height)
        let height = AgentBar.fieldHeight + logHeight
        var f = frame
        f.origin.y = f.maxY - height
        f.size.height = height
        setFrame(f, display: true, animate: false)
        log.frame = NSRect(x: 0, y: 0, width: f.width, height: logHeight)
        log.isHidden = model.isEmpty
    }

    private func buildContent(size: NSSize) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.98).cgColor
        root.layer?.cornerRadius = 14
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        root.autoresizesSubviews = true

        let icon = NSImageView(frame: NSRect(x: 20, y: size.height - 46, width: 28, height: 28))
        icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Tell Sunlight")
        icon.contentTintColor = NSColor(calibratedRed: 1, green: 0.78, blue: 0.25, alpha: 1)
        icon.symbolConfiguration = .init(pointSize: 20, weight: .medium)
        icon.autoresizingMask = [.minYMargin]
        root.addSubview(icon)

        field.frame = NSRect(x: 58, y: size.height - 48, width: size.width - 78, height: 32)
        field.autoresizingMask = [.width, .minYMargin]
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(string: "Tell Sunlight what to do…", attributes: [
            .foregroundColor: NSColor(white: 1, alpha: 0.35),
            .font: NSFont.systemFont(ofSize: 22, weight: .regular),
        ])
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        root.addSubview(field)

        log = NSHostingView(rootView: AgentBarLog(model: model))
        log.frame = NSRect(x: 0, y: 0, width: size.width, height: 0)
        log.autoresizingMask = [.width]
        log.isHidden = true
        root.addSubview(log)
        return root
    }
}

// MARK: - What shows under the field

@MainActor
final class AgentBarModel: ObservableObject {
    @Published var hasKey = true
    @Published var steps: [String] = []
    @Published var state: AgentRun.State?
    /// A step waiting on Allow or Don't.
    @Published var confirmation: String?
    var onOpenSettings: (() -> Void)?
    var onStop: (() -> Void)?
    var onAnswer: ((Bool) -> Void)?

    var isEmpty: Bool { hasKey && steps.isEmpty && state == nil }

    func reset(hasKey: Bool) {
        self.hasKey = hasKey
        steps = []
        state = nil
        confirmation = nil
    }

    func begin(request: String) {
        hasKey = true
        steps = []
        state = .working("Thinking")
    }
}

struct AgentBarLog: View {
    @ObservedObject var model: AgentBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.08))
            if !model.hasKey {
                HStack(spacing: 10) {
                    Text("Tell Sunlight needs your Anthropic API key.")
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Button("Open Settings…") { model.onOpenSettings?() }
                }
                .padding(.horizontal, 20)
            }
            ForEach(Array(model.steps.enumerated()), id: \.offset) { _, step in
                Label(step, systemImage: "checkmark")
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 20)
            }
            if let question = model.confirmation {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Color(nsColor: .systemYellow))
                    Text(question).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Don't") { model.onAnswer?(false) }
                    Button("Allow") { model.onAnswer?(true) }.buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20)
            }
            switch model.state {
            case .working(let what)? where model.confirmation == nil:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(what + "…").foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Button("Stop") { model.onStop?() }
                    Text("esc").font(.caption).foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 20)
            case .finished(let answer)?:
                Text(answer)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
            case .failed(let why)?:
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            case .stopped?:
                Label("Stopped. What's done stays done.", systemImage: "stop.circle")
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 20)
            case nil, .working?:
                EmptyView()
            }
        }
        .font(.system(size: 14))
        .padding(.bottom, 14)
        .frame(width: 620, alignment: .leading)
    }
}
