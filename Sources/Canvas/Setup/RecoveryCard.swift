import AppKit
import CoreImage

/// The Recovery step, designed to be read from a phone while the Mac is off: the steps, the two
/// commands with Copy, a QR code that opens the same steps on sunlight.software, and a share button
/// for AirDrop or Messages to yourself, which also works with no internet on the phone.
@MainActor
final class RecoveryCard: NSView {
    /// What the card is for: live windows (SIP partly off, the boot argument), or the uninstall's
    /// opposite (SIP fully on again).
    enum Variant: Sendable {
        case liveWindows
        case protectionBackOn

        var commands: String {
            switch self {
            case .liveWindows: return SetupStatus.recoveryCommands
            case .protectionBackOn: return "csrutil enable"
            }
        }

        /// The steps as a web page, for the QR code. Hosted, because the Mac that could serve them is
        /// in Recovery while they're read; the pages are on sunlight.software.
        var page: URL {
            switch self {
            case .liveWindows: return URL(string: "https://sunlight.software/recovery")!
            case .protectionBackOn: return URL(string: "https://sunlight.software/recovery/uninstall")!
            }
        }

        /// For Send to iPhone: the commands themselves, so they're readable offline, then the page.
        var shareText: String {
            "Sunlight, in Recovery's Terminal:\n\(commands)\n\nAll the steps: \(page.absoluteString)"
        }

        var typing: String {
            switch self {
            case .liveWindows: return "type these two lines and press Return after each:"
            case .protectionBackOn: return "type this line and press Return:"
            }
        }

        var after: String {
            switch self {
            case .liveWindows:
                return "3. Choose Apple menu › Restart. If the second line is refused, skip it: Sunlight sets the boot argument from here afterwards, with one more restart."
            case .protectionBackOn:
                return "3. Choose Apple menu › Restart. Sunlight opens once more afterwards, to finish."
            }
        }

        var caveat: String? {
            switch self {
            case .liveWindows: return "The second line replaces any boot arguments already set."
            case .protectionBackOn: return nil
            }
        }
    }

    private let share = NSButton(title: "Send to iPhone…", target: nil, action: nil)
    private let variant: Variant

    init(_ variant: Variant = .liveWindows) {
        self.variant = variant
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor

        let steps = NSTextField(wrappingLabelWithString: """
            1. Choose Apple menu › Shut Down. Press and hold the power button until “Loading startup options” appears, then choose Options.
            2. In Recovery, choose Utilities › Terminal. Pick your administrator account if asked, then \(variant.typing)
            """)
        steps.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        steps.textColor = .labelColor
        steps.preferredMaxLayoutWidth = 320

        let commands = NSTextField(labelWithString: variant.commands)
        commands.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        commands.isSelectable = true
        commands.maximumNumberOfLines = 2
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyCommands))
        copy.controlSize = .small
        share.target = self
        share.action = #selector(shareCommands)
        share.controlSize = .small
        let buttons = NSStackView(views: [copy, share])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let after = NSTextField(wrappingLabelWithString: variant.after)
        after.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        after.textColor = .labelColor
        after.preferredMaxLayoutWidth = 320

        var leftViews = [steps, commands, buttons, after]
        if let text = variant.caveat {
            let caveat = NSTextField(wrappingLabelWithString: text)
            caveat.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caveat.textColor = .secondaryLabelColor
            caveat.preferredMaxLayoutWidth = 320
            leftViews.append(caveat)
        }
        let left = NSStackView(views: leftViews)
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        left.setCustomSpacing(4, after: commands)

        let qr = NSImageView()
        qr.image = RecoveryCard.qrCode(variant.page.absoluteString, side: 132)
        qr.imageScaling = .scaleNone
        qr.wantsLayer = true
        qr.layer?.backgroundColor = NSColor.white.cgColor
        qr.layer?.cornerRadius = 8
        qr.widthAnchor.constraint(equalToConstant: 148).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 148).isActive = true
        qr.setAccessibilityLabel("QR code that opens these steps at \(variant.page.absoluteString)")
        let scan = NSTextField(wrappingLabelWithString: RecoveryCard.scanCaption)
        scan.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scan.textColor = .secondaryLabelColor
        scan.alignment = .center
        scan.preferredMaxLayoutWidth = 148
        let right = NSStackView(views: [qr, scan])
        right.orientation = .vertical
        right.alignment = .centerX
        right.spacing = 6

        let row = NSStackView(views: [left, right])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 20
        row.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func copyCommands() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(variant.commands + "\n", forType: .string)
    }

    @objc private func shareCommands() {
        let picker = NSSharingServicePicker(items: [variant.shareText])
        picker.show(relativeTo: share.bounds, of: share, preferredEdge: .minY)
    }

    static let scanCaption = "Scan to open these steps on your phone."

    /// `text` (the steps page's address) as a QR code, drawn crisp at `side` points.
    static func qrCode(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = floor(side / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Shutting down and restarting

    /// Through System Events, which asks once for Sunlight's permission to control it
    /// (`NSAppleEventsUsageDescription`). nil on success, else what went wrong, for an alert that
    /// points at the Apple menu instead.
    static func shutDown() -> String? { tellSystemEvents("shut down") }
    static func restart() -> String? { tellSystemEvents("restart") }

    private static func tellSystemEvents(_ verb: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "tell application \"System Events\" to \(verb)") else { return "no AppleScript" }
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        let message = error[NSAppleScript.errorMessage] as? String ?? "error \(error[NSAppleScript.errorNumber] ?? "?")"
        Log.note("Setup: couldn't \(verb) through System Events — \(message)")
        return message
    }
}
