import AppKit
import ServiceManagement

/// Thin wrapper over SMAppService for "Launch at Login".
/// Source of truth is the OS: always read `status`, never cache a Bool.
@MainActor
enum LoginItem {

    private static var service: SMAppService { .mainApp }

    /// The live OS-reported status. Cases: .notRegistered, .enabled,
    /// .requiresApproval, .notFound.
    static var status: SMAppService.Status {
        service.status
    }

    static var isEnabled: Bool {
        service.status == .enabled
    }

    /// User toggled it off in System Settings, or first run pending approval.
    static var needsApproval: Bool {
        service.status == .requiresApproval
    }

    @discardableResult
    static func enable() -> Result<Void, Error> {
        do {
            // register() is idempotent-ish but skip if already enabled.
            if service.status != .enabled {
                try service.register()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    static func disable() -> Result<Void, Error> {
        do {
            try service.unregister()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    static func toggle() -> Result<Void, Error> {
        isEnabled ? disable() : enable()
    }

    /// Deep-link the user to System Settings > General > Login Items,
    /// e.g. when status == .requiresApproval.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
