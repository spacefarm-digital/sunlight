import SwiftUI

/// How the wizard fits its screen: a type scale from the screen's width, and the strip the menu bar and
/// the Dock take, which the content stays out of.
struct SetupMetrics {
    var scale: CGFloat = 1
    var insets = EdgeInsets()

    static func fit(screen: NSScreen) -> SetupMetrics {
        let frame = screen.frame, visible = screen.visibleFrame
        let scale = min(max(visible.width / 1512, 0.78), 1.2)
        return SetupMetrics(scale: scale, insets: EdgeInsets(top: frame.maxY - visible.maxY, leading: visible.minX - frame.minX,
                                                             bottom: visible.minY - frame.minY, trailing: frame.maxX - visible.maxX))
    }
}

/// What a page shows. The controller builds one from the Mac's state (`SetupFlow` picks the page); the
/// view draws it: an eyebrow, a headline, a subheadline or a paragraph or two, one of the extras, the big
/// button, the quiet ones, and a line under them.
struct SetupPageSpec {
    struct Action: Identifiable {
        let id: String
        var title: String
        var enabled = true
        var run: () -> Void
    }

    enum Extra { case none, loginItem, consent, recovery, tour, tutorial }

    var page: SetupFlow.Page
    var eyebrow: String?
    var headline: String
    /// One larger, lighter line under the headline, in place of paragraphs: the welcome's.
    var subheadline: String?
    var paragraphs: [String]
    var extra: Extra = .none
    var primary: Action?
    var secondary: [Action] = []
    var note: String?
    /// System Settings is being watched: the page moves on by itself.
    var watching = false
    var busy = false
    /// The app icon above the headline: the welcome, the preview's "you're set".
    var showsIcon = false
    /// The tutorial's question: one action per answer, drawn as cards.
    var choices: [Tutorial.Input: Action] = [:]
}

/// The wizard's state as the view sees it.
@MainActor
final class SetupWizardModel: ObservableObject {
    enum Direction { case forward, backward }

    struct Notice: Equatable {
        var title: String
        var detail: String
        var isError: Bool
    }

    @Published var page: SetupFlow.Page = .welcome
    @Published var spec: SetupPageSpec
    /// The page just left, drawn while it fades; bumped `transition` starts the move.
    @Published var leaving: SetupPageSpec?
    @Published var transition = 0
    @Published var direction: Direction = .forward
    @Published var rail: [SetupFlow.RailEntry] = []
    @Published var notice: Notice?
    /// The welcome's "Open Sunlight when I log in".
    @Published var loginItem = true
    /// The consent page's box; Continue waits for it.
    @Published var consent = false
    /// Trackpad or mouse, for the tutorial; nil until asked.
    @Published var tutorialInput: Tutorial.Input?
    /// The tutorial's step, from 0.
    @Published var lesson = 0
    /// The "Open at launch" switch: live pages, not the tour, not in review.
    @Published var showsOpenAtLaunch = false
    @Published var copied = false
    /// How much of the page is in while the welcome music plays (`WelcomeReveal`); all of it otherwise.
    @Published var reveal: WelcomeReveal = .all
    let review: Bool

    init(review: Bool) {
        self.review = review
        spec = SetupPageSpec(page: .welcome, headline: "", paragraphs: [])
    }
}

// MARK: - The wizard

struct SetupWizardView: View {
    @ObservedObject var model: SetupWizardModel
    var metrics: SetupMetrics
    var onLater: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("SunlightSetupAtLaunch") private var opensAtLaunch = true

    private var s: CGFloat { metrics.scale }

