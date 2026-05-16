import Foundation

// MARK: - Inbound Messages

/// Top-level wrapper for all messages received from the Teams WebSocket.
struct TeamsMessage: Codable, Sendable {
    let apiVersion: String?
    let meetingUpdate: MeetingUpdate?
}

/// Contains the current meeting state and/or permissions.
struct MeetingUpdate: Codable, Sendable {
    let meetingState: MeetingState?
    let meetingPermissions: MeetingPermissions?
}

/// Snapshot of the current meeting state. Only `isInMeeting` and `isMuted` are guaranteed.
struct MeetingState: Codable, Sendable {
    let isInMeeting: Bool
    let isMuted: Bool
    let isVideoOn: Bool?
    let isHandRaised: Bool?
    let isInLargeGallery: Bool?
    let isBackgroundBlurred: Bool?
    let isSharing: Bool?
    let hasUnreadMessages: Bool?
    let isRecordingOn: Bool?
}

/// Permissions the paired device is allowed to exercise.
struct MeetingPermissions: Codable, Sendable {
    let canPair: Bool?
    let canToggleMute: Bool?
    let canToggleHand: Bool?
    let canToggleVideo: Bool?
    let canToggleBlur: Bool?
    let canLeave: Bool?
    let canReact: Bool?
    let canToggleShareTray: Bool?
    let canToggleChat: Bool?
    let canStopSharing: Bool?
}

// MARK: - Connection Acknowledgment

/// Response sent by Teams after accepting the WebSocket upgrade.
/// Example: `{"response":"Success","requestId":0}`
struct TeamsHandshakeResponse: Codable, Sendable {
    let response: String
    let requestId: Int?
}

// MARK: - Pairing

/// Inbound pairing/token-refresh response from Teams.
struct TeamsPairingResponse: Codable, Sendable {
    let token: String?
    let tokenRefresh: String?

    /// Prefer `tokenRefresh`; fall back to `token`.
    var effectiveToken: String? {
        tokenRefresh ?? token
    }
}

/// Outbound pairing query parameters sent when opening the WebSocket.
struct TeamsPairingMessage: Codable, Sendable {
    let protocolVersion: String
    let token: String
    let manufacturer: String
    let device: String
    let app: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol-version"
        case token, manufacturer, device, app
        case appVersion = "app-version"
    }

    static func make(token: String) -> TeamsPairingMessage {
        TeamsPairingMessage(
            protocolVersion: "2.0.0",
            token: token,
            manufacturer: "alampros",
            device: "macOS",
            app: "OnAirCompanion",
            appVersion: "1.0.0"
        )
    }
}
