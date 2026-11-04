import StorageCore
import Synchronization

/// A `RunningAppChecking` driven by a set of running bundle IDs and process names.
public final class FakeAppChecker: RunningAppChecking {
    private struct State {
        var running: Set<String>
        var quitSucceeds: Bool
    }

    private let state: Mutex<State>

    public init(running: Set<String> = [], quitSucceeds: Bool = true) {
        state = Mutex(State(running: running, quitSucceeds: quitSucceeds))
    }

    /// Bundle IDs and process names that count as running.
    public var running: Set<String> {
        get { state.withLock { $0.running } }
        set { state.withLock { $0.running = newValue } }
    }

    /// When true, `requestQuit` removes the bundle IDs from `running` and returns true.
    public var quitSucceeds: Bool {
        get { state.withLock { $0.quitSucceeds } }
        set { state.withLock { $0.quitSucceeds = newValue } }
    }

    public func isRunning(bundleIDs: [String], processNames: [String]) async -> Bool {
        let running = self.running
        return (bundleIDs + processNames).contains { running.contains($0) }
    }

    public func requestQuit(bundleIDs: [String]) async -> Bool {
        state.withLock { state in
            guard state.quitSucceeds else { return false }
            state.running.subtract(bundleIDs)
            return true
        }
    }
}