    var body: some View {
        ZStack {
            if contrast == .increased {
                Rectangle().fill(.black.opacity(0.3)).ignoresSafeArea()
            }
            PageStage(key: model.transition, sign: model.direction == .forward ? 1 : -1, leaving: model.leaving, reduceMotion: reduceMotion) { old in
                SetupPageView(spec: old ?? model.spec, model: model, isCurrent: old == nil, scale: s)
            }
            .padding(.horizontal, 48 * s)
            .padding(.top, metrics.insets.top)
            .padding(.bottom, metrics.insets.bottom)

            VStack {
                RailDots(entries: model.rail, scale: s)
                    .padding(.top, metrics.insets.top + 44 * s)
                    .modifier(Arrival(held: model.reveal < .chrome, reduceMotion: reduceMotion, rise: 0))
                Spacer()
                HStack {
                    // Not on the tour: taking over is the way on from there.
                    if model.page != .tour {
                        Button("Set Up Later", action: onLater)
                            .quietButton(size: 14 * s, dim: 0.6)
                            .accessibilityHint("Closes setup. It comes back when there's more to do.")
                            // Last of all, and only a slow fade, so it draws the eye least.
                            .modifier(Arrival(held: model.reveal < .later, reduceMotion: reduceMotion,
                                              duration: Arrival.laterDuration, plain: true))
                    }
                    Spacer()
                    if model.showsOpenAtLaunch {
                        Toggle(isOn: $opensAtLaunch) {
                            Text("Open at launch until live windows are set up")
                                .font(.system(size: 13 * s, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.55))
                        }
                        .toggleStyle(.switch)
                        .transition(.opacity)
                        .modifier(Arrival(held: model.reveal < .chrome, reduceMotion: reduceMotion, rise: 0))
                    }
                }
                .padding(.horizontal, 36 * s)
                .padding(.bottom, metrics.insets.bottom + 36 * s)
                .animation(.easeInOut(duration: 0.25), value: model.showsOpenAtLaunch)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.page) { _, _ in announce() }
        .onAppear(perform: announce)
    }

    private func announce() {
        let spec = model.spec
        AccessibilityNotification.Announcement("\(spec.eyebrow ?? ""). \(spec.headline)").post()
    }
}

// MARK: - A page

struct SetupPageView: View {
    var spec: SetupPageSpec
    @ObservedObject var model: SetupWizardModel
    /// The page on screen, as against the one fading out behind it.
    var isCurrent: Bool
    var scale: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Held back for the welcome music until `part`'s moment; only the page on screen.
    private func held(_ part: WelcomeReveal) -> Bool { isCurrent && model.reveal < part }
    /// The buttons, held until the closing chord: unclickable and out of the Tab order till then.
    private var actionsHeld: Bool { held(.start) }

    /// The sun. A bare build (`swift run`, `.build/release/Sunlight`) has no bundle icon, only the
    /// generic one, so it takes the checkout's `Resources/Sunlight.icns`.
    static let appIcon: NSImage = {
        if Bundle.main.bundleURL.pathExtension == "app" { return NSApp.applicationIconImage }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return NSImage(contentsOf: checkout.appendingPathComponent("Resources/Sunlight.icns")) ?? NSApp.applicationIconImage
    }()

    private var s: CGFloat { scale }
    private var tall: Bool { spec.extra == .recovery || spec.extra == .tour || spec.extra == .tutorial || spec.paragraphs.count >= 3 }

