import Foundation

/// A generic debounce utility that delays execution and cancels previous pending calls.
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?
    private let duration: Duration

    init(duration: Duration = .milliseconds(250)) {
        self.duration = duration
    }

    /// Schedule a debounced action. Cancels any previously scheduled action.
    func debounce(_ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
