import SwiftUI

/// The dropdown menu content displayed when the menu bar icon is clicked.
struct MenuBarView: View {
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.openSettings) private var openSettings

    private var statusText: String {
        switch coordinator.appState {
        case .disconnected: "Status: Disconnected"
        case .idle: "Status: Idle"
        case .inCall: "Status: In Call (Muted)"
        case .onAir: "Status: On Air"
        }
    }

    private var teamsText: String {
        switch coordinator.teamsMonitor.connectionState {
        case .connected:
            "Teams: Connected"
        case .pairing:
            "Teams: Waiting for Approval"
        case .connecting:
            "Teams: Connecting..."
        case .error(let msg):
            "Teams: \(msg)"
        case .disconnected:
            "Teams: Disconnected"
        }
    }

    private var pluginText: String {
        if coordinator.pluginClient.connectionState == .connected {
            let occupantId = UserDefaults.standard.string(forKey: "occupantId") ?? ""
            return occupantId.isEmpty ? "Plugin: Connected" : "Plugin: Connected (\(occupantId))"
        }
        return "Plugin: Disconnected"
    }

    var body: some View {
        Text(statusText)
        Divider()
        Text(teamsText)
        Text(pluginText)
        Divider()
        Button("Settings...") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button("Quit OnAir Companion") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