    var body: some View {
        VStack(spacing: 0) {
            if spec.showsIcon {
                Image(nsImage: Self.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112 * s, height: 112 * s)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.22), radius: 18 * s, y: 10 * s)
                    .modifier(Arrival(held: held(.sun), reduceMotion: reduceMotion, scale: 0.85,
                                      duration: Arrival.sunDuration, rise: 40))
                    // When the chime lands on it: a slight settle.
                    .keyframeAnimator(initialValue: 1.0, trigger: isCurrent && model.reveal >= .headline) { icon, size in
                        icon.scaleEffect(size)
                    } keyframes: { _ in
                        CubicKeyframe(reduceMotion ? 1 : 1.05, duration: 0.22)
                        CubicKeyframe(1, duration: 0.9)
                    }
                    .padding(.top, 16 * s)
                    .padding(.bottom, 56 * s)
                    .accessibilityHidden(true)
            }
            if let eyebrow = spec.eyebrow {
                Text(eyebrow)
                    .font(.system(size: 13 * s, weight: .semibold))
                    .tracking(1.6 * s)
                    .textCase(.uppercase)
                    .foregroundStyle(.primary.opacity(0.55))
                    .modifier(Arrival(held: held(.headline), reduceMotion: reduceMotion))
                    .padding(.bottom, 22 * s)
            }
            Text(spec.headline)
                .font(.system(size: (tall ? 52 : 64) * s, weight: .semibold))
                .tracking(-1.6 * s)
                .multilineTextAlignment(.center)
                .lineSpacing(-2 * s)
                .foregroundStyle(.primary)
                .frame(maxWidth: 760 * s)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.35), value: spec.headline)
                .modifier(Arrival(held: held(.headline), reduceMotion: reduceMotion))
                .accessibilityAddTraits(.isHeader)
            if let subheadline = spec.subheadline {
                Text(subheadline)
                    .font(.system(size: (tall ? 22 : 26) * s, weight: .regular))
                    .tracking(-0.3 * s)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(maxWidth: 820 * s)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18 * s)
                    .modifier(Arrival(held: held(.headline), reduceMotion: reduceMotion))
            }
            if !spec.paragraphs.isEmpty {
                VStack(spacing: 12 * s) {
                    ForEach(Array(spec.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(size: (tall ? 18 : 20) * s))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4 * s)
                            .foregroundStyle(.primary.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 600 * s)
                .padding(.top, 20 * s)
                .modifier(Arrival(held: held(.headline), reduceMotion: reduceMotion))
            }
            extra
                .modifier(Arrival(held: held(.headline), reduceMotion: reduceMotion))
            actions
                .modifier(Arrival(held: actionsHeld, reduceMotion: reduceMotion, scale: 0.96,
                                  duration: Arrival.buttonDuration, rise: 20))
                .padding(.top, spec.extra == .none ? 40 * s : 30 * s)
            footnote
                .modifier(Arrival(held: held(.headline), reduceMotion: reduceMotion))
            if let notice = model.notice, isCurrent {
                NoticeView(notice: notice, scale: s)
                    .padding(.top, 22 * s)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -0.04 * 982 * s)
        .animation(.easeInOut(duration: 0.3), value: model.notice)
    }

    @ViewBuilder
    private var extra: some View {
        switch spec.extra {
        case .none:
            EmptyView()
        case .loginItem:
            VStack(spacing: 6 * s) {
                Toggle(isOn: $model.loginItem) {
                    Text("Open Sunlight when I log in").font(.system(size: 15 * s, weight: .medium)).foregroundStyle(.primary.opacity(0.85))
                }
                .toggleStyle(.switch)
                Text("Brings Sunlight, and this window, back by itself after the restart live windows need.")
                    .font(.system(size: 13 * s))
                    .foregroundStyle(.primary.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480 * s)
            }
            .padding(.top, 28 * s)
        case .consent:
            Toggle(isOn: $model.consent) {
                Text("I understand, and this is a Mac I'm comfortable changing")
                    .font(.system(size: 15 * s, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
            }
            .toggleStyle(.checkbox)
            .padding(.top, 28 * s)
        case .recovery:
            RecoveryCardView(model: model, scale: s)
                .padding(.top, 28 * s)
        case .tour:
            TourTable(scale: s)
                .padding(.top, 28 * s)
        case .tutorial:
            TutorialStage(input: model.tutorialInput, index: model.lesson, scale: s) { input in spec.choices[input]?.run() }
                .padding(.top, 28 * s)
        }
    }

    private var primaryEnabled: Bool {
        guard let primary = spec.primary else { return false }
        return primary.enabled && !spec.busy && (spec.extra != .consent || model.consent)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 18 * s) {
            if let primary = spec.primary {
                Button(action: primary.run) {
                    HStack(spacing: 10 * s) {
                        if spec.busy {
                            ProgressView().controlSize(.small).tint(PillButtonStyle.spinnerTint(scheme))
                        }
                        Text(primary.title).contentTransition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.25), value: primary.title)
                }
                .primaryButton(scale: s)
                .disabled(!primaryEnabled || actionsHeld)
            } else if spec.busy {
                ProgressView().controlSize(.small)
            }
            if !spec.secondary.isEmpty {
                HStack(spacing: 22 * s) {
                    ForEach(spec.secondary) { action in
                        Button(action.title, action: action.run)
                            .quietButton(size: 15 * s, dim: 0.6)
                            .disabled(!action.enabled || actionsHeld)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footnote: some View {
        if spec.watching {
            HStack(spacing: 8 * s) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7 * s))
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Watching System Settings. This page moves on by itself once the step is done.")
                    .font(.system(size: 13 * s))
                    .foregroundStyle(.primary.opacity(0.5))
            }
            .padding(.top, 22 * s)
            .accessibilityElement(children: .combine)
        } else if let note = spec.note {
            Text(note)
                .font(.system(size: 13 * s))
                .foregroundStyle(.primary.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560 * s)
                .padding(.top, 22 * s)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: note)
        }
    }
}

