# AGENTS.md

## Project

macOS menubar-only app (SwiftUI, Swift 6 strict concurrency) that monitors Microsoft Teams meeting status via a local WebSocket API and forwards it to [homebridge-onair](https://github.com/alampros/homebridge-onair) plugin servers discovered via Bonjour/mDNS. No third-party dependencies -- Apple frameworks only.

**Requires macOS 15+ (Sequoia).**

## Build & test

```sh
# Build
xcodebuild -project OnAirCompanion.xcodeproj -scheme OnAirCompanion build

# Run tests
xcodebuild test -project OnAirCompanion.xcodeproj -scheme OnAirCompanion -destination 'platform=macOS'
```

- Build output goes to `dist/` (configured via `BUILD_DIR` in project settings, gitignored).
- Code signing is ad-hoc (`-`), no team provisioning needed.
- The Xcode MCP bridge is available (`opencode.json` enables `xcrun mcpbridge`). Prefer it for builds and tests when Xcode is open.

## Architecture

Single-scheme, two-target Xcode project (no SPM):

| Target | Purpose |
|---|---|
| `OnAirCompanion` | macOS app (`LSUIElement = true` -- no dock icon) |
| `OnAirCompanionTests` | Unit tests (hosted in the app) |

### Key services (`OnAirCompanion/Services/`)

- **`AppCoordinator`** -- owns all services, handles sleep/wake, network changes, 250ms debounce + duplicate suppression before forwarding state to plugin.
- **`TeamsMonitor`** -- WebSocket to `ws://127.0.0.1:8124/` (must be `127.0.0.1`, not `localhost` -- Teams binds IPv4 only). Token-based pairing stored in UserDefaults.
- **`PluginClient`** -- WebSocket to discovered plugin server. Sends `identify` on connect, pings every 5s (server stale timeout is 15s).
- **`ServerDiscovery`** -- `NWBrowser` for `_onair._tcp` Bonjour. Falls back to manual URI from UserDefaults.

### Concurrency model

All service classes are `@MainActor @Observable`. All model types are `Sendable`. Observation uses `withObservationTracking` loops, not Combine.

### UserDefaults keys

`"occupantId"`, `"pluginURI"`, `"teamsPairingToken"`

### Logging

`os.Logger` with subsystem `"com.alampros.OnAirCompanion"` and per-service categories.

## Conventions

- No linter or formatter is configured.
- Protocol messages use manual `Codable` with a `"type"` discriminator key (see `PluginMessage.swift`, `TeamsMessage.swift`).
- `docs/PLAN.md` has the full architecture plan, protocol specs, and Mermaid state diagrams.
