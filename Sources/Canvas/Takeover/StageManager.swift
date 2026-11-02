import Foundation

/// Stage Manager and Sunlight can't share a Mac: with it on, macOS hides every other app's windows into
/// the strip at the side whenever one app comes forward, so opening an app seems to close the last one,
/// and windows jump to the stage instead of staying where the canvas put them.
///
/// So Sunlight turns it off while it runs, from the open-at-login page of setup on (where the wizard says
/// so), and turns it back on as it quits, the same way takeover's Dock settings come back. Only a Stage
/// Manager that Sunlight itself turned off is turned back on: `turnedOffKey` says so, and it survives a
/// crash, so the next launch (or `--release`, or Uninstall) still puts it back.
///
/// The switch is Control Center's own: `com.apple.WindowManager GloballyEnabled`. The WindowManager
/// process watches the key, so writing it is enough; nothing restarts.
enum StageManager {
    static let domain = "com.apple.WindowManager"
    static let key = "GloballyEnabled"
    /// In Sunlight's own defaults: Stage Manager was on, and Sunlight turned it off.
    static let turnedOffKey = "stageManager.turnedOff"

    /// Where the switch and Sunlight's note about it live. The real Mac's in `.mac`; tests pass their own.
    struct Store {
        var read: () -> Bool
        var write: (Bool) -> Void
        var turnedOff: () -> Bool
        var setTurnedOff: (Bool) -> Void
        /// To the setup journal.
        var note: (String) -> Void = { _ in }

        static var mac: Store {
            Store(read: {
                      CFPreferencesAppSynchronize(domain as CFString)
                      return CFPreferencesGetAppBooleanValue(key as CFString, domain as CFString, nil)
                  },
                  write: { on in
                      CFPreferencesSetAppValue(key as CFString, on as CFBoolean, domain as CFString)
                      CFPreferencesAppSynchronize(domain as CFString)
                  },
                  turnedOff: { UserDefaults.standard.bool(forKey: turnedOffKey) },
                  setTurnedOff: { off in
                      if off { UserDefaults.standard.set(true, forKey: turnedOffKey) } else { UserDefaults.standard.removeObject(forKey: turnedOffKey) }
                      UserDefaults.standard.synchronize()
                  },
                  note: { SetupJournal.note($0) })
        }
    }

    /// Stage Manager is on right now.
    static func isOn(_ store: Store = .mac) -> Bool { store.read() }

    /// Sunlight turned it off and owes it back.
    static func turnedOffBySunlight(_ store: Store = .mac) -> Bool { store.turnedOff() }

    /// Turns Stage Manager off if it's on, noting that Sunlight did. Returns whether it was on.
    @discardableResult
    static func turnOff(_ store: Store = .mac, why: String) -> Bool {
        guard store.read() else { return false }
        // The note first: a crash between the two still leaves Sunlight owing it back.
        store.setTurnedOff(true)
        store.write(false)
        store.note("Stage Manager was on; turned it off (\(why)). It comes back on when Sunlight quits")
        return true
    }

    /// Turns Stage Manager back on if Sunlight turned it off. One the person turned off themselves, or
    /// turned back on while Sunlight ran, is left as it is. Returns whether it was turned on.
    @discardableResult
    static func restore(_ store: Store = .mac) -> Bool {
        guard store.turnedOff() else { return false }
        store.setTurnedOff(false)
        guard !store.read() else { return false }
        store.write(true)
        store.note("Stage Manager turned back on, as it was before Sunlight")
        return true
    }

    /// One line for Diagnose and `--status`.
    static func describe(on: Bool, turnedOffBySunlight: Bool) -> String {
        switch (on, turnedOffBySunlight) {
        case (true, _): return "on (Sunlight needs it off: windows hide into the strip whenever an app comes forward)"
        case (false, true): return "off, turned off by Sunlight; it comes back on when Sunlight quits"
        case (false, false): return "off"
        }
    }

    static func describeCurrent(_ store: Store = .mac) -> String {
        describe(on: store.read(), turnedOffBySunlight: store.turnedOff())
    }
}
