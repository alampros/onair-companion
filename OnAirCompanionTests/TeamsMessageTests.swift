import XCTest
@testable import OnAirCompanion

final class TeamsMessageTests: XCTestCase {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - Meeting State

    func testDecodeMeetingStateUpdate() throws {
        let json = """
        {
            "apiVersion": "2.0.0",
            "meetingUpdate": {
                "meetingState": {
                    "isInMeeting": true,
                    "isMuted": false,
                    "isVideoOn": true,
                    "isHandRaised": false,
                    "isInLargeGallery": false,
                    "isBackgroundBlurred": false,
                    "isSharing": false,
                    "hasUnreadMessages": false,
                    "isRecordingOn": false
                },
                "meetingPermissions": {
                    "canToggleMute": true,
                    "canToggleVideo": true,
                    "canToggleHand": true,
                    "canToggleBlur": true,
                    "canLeave": true,
                    "canReact": true,
                    "canToggleShareTray": true,
                    "canToggleChat": true,
                    "canStopSharing": true,
                    "canPair": true
                }
            }
        }
        """.data(using: .utf8)!

        let message = try decoder.decode(TeamsMessage.self, from: json)
        XCTAssertEqual(message.apiVersion, "2.0.0")

        let update = try XCTUnwrap(message.meetingUpdate)
        let state = try XCTUnwrap(update.meetingState)

        XCTAssertTrue(state.isInMeeting)
        XCTAssertFalse(state.isMuted)
        XCTAssertEqual(state.isVideoOn, true)
        XCTAssertEqual(state.isHandRaised, false)
        XCTAssertEqual(state.isInLargeGallery, false)
        XCTAssertEqual(state.isBackgroundBlurred, false)
        XCTAssertEqual(state.isSharing, false)
        XCTAssertEqual(state.hasUnreadMessages, false)
        XCTAssertEqual(state.isRecordingOn, false)

        let permissions = try XCTUnwrap(update.meetingPermissions)
        XCTAssertEqual(permissions.canToggleMute, true)
        XCTAssertEqual(permissions.canToggleVideo, true)
        XCTAssertEqual(permissions.canToggleHand, true)
        XCTAssertEqual(permissions.canToggleBlur, true)
        XCTAssertEqual(permissions.canLeave, true)
        XCTAssertEqual(permissions.canReact, true)
        XCTAssertEqual(permissions.canToggleShareTray, true)
        XCTAssertEqual(permissions.canToggleChat, true)
        XCTAssertEqual(permissions.canStopSharing, true)
        XCTAssertEqual(permissions.canPair, true)
    }

    func testDecodeMinimalMeetingState() throws {
        let json = """
        {
            "apiVersion": "2.0.0",
            "meetingUpdate": {
                "meetingState": {
                    "isInMeeting": true,
                    "isMuted": true
                }
            }
        }
        """.data(using: .utf8)!

        let message = try decoder.decode(TeamsMessage.self, from: json)
        let state = try XCTUnwrap(message.meetingUpdate?.meetingState)

        XCTAssertTrue(state.isInMeeting)
        XCTAssertTrue(state.isMuted)
        XCTAssertNil(state.isVideoOn)
        XCTAssertNil(state.isHandRaised)
        XCTAssertNil(state.isInLargeGallery)
        XCTAssertNil(state.isBackgroundBlurred)
        XCTAssertNil(state.isSharing)
        XCTAssertNil(state.hasUnreadMessages)
        XCTAssertNil(state.isRecordingOn)
    }

    // MARK: - Meeting Permissions

    func testDecodeMeetingPermissions() throws {
        let json = """
        {
            "apiVersion": "2.0.0",
            "meetingUpdate": {
                "meetingPermissions": {
                    "canToggleMute": true,
                    "canToggleVideo": false,
                    "canToggleHand": true,
                    "canToggleBlur": false,
                    "canLeave": true,
                    "canReact": true,
                    "canToggleShareTray": false,
                    "canToggleChat": true,
                    "canStopSharing": false,
                    "canPair": true
                }
            }
        }
        """.data(using: .utf8)!

        let message = try decoder.decode(TeamsMessage.self, from: json)
        let update = try XCTUnwrap(message.meetingUpdate)

        XCTAssertNil(update.meetingState)

        let permissions = try XCTUnwrap(update.meetingPermissions)
        XCTAssertEqual(permissions.canToggleMute, true)
        XCTAssertEqual(permissions.canToggleVideo, false)
        XCTAssertEqual(permissions.canToggleHand, true)
        XCTAssertEqual(permissions.canToggleBlur, false)
        XCTAssertEqual(permissions.canLeave, true)
        XCTAssertEqual(permissions.canReact, true)
        XCTAssertEqual(permissions.canToggleShareTray, false)
        XCTAssertEqual(permissions.canToggleChat, true)
        XCTAssertEqual(permissions.canStopSharing, false)
        XCTAssertEqual(permissions.canPair, true)
    }

    // MARK: - Pairing Response

    func testDecodePairingResponseWithTokenRefresh() throws {
        let json = """
        {
            "tokenRefresh": "new-token-123",
            "token": "old-token"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(TeamsPairingResponse.self, from: json)
        XCTAssertEqual(response.tokenRefresh, "new-token-123")
        XCTAssertEqual(response.token, "old-token")
    }

    func testEffectiveTokenPrefersTokenRefresh() throws {
        let json = """
        {
            "tokenRefresh": "new-token-123",
            "token": "old-token"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(TeamsPairingResponse.self, from: json)
        XCTAssertEqual(response.effectiveToken, "new-token-123")
    }

    func testEffectiveTokenFallsToToken() throws {
        let json = """
        {
            "token": "only-token"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(TeamsPairingResponse.self, from: json)
        XCTAssertNil(response.tokenRefresh)
        XCTAssertEqual(response.effectiveToken, "only-token")
    }

    // MARK: - Pairing Message

    func testPairingMessageCodingKeys() throws {
        let message = TeamsPairingMessage.make(token: "test-token")
        let data = try encoder.encode(message)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(dict["protocol-version"], "2.0.0")
        XCTAssertEqual(dict["app-version"], "1.0.0")
        XCTAssertEqual(dict["token"], "test-token")
        XCTAssertEqual(dict["manufacturer"], "alampros")
        XCTAssertEqual(dict["device"], "macOS")
        XCTAssertEqual(dict["app"], "OnAirCompanion")
    }

    func testPairingMessageMake() {
        let message = TeamsPairingMessage.make(token: "abc")

        XCTAssertEqual(message.protocolVersion, "2.0.0")
        XCTAssertEqual(message.token, "abc")
        XCTAssertEqual(message.manufacturer, "alampros")
        XCTAssertEqual(message.device, "macOS")
        XCTAssertEqual(message.app, "OnAirCompanion")
        XCTAssertEqual(message.appVersion, "1.0.0")
    }
}
