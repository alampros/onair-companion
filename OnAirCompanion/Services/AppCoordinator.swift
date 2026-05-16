import AppKit
import Foundation
import Network
import os

/// Coordinates Teams monitoring, plugin communication, and server discovery.
///
/// Observes `TeamsMonitor` state changes, debounces them, and forwards
/// the current call/mute status to the `PluginClient`. Derives a combined
/// `AppState` for the UI layer.
@Observable @MainActor
final class AppCoordinator {

    // MARK: - Published State

    /// Combined app state derived from Teams + plugin connection status.
    private(set) var appState: AppState = .disconnected

    // MARK: - Owned Services

    let teamsMonitor = TeamsMonitor()
    let pluginClient = PluginClient()
    let serverDiscovery = ServerDiscovery()

    // MARK: - Private

    private let debouncer = Debouncer(duration: .milliseconds(250))
    private var teamsObservationTask: Task<Void, Never>?
    private var pluginObservationTask: Task<Void, Never>?
    private var serverObservationTask: Task<Void, Never>?

    /// Last state sent to the plugin, for duplicate suppression.
    private var lastSentOnCall: Bool?
    private var lastSentMuted: Bool?

    /// The URL of the server the plugin is currently connected to, so we can
    /// detect when the selected server actually changes.
    private var connectedServerURL: URL?

    /// Observers for system sleep/wake notifications.
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    /// Monitors network path changes to restart mDNS browsing.
    private var pathMonitor: NWPathMonitor?
    /// The last known network path status, used to detect actual changes
    /// (NWPathMonitor fires immediately on start with current state).
    private var lastPathStatus: NWPath.Status?

    private let logger = Logger(subsystem: "com.alampros.OnAirCompanion", category: "AppCoordinator")

    // MARK: - Lifecycle

    /// Start all services and observation loops.
    func start() {
        logger.info("Starting AppCoordinator")

        // Launch TeamsMonitor and ServerDiscovery in parallel
        teamsMonitor.connect()
        serverDiscovery.startBrowsing()

        // Start observation loops
        startTeamsObservation()
        startPluginObservation()
        startServerObservation()

        // System lifecycle
        observeSleepWake()
        startNetworkMonitoring()
    }

    /// Shut down all services and observation loops.
    ///
    /// Async so the caller (AppDelegate) can spin the RunLoop until the
    /// final "off air" message has time to flush over the WebSocket.
    func stop() async {
        logger.info("Stopping AppCoordinator")

        // Cancel observation loops
        teamsObservationTask?.cancel()
        teamsObservationTask = nil
        pluginObservationTask?.cancel()
        pluginObservationTask = nil
        serverObservationTask?.cancel()
        serverObservationTask = nil
        debouncer.cancel()

        // Remove sleep/wake observers
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }

        // Cancel network path monitor
        pathMonitor?.cancel()
        pathMonitor = nil

        // Send final "off air" and give the WebSocket time to flush
        pluginClient.sendStatus(onCall: false, muted: true)
        try? await Task.sleep(for: .milliseconds(100))

