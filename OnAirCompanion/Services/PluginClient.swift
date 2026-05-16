import Foundation
import os

/// Connection state for the plugin WebSocket.
enum PluginConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case identifying
    case connected
    case error(String)
}

/// Manages the WebSocket connection to the homebridge-onair plugin.
///
/// Connects to the plugin's WebSocket server, identifies with an occupant ID,
/// sends periodic status updates reflecting Teams meeting state, and maintains
/// a keep-alive ping every 5 seconds (server stale timeout is 15s).
@Observable @MainActor
final class PluginClient {
    private(set) var connectionState: PluginConnectionState = .disconnected

    private var occupantId: String = ""
    private var serverURL: URL?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var currentBackoff: TimeInterval = 1.0
    private let maxBackoff: TimeInterval = 30.0
    private let logger = Logger(subsystem: "com.alampros.OnAirCompanion", category: "PluginClient")

    // MARK: - Public API

    /// Connect to the homebridge-onair plugin WebSocket.
    /// - Parameters:
    ///   - url: WebSocket URL of the plugin server.
    ///   - occupantId: Configured occupant ID to identify with.
    func connect(to url: URL, occupantId: String) {
        // Don't reconnect if already connected or connecting
        switch connectionState {
        case .connecting, .identifying, .connected:
            logger.debug("Already connected/connecting — skipping connect()")
            return
        case .disconnected, .error:
            break
        }

        self.serverURL = url
        self.occupantId = occupantId

        // Cancel any lingering state
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        connectionState = .connecting
        logger.info("Connecting to plugin at \(url.absoluteString)...")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        urlSession = session
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        // Must send identify as the very first message (server requirement)
        connectionState = .identifying
        sendIdentify()
        startReceiveLoop()
    }

    /// Send current Teams meeting state to the plugin.
    /// - Parameters:
    ///   - onCall: Whether the user is currently in a call.
    ///   - muted: Whether the user is currently muted.
    func sendStatus(onCall: Bool, muted: Bool) {
        guard connectionState == .connected else {
            logger.debug("Not connected — skipping sendStatus")
            return
        }
        send(.status(onCall: onCall, muted: muted))
    }

    /// Disconnect and stop reconnection.
    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connectionState = .disconnected
    }

    // MARK: - Send

    private func sendIdentify() {
        send(.identify(id: occupantId))
    }

    private func send(_ message: PluginClientMessage) {
        guard let ws = webSocketTask else { return }
        do {
            let data = try JSONEncoder().encode(message)
            guard let text = String(data: data, encoding: .utf8) else { return }
            ws.send(.string(text)) { [weak self] error in
                if let error {
                    Task { @MainActor [weak self] in
                        self?.logger.warning("Send failed: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            logger.error("Failed to encode message: \(error.localizedDescription)")
        }
    }

    // MARK: - Ping Timer

    private func startPingTimer() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { break }
                guard self.connectionState == .connected else { break }
                self.send(.ping)
            }
        }
    }

    private func stopPingTimer() {
        pingTask?.cancel()
        pingTask = nil
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

        do {
            let serverMessage = try JSONDecoder().decode(PluginServerMessage.self, from: data)
            switch serverMessage {
            case .welcome(let version):
                logger.info("Welcome received (version \(version))")
                connectionState = .connected
                currentBackoff = 1.0
                startPingTimer()

            case .ack:
                logger.debug("Status acknowledged")

            case .pong:
                logger.debug("Pong received")

            case .error(let message):
                logger.error("Server error: \(message)")
                // Don't proactively disconnect — let the server decide.
                // If the server closes the connection, the receive loop will
                // catch the close and trigger reconnection automatically.
            }
        } catch {
            logger.warning("Failed to decode server message: \(error.localizedDescription)")
        }
    }

    // MARK: - Reconnection

    private func handleDisconnection(error: Error) {
        logger.warning("Disconnected: \(error.localizedDescription)")
        webSocketTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        stopPingTimer()

        connectionState = .disconnected
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard let url = serverURL else { return }

        let delay = currentBackoff
        currentBackoff = min(currentBackoff * 2, maxBackoff)
        logger.info("Reconnecting in \(delay)s...")

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.connectionState = .disconnected  // ensure we can reconnect
            self.connect(to: url, occupantId: self.occupantId)
        }
    }
}
