import Foundation

/// Combined application state derived from Teams and plugin connection status.
///
/// Used by the UI to show the current state of the user:
/// - `disconnected` — Teams or plugin not connected
/// - `idle` — Connected to both, not in a call
/// - `inCall` — In a call, muted
/// - `onAir` — In a call, unmuted (on air!)
enum AppState: Sendable, Equatable {
    case disconnected
    case idle
    case inCall
    case onAir
}