// MARK: - Recovery

/// The Recovery step, to be read from a phone while the Mac is off: the steps, the two commands with
/// Copy and Send to iPhone, and a QR code that opens the same steps on sunlight.software.
struct RecoveryCardView: View {
    @ObservedObject var model: SetupWizardModel
    var scale: CGFloat
    private var s: CGFloat { scale }
    private let variant = RecoveryCard.Variant.liveWindows

    private var steps: [String] {
        ["Choose Apple menu › Shut Down. Press and hold the power button until “Loading startup options” appears, then choose Options.",
         "In Recovery, choose Utilities › Terminal. Pick your administrator account if asked, then \(variant.typing)"]
    }

    private var after: String {
        variant.after.hasPrefix("3. ") ? String(variant.after.dropFirst(3)) : variant.after
    }

    var body: some View {
        HStack(alignment: .top, spacing: 32 * s) {
            VStack(alignment: .leading, spacing: 12 * s) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    StepRow(number: i + 1, text: step, scale: s)
                }
                CommandCard(commands: variant.commands, scale: s)
                HStack(spacing: 18 * s) {
                    Button(model.copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(variant.commands + "\n", forType: .string)
                        model.copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.copied = false }
                    }
                    .quietButton(size: 15 * s, dim: 0.75)
                    ShareLink(item: variant.shareText) {
                        Text("Send to iPhone…")
                    }
                    .quietButton(size: 15 * s, dim: 0.75)
                }
                .padding(.leading, -10 * s)
                StepRow(number: 3, text: after, scale: s)
                if let caveat = variant.caveat {
                    Text(caveat)
                        .font(.system(size: 13 * s))
                        .foregroundStyle(.primary.opacity(0.45))
                        .padding(.leading, 32 * s)
                }
            }
            .frame(maxWidth: 660 * s)
            VStack(spacing: 10 * s) {
                if let image = RecoveryCard.qrCode(variant.page.absoluteString, side: 132) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .padding(8 * s)
                        .background(RoundedRectangle(cornerRadius: 12 * s, style: .continuous).fill(.white))
                        .accessibilityLabel("QR code that opens these steps at \(variant.page.absoluteString)")
                }
                Text(RecoveryCard.scanCaption)
                    .font(.system(size: 13 * s))
                    .foregroundStyle(.primary.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(width: 168 * s)
            }
        }
        .frame(maxWidth: 880 * s)
    }

    struct StepRow: View {
        var number: Int
        var text: String
        var scale: CGFloat

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 12 * scale) {
                Text("\(number)")
                    .font(.system(size: 18 * scale, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary.opacity(0.4))
                    .frame(width: 20 * scale, alignment: .trailing)
                Text(text)
                    .font(.system(size: 17 * scale))
                    .lineSpacing(3 * scale)
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The two Recovery commands, big enough to read from a phone photo, selectable.
struct CommandCard: View {
    var commands: String
    var scale: CGFloat
    private var s: CGFloat { scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            ForEach(commands.split(separator: "\n").map(String.init), id: \.self) { line in
                Text(line)
                    .font(.system(size: 16 * s, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.92))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
        }
        .padding(.horizontal, 22 * s)
        .padding(.vertical, 16 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16 * s, style: .continuous)
                .fill(.primary.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 16 * s, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 1))
        )
    }
}

// MARK: - Tour

struct TourTable: View {
    var scale: CGFloat
    private var s: CGFloat { scale }