        // Disconnect everything
        teamsMonitor.disconnect()
        pluginClient.disconnect()
        serverDiscovery.stopBrowsing()
    }

    // MARK: - Sleep / Wake

    /// Register for system sleep and wake notifications so we can tear down
    /// stale WebSocket connections before sleep and re-establish them on wake.
    private func observeSleepWake() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] (_: Notification) in
            Task { @MainActor [weak self] in
                self?.handleSleep()
            }
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] (_: Notification) in
            Task { @MainActor [weak self] in
                self?.handleWake()
            }
        }
    }

    private func handleSleep() {
        logger.info("System sleeping — disconnecting")
        teamsMonitor.disconnect()
        pluginClient.disconnect()
        serverDiscovery.stopBrowsing()
    }

    private func handleWake() {
        logger.info("System woke — reconnecting")
        // Brief delay to let networking stack reinitialise after wake
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.teamsMonitor.connect()
            self.serverDiscovery.startBrowsing()
            // PluginClient reconnects via server observation when discovery
            // finds a server, so no explicit call needed here.
        }
    }

    // MARK: - Network Monitoring

    /// Watch for network path changes and restart mDNS browsing when the
    /// network becomes available (e.g. switching between Wi-Fi and Ethernet).
    private func startNetworkMonitoring() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkChange(path)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    private func handleNetworkChange(_ path: NWPath) {
        let previousStatus = lastPathStatus
        lastPathStatus = path.status

        // NWPathMonitor fires immediately on start with the current state.
        // Only restart browsing when the status actually transitions to .satisfied.
        guard path.status == .satisfied, previousStatus != nil, previousStatus != .satisfied else { return }
        logger.info("Network available — restarting mDNS browse")
        serverDiscovery.stopBrowsing()
        serverDiscovery.startBrowsing()
    }

    // MARK: - State Derivation

    /// Derive the combined `AppState` from current sub-service states.
    private func deriveAppState() {
        let teamsConnected = teamsMonitor.connectionState == .connected
        let pluginConnected = pluginClient.connectionState == .connected

        let newState: AppState
        if !teamsConnected || !pluginConnected {
            newState = .disconnected
        } else if !teamsMonitor.isInCall {
            newState = .idle
        } else if teamsMonitor.isMuted {
            newState = .inCall
        } else {
            newState = .onAir
        }

        if appState != newState {
            logger.info("App state: \(String(describing: newState))")
            appState = newState
        }
    }

    // MARK: - Teams Observation

    /// Watch TeamsMonitor properties and debounce-forward changes to PluginClient.
    private func startTeamsObservation() {
        teamsObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Read current values (registers observation)
                let connectionState = self.teamsMonitor.connectionState
                let isInCall = self.teamsMonitor.isInCall
                let isMuted = self.teamsMonitor.isMuted

                // Handle the state change
                self.deriveAppState()
                self.debounceSendStatus(
                    teamsConnected: connectionState == .connected,
                    onCall: isInCall,
                    muted: isMuted
                )

                // Wait for next change
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.teamsMonitor.connectionState
                        _ = self.teamsMonitor.isInCall
                        _ = self.teamsMonitor.isMuted
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Debounce and send status to plugin, with duplicate suppression.
    private func debounceSendStatus(teamsConnected: Bool, onCall: Bool, muted: Bool) {
        // When Teams disconnects, TeamsMonitor resets isInCall=false.
        // We still want to forward that to the plugin.
        let effectiveOnCall = teamsConnected ? onCall : false
        let effectiveMuted = teamsConnected ? muted : true

        debouncer.debounce { [weak self] in
            guard let self else { return }
            self.sendStatusIfChanged(onCall: effectiveOnCall, muted: effectiveMuted)
        }
    }

    /// Send status to plugin only if it differs from the last sent state.
    private func sendStatusIfChanged(onCall: Bool, muted: Bool) {
        guard onCall != lastSentOnCall || muted != lastSentMuted else {
            return
        }

        logger.info("Sending status to plugin: onCall=\(onCall), muted=\(muted)")
        pluginClient.sendStatus(onCall: onCall, muted: muted)

        // Update last-sent state. PluginClient.sendStatus guards on .connected
        // internally, so if not connected this is effectively a no-op. We still
        // update tracking here so the replay-on-reconnect path will re-send.
        // Actually — don't update if plugin isn't connected, so replay will fire.
        if pluginClient.connectionState == .connected {
            lastSentOnCall = onCall
            lastSentMuted = muted
        }
    }

    // MARK: - Plugin Observation (Reconnect Replay)

    /// Watch PluginClient connection state. When plugin reconnects to .connected,
    /// immediately replay the current Teams state (no debounce).
    private func startPluginObservation() {
        pluginObservationTask = Task { [weak self] in
            var previousPluginState: PluginConnectionState = .disconnected
            while !Task.isCancelled {
                guard let self else { return }

                let currentPluginState = self.pluginClient.connectionState

                // Detect transition to .connected → replay current Teams state
                if currentPluginState == .connected && previousPluginState != .connected {
                    self.logger.info("Plugin connected — replaying current Teams state")
                    // Clear last-sent so the replay always sends
                    self.lastSentOnCall = nil
                    self.lastSentMuted = nil
                    let onCall = self.teamsMonitor.isInCall
                        && self.teamsMonitor.connectionState == .connected
                    let muted = self.teamsMonitor.isMuted
                        || self.teamsMonitor.connectionState != .connected
                    self.sendStatusIfChanged(onCall: onCall, muted: muted)
                }

                previousPluginState = currentPluginState

                // Also re-derive app state when plugin connection changes
                self.deriveAppState()

                // Wait for next change
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.pluginClient.connectionState
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    // MARK: - Server Observation

    /// Watch ServerDiscovery for selected server changes.
    /// When a server is selected (or changes), connect the PluginClient.
    private func startServerObservation() {
        serverObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let server = self.serverDiscovery.selectedServer

                if let server {
                    let serverURL = server.url
                    // Only reconnect if the server actually changed
                    if serverURL != self.connectedServerURL {
                        self.logger.info("Server changed — connecting plugin to \(serverURL.absoluteString)")
                        self.pluginClient.disconnect()
                        self.connectedServerURL = serverURL
                        self.lastSentOnCall = nil
                        self.lastSentMuted = nil

                        let occupantId = UserDefaults.standard.string(forKey: "occupantId") ?? ""
                        self.pluginClient.connect(to: serverURL, occupantId: occupantId)
                    }
                } else if self.connectedServerURL != nil {
                    // Server deselected — disconnect plugin
                    self.logger.info("Server deselected — disconnecting plugin")
                    self.pluginClient.disconnect()
                    self.connectedServerURL = nil
                    self.deriveAppState()
                }

                // Wait for next change
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.serverDiscovery.selectedServer
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
}
