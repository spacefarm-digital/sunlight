import Foundation

/// Tell Sunlight's limits, in one place to read and change. They're enforced by Sunlight's code
/// (`AgentRun`, `AppTools`), whatever the model says or an app's content asks for.
enum Guardrails {
    /// Tool calls in one request: past this the run stops and says what's left.
    static let maxToolCalls = 60
    /// Wall-clock time for one request, model replies included. Inside apps a step can take seconds.
    static let maxDuration: TimeInterval = 300
    /// Characters of the request typed into the bar.
    static let maxRequestLength = 2000
    /// Characters of one snapshot sent back to the model; past it the model is told to drill into a region.
    static let maxSnapshotLength = 40_000

    /// Apps Tell Sunlight never works inside (the canvas tools still move their windows): settings,
    /// secrets and shells, where one wrong click or keystroke costs too much. Sunlight itself too.
    static let blockedApps: Set<String> = [
        "com.apple.systempreferences", "com.apple.Passwords", "com.apple.keychainaccess",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "io.alacritty",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.spacefarm.sunlight",
    ]

    /// Words on a control that mean the click can't be taken back: it sends, deletes, pays or publishes.
    /// Such a click waits for the user to allow it in the bar.
    static let confirmWords = [
        "send", "submit", "delete", "remove", "erase", "trash", "discard", "empty",
        "pay", "buy", "purchase", "order", "checkout", "check out", "subscribe", "unsubscribe",
        "post", "publish", "share", "invite", "transfer", "forward", "reply all", "tweet",
        "sign out", "log out", "uninstall", "reset", "confirm", "accept", "decline",
    ]

    /// The actions that press something; typing or setting a field's value is never final by itself.
    /// expand and collapse are among them: on an element with no disclosure they fall back to pressing it.
    static let pressingActions: Set<String> = ["click", "confirm", "select", "check", "uncheck", "toggle", "expand", "collapse"]

    /// Fields where Return only looks something up: an address bar, a search or filter box. Return anywhere
    /// else (a message, a form) may send, so it asks.
    static let lookupWords = ["search", "address", "url", "location", "find", "filter", "go to", "jump to"]
    /// Fields where Return sends, whatever else their name says ("Message #search-team").
    static let composeWords = ["message", "reply", "comment", "chat", "compose", "write", "post", "tweet", "email", "mail to"]

    /// A press on a control whose name (or, for `select`, the option picked) has one of `confirmWords`
    /// as whole words, in any case. Return (`confirm`) asks unless the field is a search field or named
    /// only as a lookup; the model's own text never counts there, so it can't talk its way past the ask.
    static func needsConfirmation(action: String, name: String, option: String = "", role: String = "") -> Bool {
        guard pressingActions.contains(action) else { return false }
        if action == "confirm" {
            let field = " " + words(name) + " "
            if composeWords.contains(where: { field.contains(" \($0) ") }) { return true }
            if role == "searchfield" { return false }
            return !lookupWords.contains { field.contains(" \($0) ") }
        }
        let text = " " + words(name + " " + option) + " "
        return confirmWords.contains { text.contains(" \($0) ") }
    }

    /// Lowercased, every run of non-letters and non-digits one space.
    static func words(_ s: String) -> String {
        s.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { out, c in if !(c == " " && out.last == " ") { out.append(c) } }
            .trimmingCharacters(in: .whitespaces)
    }
}