    static let rows: [(String, String)] = [
        ("Canvas ↔ last window", "four-finger tap  ·  Mission Control key"),
        ("Enter a window", "click  ·  ⏎"),
        ("Zoom and pan", "pinch  ·  ⌥ or ⌘ scroll  ·  four-finger drag"),
        ("Place windows", "⌃⌥ keys: one window, one screen, everything"),
        ("Learn the rest", "Settings › How to use  ·  ⌘?"),
        ("Save and restore layouts", "⌘S  ·  ⌘1 – ⌘9"),
        ("Everything else", "the sun icon in the menu bar"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 28 * s, verticalSpacing: 10 * s) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .font(.system(size: 17 * s, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.9))
                        .gridColumnAlignment(.trailing)
                    Text(row.1)
                        .font(.system(size: 17 * s))
                        .foregroundStyle(.primary.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 28 * s)
        .padding(.vertical, 20 * s)
        .background(
            RoundedRectangle(cornerRadius: 18 * s, style: .continuous)
                .fill(.primary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 18 * s, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
        )
    }
}

// MARK: - Notice

/// A failure, or a word of information, under the buttons: never a sheet.
struct NoticeView: View {
    var notice: SetupWizardModel.Notice
    var scale: CGFloat
    private var s: CGFloat { scale }

    var body: some View {
        VStack(spacing: 6 * s) {
            Text(notice.title)
                .font(.system(size: 15 * s, weight: .medium))
                .foregroundStyle(notice.isError ? Color(red: 1.0, green: 0.72, blue: 0.3) : .primary.opacity(0.85))
            if !notice.detail.isEmpty {
                Text(notice.detail)
                    .font(.system(size: 12.5 * s, design: notice.isError ? .monospaced : .default))
                    .foregroundStyle(.primary.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560 * s)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rail

/// The rail's entries as dots: filled when done, a pill for the one the page belongs to.
struct RailDots: View {
    var entries: [SetupFlow.RailEntry]
    var scale: CGFloat
    private var s: CGFloat { scale }

    var body: some View {
        HStack(spacing: 10 * s) {
            ForEach(Array(entries.enumerated()), id: \.offset) { i, entry in
                let current = entry.state == .current
                Capsule()
                    .fill(.primary.opacity(current || entry.state == .done ? 0.9 : 0.28))
                    .frame(width: (current ? 20 : 6) * s, height: 6 * s)
                    .help(entry.title)
                    .accessibilityLabel("Step \(i + 1) of \(entries.count), \(entry.title)\(entry.state == .done ? ", done" : entry.state == .current ? ", current" : "")")
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: entries.map { "\($0.title)\($0.state)" })
    }
}

// MARK: - Arrival

/// The welcome page's parts in the order they come in with the welcome music, each on a moment of it
/// (`moments`, in seconds): the sun rising with the sunrise from an early chime to land on the reveal
/// chime, the headline and everything under it together on that chime, the rail on a later one, Get
/// Started on the closing chord, and last, once that has settled, Set Up Later.
enum WelcomeReveal: Int, Comparable {
    case none, sun, headline, chrome, start, later
    static let all = WelcomeReveal.later

    static let moments: [(at: Double, reveal: WelcomeReveal)] = [
        (1.15, .sun), (WelcomeMusic.climax, .headline), (4.4, .chrome), (WelcomeMusic.cadence, .start),
        // Set Up Later, once Get Started has settled.
        (WelcomeMusic.cadence + Arrival.buttonDuration, .later),
    ]

    static func < (a: WelcomeReveal, b: WelcomeReveal) -> Bool { a.rawValue < b.rawValue }
}

/// How each part of the welcome page comes in, as softly as the music: it eases up out of a blur over
/// `duration`, growing from `scale`. The sun takes longer, rising through the sunrise to the reveal
/// chime; the buttons unfold slowly with the closing chord. Reduce Motion: plain fades at the same moments.
struct Arrival: ViewModifier {
    static let duration = 1.1
    static let sunDuration = WelcomeMusic.climax - WelcomeReveal.moments[0].at
    static let buttonDuration = 1.8
    static let laterDuration = 1.8

    var held: Bool
    var reduceMotion: Bool
    /// The size it grows from.
    var scale: CGFloat = 1
    var duration = Arrival.duration
    var rise: CGFloat = 30
    /// Only a fade, eased in and out: no rise, blur or growing.
    var plain = false

    func body(content: Content) -> some View {
        let still = reduceMotion || plain || !held
        content
            .opacity(held ? 0 : 1)
            .allowsHitTesting(!held)
            .scaleEffect(still ? 1 : scale)
            .offset(y: still ? 0 : rise)
            .blur(radius: still ? 0 : 10)
            .animation(held ? nil : animation, value: held)
    }

    private var animation: Animation {
        if plain { return .easeInOut(duration: duration) }
        return reduceMotion ? .easeInOut(duration: 0.8) : .timingCurve(0.16, 1, 0.3, 1, duration: duration)
    }
}

// MARK: - Stage

/// Pages come and go by hand rather than by SwiftUI's transitions, so both the leaving page and the
/// arriving one move the way the flow went. Forward: out upwards, in from below. Back: mirrored.
struct PageStage<Content: View>: View {
    /// Bumped by the controller for each page change.
    var key: Int
    var sign: CGFloat
    var leaving: SetupPageSpec?
    var reduceMotion: Bool
    /// The page to draw: nil for the one on screen, or the one on its way out.
    @ViewBuilder var content: (SetupPageSpec?) -> Content

    @State private var enter: CGFloat = 1
    @State private var leave: CGFloat = 0
    @State private var showsLeaving = false
    @State private var token = UUID()

    var body: some View {
        ZStack {
            if showsLeaving, let leaving {
                content(leaving)
                    .opacity(1 - leave)
                    .offset(y: reduceMotion ? 0 : -28 * sign * leave)
                    .blur(radius: reduceMotion ? 0 : 6 * leave)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .id("leaving-\(key)")
            }
            content(nil)
                .opacity(enter)
                .offset(y: reduceMotion ? 0 : 36 * sign * (1 - enter))
                .blur(radius: reduceMotion ? 0 : 8 * (1 - enter))
                .id("page-\(key)")
        }
        .onChange(of: key) { _, _ in
            showsLeaving = leaving != nil
            leave = 0
            enter = 0
            let mine = UUID()
            token = mine
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.25)) {
                    leave = 1
                    enter = 1
                }
            } else {
                withAnimation(.easeIn(duration: 0.32)) { leave = 1 }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.08)) { enter = 1 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if token == mine { showsLeaving = false }
            }
        }
    }
}

// MARK: - Styles

extension View {
    /// The big button: the system's prominent glass button on macOS 26 and later, the ink pill
    /// (`PillButtonStyle`) before it.
    @ViewBuilder
    func primaryButton(scale: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .font(.system(size: 17 * scale, weight: .semibold))
        } else {
            self.buttonStyle(PillButtonStyle(scale: scale))
        }
    }

