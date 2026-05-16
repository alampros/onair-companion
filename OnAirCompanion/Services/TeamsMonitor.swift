import Foundation
import os

/// Connection state for the Teams WebSocket.
enum TeamsConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case pairing
    case connected
    case error(String)
}

/// Manages the WebSocket connection to the MS Teams Third-Party API.
@Observable @MainActor
final class TeamsMonitor {
    private(set) var connectionState: TeamsConnectionState = .disconnected
    private(set) var isInCall: Bool = false
    private(set) var isMuted: Bool = true

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var currentBackoff: TimeInterval = 1.0
    private let maxBackoff: TimeInterval = 30.0
    private let logger = Logger(subsystem: "com.alampros.OnAirCompanion", category: "TeamsMonitor")

    private(set) var pairingToken: String? {
        didSet {
            if let token = pairingToken {
                UserDefaults.standard.set(token, forKey: "teamsPairingToken")
            } else {
                UserDefaults.standard.removeObject(forKey: "teamsPairingToken")
            }
        }
    }

    init() {
        pairingToken = UserDefaults.standard.string(forKey: "teamsPairingToken")
    }

    // MARK: - Public API

    /// Clears the stored pairing token and reconnects to Teams for fresh pairing.
    func clearPairingToken() {
        pairingToken = nil
        disconnect()
        connect()
    }

    /// Connect to Teams WebSocket.
    /// Pairing data is sent as query parameters in the WebSocket upgrade URL.
    /// Teams reads them during the HTTP upgrade via Boost.Beast — there is no
    /// separate post-connect JSON pairing message.
    func connect() {
        // Don't reconnect if already connected or connecting
        switch connectionState {
        case .connecting, .pairing, .connected:
            logger.debug("Already connected/connecting — skipping connect()")
            return
        case .disconnected, .error:
            break
        }

        // Cancel any lingering state
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        connectionState = .connecting
        logger.info("Connecting to Teams...")

        // MUST use 127.0.0.1, not localhost — Teams only listens on IPv4.
        // Query params are required for Teams to accept the HTTP upgrade.
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = 8124
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "protocol-version", value: "2.0.0"),
            URLQueryItem(name: "token", value: pairingToken ?? ""),
            URLQueryItem(name: "manufacturer", value: "alampros"),
            URLQueryItem(name: "device", value: "macOS"),
            URLQueryItem(name: "app", value: "OnAirCompanion"),
            URLQueryItem(name: "app-version", value: "1.0.0"),
        ]

        guard let url = components.url else {
            logger.error("Failed to build Teams WebSocket URL")
            connectionState = .error("Invalid URL")
            return
        }

        logger.info("WebSocket URL: \(url.absoluteString)")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        urlSession = session
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        connectionState = .pairing
        startReceiveLoop()
    }

    /// Send a command to Teams (e.g., toggle-mute).
    /// Used during initial pairing to trigger the Allow/Block approval prompt.
    func sendCommand(action: String, requestId: Int = 1) {
        guard let ws = webSocketTask else {
            logger.warning("Cannot send command — not connected")
            return
        }
        let json = "{\"action\":\"\(action)\",\"requestId\":\(requestId),\"parameters\":{}}"
        logger.info("Sending command: \(json)")
        ws.send(.string(json)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.logger.error("Failed to send command: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Disconnect and stop reconnection.
    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isInCall = false
        isMuted = true
        connectionState = .disconnected
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let ws = self.webSocketTask else { break }
                do {
                    let message = try await ws.receive()
                    self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        self.handleDisconnection(error: error)
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            logger.info("Received: \(text)")
            processTextMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                logger.info("Received data: \(text)")
                processTextMessage(text)
            }
        @unknown default:
            logger.warning("Unknown message type")
        }
    }

    private func processTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        // 1. Connection acknowledgment from Teams.
        //    e.g. {"response":"Success","requestId":0}
        //    Teams logs show this corresponds to onAccept → start → onStart.
        //    If we have no stored token this is a fresh pairing — send a
        //    toggle-mute command to trigger the Allow/Block approval prompt.
        if let ack = try? JSONDecoder().decode(TeamsHandshakeResponse.self, from: data) {
            logger.info("Teams response: \(ack.response)")
            if ack.response == "Success" {
                if pairingToken == nil {
                    logger.info("No pairing token — sending toggle-mute to trigger approval prompt")
                    sendCommand(action: "toggle-mute")
                } else {
                    markConnected()
                }
            }
            return
        }

        // 2. Pairing token — Teams sends this after the user clicks Allow.
        if let response = try? JSONDecoder().decode(TeamsPairingResponse.self, from: data),
           let token = response.effectiveToken, !token.isEmpty {
            pairingToken = token
            markConnected()
            logger.info("Pairing token received and stored")
            return
        }

        // 3. MeetingUpdate — meeting state and/or permissions push.
        //    Receiving this means Teams considers us paired (either the user just
        //    approved, or we reconnected with a stored token).
        if let teamsMessage = try? JSONDecoder().decode(TeamsMessage.self, from: data),
           let update = teamsMessage.meetingUpdate {
            markConnected()
            if let state = update.meetingState {
                isInCall = state.isInMeeting
                isMuted = state.isMuted
                if !isInCall {
                    isMuted = true
                }
                logger.info("Meeting state: inCall=\(self.isInCall), muted=\(self.isMuted)")
            } else {
                logger.info("Meeting update (permissions only, no state)")
            }
            return
        }

        logger.info("Unhandled message: \(text)")
    }

    /// Transition to `.connected` if not already there.
    private func markConnected() {
        guard connectionState != .connected else { return }
        connectionState = .connected
        currentBackoff = 1.0
        logger.info("Connected to Teams")
    }

    // MARK: - Reconnection

    private func handleDisconnection(error: Error) {
        logger.warning("Disconnected: \(error.localizedDescription)")
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        // If we were still pairing when disconnected, the token was likely rejected
        if connectionState == .pairing, pairingToken != nil {
            logger.warning("Token likely rejected — clearing for fresh pairing")
            pairingToken = nil
        }

        // Detect connection refused — Teams might not be running
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 61 {
            connectionState = .error("Teams not running")
        } else if nsError.domain == "kNWErrorDomainPOSIX" && nsError.code == 61 {
            connectionState = .error("Teams not running")
        } else {
            connectionState = .disconnected
        }

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let delay = currentBackoff
        currentBackoff = min(currentBackoff * 2, maxBackoff)
        logger.info("Reconnecting in \(delay)s...")

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.connectionState = .disconnected  // ensure we can reconnect
            self.connect()
        }
    }
}
