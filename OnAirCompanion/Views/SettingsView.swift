import SwiftUI

/// Settings form for configuring the companion app.
struct SettingsView: View {
    @Environment(AppCoordinator.self) var coordinator
    @AppStorage("occupantId") private var occupantId: String = ""
    @AppStorage("pluginURI") private var pluginURI: String = ""
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Occupant ID", text: $occupantId, prompt: Text("Required"))
                TextField("Plugin URI", text: $pluginURI, prompt: Text("ws://host:port (optional)"))
            }

            Section("General") {
                @Bindable var bindableLAL = launchAtLogin
                Toggle("Launch at Login", isOn: $bindableLAL.isEnabled)
            }

            Section("Microsoft Teams") {
                let teamsState = coordinator.teamsMonitor.connectionState
                let teamsConnected = teamsState == .connected
                HStack {
                    Text("Status:")
                    Text(teamsConnected ? "Connected" : "Disconnected")
                        .foregroundStyle(teamsConnected ? .green : .secondary)
                }
                Button("Re-pair Teams") {
                    coordinator.teamsMonitor.clearPairingToken()
                }
                .help("Clears the stored pairing token and reconnects to Teams")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 340)
    }
}
