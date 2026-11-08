import AppKit
import ServiceManagement

/// Sunlight as a login item, so the environment is the first thing on screen after login.
/// Ad-hoc signing gives every rebuild a new identity, which the system may treat as a new app;
/// `register()` is therefore called on every takeover launch and is a no-op once enabled.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Even the status check is a round trip to launchd: call it off the main thread. Only opening
    /// System Settings comes back to it.
    static func register() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do {
            try service.register()
        } catch {
            Log.note("Login item: register failed — \(error.localizedDescription)")
            return
        }
        let status = service.status
        Log.note("Login item: \(describe(status))")
        if status == .requiresApproval {
            DispatchQueue.main.async { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    static func unregister() {
        let service = SMAppService.mainApp
        guard service.status == .enabled || service.status == .requiresApproval else { return }
        do {
            try service.unregister()
        } catch {
            Log.note("Login item: unregister failed — \(error.localizedDescription)")
        }
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval in System Settings › General › Login Items"
        case .notRegistered: return "not registered"
        case .notFound: return "not found (rebuilt bundle? sign with SIGN=… to keep a stable identity)"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }
}
