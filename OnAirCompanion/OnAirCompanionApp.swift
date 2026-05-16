import SwiftUI

/// Handles app lifecycle events such as termination.
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App struct so we can stop the coordinator on termination.
    var coordinator: AppCoordinator?

    func applicationWillTerminate(_ notification: Notification) {
        guard let coordinator else { return }

        // Kick off async shutdown (sends final off-air status, disconnects WebSockets).
        var finished = false
        Task { @MainActor in
            await coordinator.stop()
            finished = true
        }

        // Spin the RunLoop so the async Task can execute and WebSocket close
        // frames have time to send before the process exits.
        let deadline = Date().addingTimeInterval(0.5)
        while !finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }
}

@main
struct OnAirCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var coordinator = AppCoordinator()

    /// SF Symbol name derived from current app state.
    private var menuBarIcon: String {
        switch coordinator.appState {
        case .disconnected: "antenna.radiowaves.left.and.right.slash"
        case .idle: "antenna.radiowaves.left.and.right"
        case .inCall: "mic.slash.fill"
        case .onAir: "mic.fill"
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(coordinator)
        } label: {
            Label("OnAir Companion", systemImage: menuBarIcon)
        }
        Settings {
            SettingsView()
                .environment(coordinator)
        }
    }

    init() {
        // Wire the coordinator into the AppDelegate for termination cleanup,
        // then start services. We use _coordinator to access the underlying
        // State storage so we get the same instance the views will see.
        let coord = _coordinator.wrappedValue
        // Defer actual startup to avoid doing work during init
        Task { @MainActor in
            NSApplication.shared.delegate.flatMap { $0 as? AppDelegate }?.coordinator = coord
            coord.start()
        }
    }
}