    /// A quieter way on: the system's glass button on macOS 26 and later, dim text
    /// (`QuietButtonStyle`) before it.
    @ViewBuilder
    func quietButton(size: CGFloat, dim: Double) -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
                .controlSize(.large)
                .font(.system(size: size, weight: .medium))
        } else {
            self.buttonStyle(QuietButtonStyle(size: size, dim: dim))
        }
    }
}

/// The big button: a pill of ink with the ground's colour for its label. Grows a touch under the pointer,
/// gives a little when pressed.
struct PillButtonStyle: ButtonStyle {
    var scale: CGFloat

    /// The spinner in the big button: the label's colour, the accent glass's white or the ink pill's ground.
    static func spinnerTint(_ scheme: ColorScheme) -> Color {
        if #available(macOS 26.0, *) { return .white }
        return scheme == .dark ? .black : .white
    }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17 * scale, weight: .semibold))
            .foregroundStyle(scheme == .dark ? Color(white: 0.06) : .white)
            .padding(.horizontal, 28 * scale)
            .frame(minWidth: 160 * scale, minHeight: 48 * scale)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(hovering && isEnabled ? 1 : 0.94))
                    .overlay(contrast == .increased ? Capsule().strokeBorder(.primary, lineWidth: 1) : nil)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(reduceMotion ? 1 : configuration.isPressed ? 0.97 : hovering && isEnabled ? 1.02 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            .animation(.easeInOut(duration: 0.2), value: isEnabled)
            .onHover { hovering = $0 }
            .contentShape(Capsule())
    }
}

/// A quiet text button: dim, brighter under the pointer.
struct QuietButtonStyle: ButtonStyle {
    var size: CGFloat
    var dim: Double
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.primary.opacity(!isEnabled ? dim * 0.5 : configuration.isPressed ? 1 : hovering ? 0.9 : dim))
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}
