import Foundation
import Network
import os

/// Browsing state for mDNS service discovery.
enum DiscoveryState: Sendable, Equatable {
    case idle
    case browsing
    case error(String)
}

/// A discovered homebridge-onair server on the local network.
struct DiscoveredServer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let host: String
    let port: UInt16
    let protocolVersion: String?

    var url: URL { URL(string: "ws://\(host):\(port)")! }
}

/// Discovers homebridge-onair plugin instances on the local network via mDNS,
/// with fallback to a manually-configured URI from UserDefaults.
@Observable @MainActor
final class ServerDiscovery {
    private(set) var state: DiscoveryState = .idle
    private(set) var discoveredServers: [DiscoveredServer] = []
    private(set) var selectedServer: DiscoveredServer?

    /// Manual URI override — when set, this is used instead of (or in addition to) mDNS.
    var manualURI: String {
        get { UserDefaults.standard.string(forKey: "pluginURI") ?? "" }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: "pluginURI")
            } else {
                UserDefaults.standard.set(newValue, forKey: "pluginURI")
            }
        }
    }

    private var browser: NWBrowser?
    private var resolveConnections: [String: NWConnection] = [:]
    private let logger = Logger(subsystem: "com.alampros.OnAirCompanion", category: "ServerDiscovery")

    // MARK: - Public API

    /// Begin browsing for `_onair._tcp` services on the local network.
    func startBrowsing() {
        guard state != .browsing else {
            logger.debug("Already browsing — skipping startBrowsing()")
            return
        }

        stopBrowsing()

        let params = NWParameters()
        params.includePeerToPeer = true
        let newBrowser = NWBrowser(for: .bonjour(type: "_onair._tcp", domain: nil), using: params)

        newBrowser.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                self?.handleBrowserStateChange(newState)
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                self?.handleResultsChanged(results: results, changes: changes)
            }
        }

        browser = newBrowser
        state = .browsing
        logger.info("Starting mDNS browse for _onair._tcp")
        newBrowser.start(queue: .main)
    }

    /// Stop browsing and cancel all pending resolutions.
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        for (_, connection) in resolveConnections {
            connection.cancel()
        }
        resolveConnections.removeAll()
        state = .idle
        logger.info("Stopped mDNS browsing")
    }

    /// Select a discovered server for use.
    func selectServer(_ server: DiscoveredServer?) {
        selectedServer = server
        if let server {
            logger.info("Selected server: \(server.name) at \(server.host):\(server.port)")
        } else {
            logger.info("Deselected server")
        }
    }

    /// Returns the manual server (if configured) as a `DiscoveredServer`.
    var manualServer: DiscoveredServer? {
        let uri = manualURI
        guard !uri.isEmpty,
              let url = URL(string: uri),
              let host = url.host else { return nil }
        let port = url.port.map { UInt16($0) } ?? 18440
        return DiscoveredServer(
            id: "manual",
            name: "Manual (\(host))",
            host: host,
            port: port,
            protocolVersion: nil
        )
    }

    /// All available servers: manual (if configured) + discovered via mDNS.
    var allServers: [DiscoveredServer] {
        var servers: [DiscoveredServer] = []
        if let manual = manualServer {
            servers.append(manual)
        }
        servers.append(contentsOf: discoveredServers)
        return servers
    }

    // MARK: - Browser State

    private func handleBrowserStateChange(_ newState: NWBrowser.State) {
        switch newState {
        case .ready:
            state = .browsing
            logger.info("Browser ready")
        case .failed(let error):
            state = .error(error.localizedDescription)
            logger.error("Browser failed: \(error.localizedDescription)")
            // Attempt to restart after a delay
            scheduleBrowseRestart()
        case .cancelled:
            state = .idle
            logger.info("Browser cancelled")
        case .waiting(let error):
            // May indicate local network permission denied
            state = .error("Waiting: \(error.localizedDescription)")
            logger.warning("Browser waiting: \(error.localizedDescription)")
        case .setup:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Results Changed

    private func handleResultsChanged(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                logger.info("Service added: \(result.endpoint.debugDescription)")
                resolveEndpoint(result)
            case .removed(let result):
                logger.info("Service removed: \(result.endpoint.debugDescription)")
                removeServer(for: result.endpoint)
            case .changed(old: _, new: let newResult, flags: _):
                logger.info("Service changed: \(newResult.endpoint.debugDescription)")
                removeServer(for: newResult.endpoint)
                resolveEndpoint(newResult)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    // MARK: - Endpoint Resolution

    /// Resolve a Bonjour service endpoint to a concrete host:port by opening a
    /// temporary NWConnection and reading the resolved remote endpoint.
    private func resolveEndpoint(_ result: NWBrowser.Result) {
        let endpoint = result.endpoint
        let endpointID = endpoint.debugDescription

        // Extract TXT record protocol version
        var protocolVersion: String?
        if case .bonjour(let txtRecord) = result.metadata {
            protocolVersion = txtRecord["v"]
        }

        // Extract service name
        let serviceName: String
        if case .service(let name, _, _, _) = endpoint {
            serviceName = name
        } else {
            serviceName = endpointID
        }

        let connection = NWConnection(to: endpoint, using: .tcp)
        resolveConnections[endpointID] = connection

        connection.stateUpdateHandler = { [weak self, endpointID, serviceName, protocolVersion] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch newState {
                case .ready:
                    // Extract the resolved host:port from the connection path
                    if let resolvedEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = resolvedEndpoint {
                        let hostString: String
                        switch host {
                        case .ipv4(let addr):
                            // Strip interface scope suffix (e.g. "%en0") that would
                            // break URL construction (ws://10.0.0.10%en0:18440 is invalid).
                            let raw = "\(addr)"
                            hostString = raw.split(separator: "%").first.map(String.init) ?? raw
                        case .ipv6(let addr):
                            let raw = "\(addr)"
                            hostString = raw.split(separator: "%").first.map(String.init) ?? raw
                        case .name(let name, _):
                            hostString = name
                        @unknown default:
                            hostString = "\(host)"
                        }
                        let server = DiscoveredServer(
                            id: endpointID,
                            name: serviceName,
                            host: hostString,
                            port: port.rawValue,
                            protocolVersion: protocolVersion
                        )
                        if !self.discoveredServers.contains(where: { $0.id == endpointID }) {
                            self.discoveredServers.append(server)
                            self.logger.info("Resolved \(serviceName) → \(hostString):\(port.rawValue)")
                            // Auto-select the first discovered server if none is selected
                            if self.selectedServer == nil {
                                self.selectServer(server)
                            }
                        }
                    }
                    // Clean up the temporary connection
                    connection.cancel()
                    self.resolveConnections.removeValue(forKey: endpointID)

                case .failed(let error):
                    self.logger.warning("Resolution failed for \(endpointID): \(error.localizedDescription)")
                    connection.cancel()
                    self.resolveConnections.removeValue(forKey: endpointID)

                case .cancelled:
                    self.resolveConnections.removeValue(forKey: endpointID)

                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
    }

    private func removeServer(for endpoint: NWEndpoint) {
        let endpointID = endpoint.debugDescription
        discoveredServers.removeAll { $0.id == endpointID }
        // If the selected server was removed, clear selection
        if selectedServer?.id == endpointID {
            selectedServer = nil
        }
        // Cancel any pending resolution
        resolveConnections[endpointID]?.cancel()
        resolveConnections.removeValue(forKey: endpointID)
    }

    // MARK: - Restart

    private func scheduleBrowseRestart() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.logger.info("Restarting browse after failure...")
            self.startBrowsing()
        }
    }
}
