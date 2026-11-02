import AppKit
import SwiftUI

/// Everything the app teaches, as the chapters of Settings › How to use: the basics (the wizard's tour,
/// and its tutorial to play again), the trackpad's gestures acted out, placing windows (the three
/// scopes acted out, with Try), and every key (`ShortcutsPane`). Opened from the menu bar icon's More,
/// ⌘?, and the ? in Settings › Windows, which opens it on Placing.
enum Manual {
    enum Chapter: String, CaseIterable, Identifiable {
        case basics, gestures, placing, shortcuts

        var id: Self { self }

        var title: String {
            switch self {
            case .basics: return "The Basics"
            case .gestures: return "Trackpad Gestures"
            case .placing: return "Placing Windows"
            case .shortcuts: return "Keyboard Shortcuts"
            }
        }

        /// The chapter's name in the pane's segmented control.
        var short: String {
            switch self {
            case .basics: return "Basics"
            case .gestures: return "Trackpad"
            case .placing: return "Placing"
            case .shortcuts: return "Keyboard"
            }
        }

        var symbol: String {
            switch self {
            case .basics: return "sun.max"
            case .gestures: return "hand.draw"
            case .placing: return "rectangle.split.2x1"
            case .shortcuts: return "keyboard"
            }
        }
    }

    struct Row: Equatable {
        let title: String
        let how: String
    }

    /// The canvas in a few lines, in the order you'd learn it.
    static let gettingAround: [Row] = [
        Row(title: "See everything", how: "four-finger tap (or swipe up: Settings › How to use)"),
        Row(title: "Zoom", how: "pinch · ⌥ or ⌘ scroll"),
        Row(title: "Pan", how: "two-finger scroll · drag the empty canvas"),
        Row(title: "Go into a window", how: "click · pinch in over it"),
        Row(title: "Bring a window to the middle", how: "double-click · ⏎ over it"),
        Row(title: "Use a window at 1:1", how: "click, as on the desktop"),
        Row(title: "Canvas ↔ last window", how: "Mission Control key · four-finger tap"),
        Row(title: "Jump to another window", how: "hold the Mission Control key, point at it, let go"),
        Row(title: "Show Desktop", how: "F11 · four-finger spread"),
        Row(title: "Pan from anywhere, even inside a window", how: "four-finger drag, any direction"),
    ]

    /// Where the rest lives.
    static let whereThingsAre: [Row] = [
        Row(title: "The sun icon in the menu bar", how: "Sunlight on or off, the minimap, layouts; More for the rest"),
        Row(title: "Place windows", how: "⌃⌥ keys, the Window menu, a window’s right-click menu"),
        Row(title: "Open an app at a spot", how: "double-click the empty canvas · right-click › Open Here…"),
        Row(title: "Save and restore layouts", how: "⌘S · ⌘1 – ⌘9"),
        Row(title: "Settings", how: "⌘, · More › Settings…"),
        Row(title: "How to use", how: "⌘? · ⌘, › How to use"),
    ]
}

// MARK: - Views

/// The wizard's tour, a little longer: getting around the canvas, and where everything else is.
struct BasicsChapter: View {
    let onTutorial: () -> Void

    var body: some View {
        Form {
            Section {
                HStack {
                    RowLabel(title: "The tutorial", subtitle: "The moves from setup, acted out.")
                    Spacer()
                    Button("Play the Tutorial", action: onTutorial)
                }
            }
            Section {
                ForEach(Manual.gettingAround, id: \.title) { row in
                    LabeledContent(row.title) { Text(row.how).foregroundStyle(.secondary) }
                }
            } header: {
                SectionHeader(title: "Getting around",
                              detail: "All your windows on one big canvas. Zoom out to see them, click one to use it.")
            }
            Section {
                ForEach(Manual.whereThingsAre, id: \.title) { row in
                    LabeledContent(row.title) {
                        Text(row.how)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                SectionHeader(title: "Where things are")
            }
        }
        .formStyle(.grouped)
    }
}
