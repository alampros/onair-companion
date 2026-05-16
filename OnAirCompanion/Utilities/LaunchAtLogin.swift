import OSLog
import ServiceManagement

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "LaunchAtLogin")

/// Wrapper around `SMAppService.mainApp` for controlling launch-at-login registration.
@Observable @MainActor
final class LaunchAtLogin {

    /// Whether the app is registered to launch at login.
    ///
    /// Setting this to `true` registers the app; setting to `false` unregisters it.
    /// Backed by a stored property so `@Observable` can track changes.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            do {
                if isEnabled {
                    try SMAppService.mainApp.register()
                    logger.info("Registered as login item")
                } else {
                    try SMAppService.mainApp.unregister()
                    logger.info("Unregistered as login item")
                }
            } catch {
                logger.error("Failed to update login item registration: \(error.localizedDescription)")
                // Revert to the actual OS state on failure.
                isEnabled = SMAppService.mainApp.status == .enabled
            }
        }
    }

    init() {
        self.isEnabled = SMAppService.mainApp.status == .enabled
    }
}
