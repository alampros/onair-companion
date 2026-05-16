import XCTest
@testable import OnAirCompanion

final class PluginMessageTests: XCTestCase {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - Client Messages (encode/decode round-trip)

    func testIdentifyRoundTrip() throws {
        let original = PluginClientMessage.identify(id: "aaron")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PluginClientMessage.self, from: data)

        guard case .identify(let id) = decoded else {
            return XCTFail("Expected .identify, got \(decoded)")
        }
        XCTAssertEqual(id, "aaron")
    }

    func testIdentifyJSON() throws {
        let message = PluginClientMessage.identify(id: "aaron")
        let data = try encoder.encode(message)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["type"] as? String, "identify")
        XCTAssertEqual(dict["id"] as? String, "aaron")
        XCTAssertEqual(dict.count, 2)
    }

    func testStatusRoundTrip() throws {
        let original = PluginClientMessage.status(onCall: true, muted: false)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PluginClientMessage.self, from: data)

        guard case .status(let onCall, let muted) = decoded else {
            return XCTFail("Expected .status, got \(decoded)")
        }
        XCTAssertTrue(onCall)
        XCTAssertFalse(muted)
    }

    func testStatusJSON() throws {
        let message = PluginClientMessage.status(onCall: true, muted: false)
        let data = try encoder.encode(message)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["type"] as? String, "status")
        XCTAssertEqual(dict["onCall"] as? Bool, true)
        XCTAssertEqual(dict["muted"] as? Bool, false)
        XCTAssertEqual(dict.count, 3)
    }

    func testPingRoundTrip() throws {
        let original = PluginClientMessage.ping
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(PluginClientMessage.self, from: data)

        guard case .ping = decoded else {
            return XCTFail("Expected .ping, got \(decoded)")
        }
    }

    func testPingJSON() throws {
        let message = PluginClientMessage.ping
        let data = try encoder.encode(message)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["type"] as? String, "ping")
        XCTAssertEqual(dict.count, 1)
    }

    // MARK: - Server Messages (decode)

    func testDecodeWelcome() throws {
        let json = """
        {"type":"welcome","version":"1"}
        """.data(using: .utf8)!

        let message = try decoder.decode(PluginServerMessage.self, from: json)
        guard case .welcome(let version) = message else {
            return XCTFail("Expected .welcome, got \(message)")
        }
        XCTAssertEqual(version, "1")
    }

    func testDecodeAck() throws {
        let json = """
        {"type":"ack"}
        """.data(using: .utf8)!

        let message = try decoder.decode(PluginServerMessage.self, from: json)
        guard case .ack = message else {
            return XCTFail("Expected .ack, got \(message)")
        }
    }

    func testDecodePong() throws {
        let json = """
        {"type":"pong"}
        """.data(using: .utf8)!

        let message = try decoder.decode(PluginServerMessage.self, from: json)
        guard case .pong = message else {
            return XCTFail("Expected .pong, got \(message)")
        }
    }

    func testDecodeError() throws {
        let json = """
        {"type":"error","message":"unknown occupant id"}
        """.data(using: .utf8)!

        let message = try decoder.decode(PluginServerMessage.self, from: json)
        guard case .error(let errorMessage) = message else {
            return XCTFail("Expected .error, got \(message)")
        }
        XCTAssertEqual(errorMessage, "unknown occupant id")
    }

    // MARK: - Server Messages (encode verification)

    func testEncodeWelcomeJSON() throws {
        let message = PluginServerMessage.welcome(version: "1")
        let data = try encoder.encode(message)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["type"] as? String, "welcome")
        XCTAssertEqual(dict["version"] as? String, "1")
        XCTAssertEqual(dict.count, 2)
    }

    func testEncodeErrorJSON() throws {
        let message = PluginServerMessage.error(message: "must identify first")
        let data = try encoder.encode(message)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["type"] as? String, "error")
        XCTAssertEqual(dict["message"] as? String, "must identify first")
        XCTAssertEqual(dict.count, 2)
    }

    // MARK: - Unknown Type Handling

    func testUnknownClientMessageTypeThrows() {
        let json = """
        {"type":"unknown"}
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try decoder.decode(PluginClientMessage.self, from: json)
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
            }
        }
    }

    func testUnknownServerMessageTypeThrows() {
        let json = """
        {"type":"unknown"}
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try decoder.decode(PluginServerMessage.self, from: json)
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected DecodingError.dataCorrupted, got \(error)")
            }
        }
    }
}
