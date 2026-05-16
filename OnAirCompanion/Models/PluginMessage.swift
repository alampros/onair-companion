import Foundation

// MARK: - Client → Server

/// Messages sent from the companion app to the homebridge-onair plugin.
enum PluginClientMessage: Codable, Sendable {
    /// First message after connecting; associates this client with a configured occupant.
    case identify(id: String)
    /// Periodic status update reflecting the current Teams meeting state.
    case status(onCall: Bool, muted: Bool)
    /// Keep-alive ping; expects a `.pong` response.
    case ping

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, id, onCall, muted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "identify":
            let id = try container.decode(String.self, forKey: .id)
            self = .identify(id: id)
        case "status":
            let onCall = try container.decode(Bool.self, forKey: .onCall)
            let muted = try container.decode(Bool.self, forKey: .muted)
            self = .status(onCall: onCall, muted: muted)
        case "ping":
            self = .ping
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown client message type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .identify(let id):
            try container.encode("identify", forKey: .type)
            try container.encode(id, forKey: .id)
        case .status(let onCall, let muted):
            try container.encode("status", forKey: .type)
            try container.encode(onCall, forKey: .onCall)
            try container.encode(muted, forKey: .muted)
        case .ping:
            try container.encode("ping", forKey: .type)
        }
    }
}

// MARK: - Server → Client

/// Messages received from the homebridge-onair plugin.
enum PluginServerMessage: Codable, Sendable {
    /// Sent after a successful identify handshake.
    case welcome(version: String)
    /// Acknowledgement of a received status update.
    case ack
    /// Response to a ping.
    case pong
    /// An error reported by the server.
    case error(message: String)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, version, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            let version = try container.decode(String.self, forKey: .version)
            self = .welcome(version: version)
        case "ack":
            self = .ack
        case "pong":
            self = .pong
        case "error":
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message: message)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown server message type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .welcome(let version):
            try container.encode("welcome", forKey: .type)
            try container.encode(version, forKey: .version)
        case .ack:
            try container.encode("ack", forKey: .type)
        case .pong:
            try container.encode("pong", forKey: .type)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}
