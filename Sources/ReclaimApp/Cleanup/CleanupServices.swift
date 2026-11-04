import Foundation
import Synchronization
import StorageCore

/// Everything the cleanup flow needs, created once per app run. There is exactly one engine,
/// so a second execution while one runs is rejected by the engine itself.
struct CleanupServices: Sendable {
    let home: URL
    let engine: CleanupEngine
    let apps: any RunningAppChecking
    /// Configured like the scan's, so items are planned by the inspector that found them.
    let inspectors: [any Inspector]
    let log: CleanupLog
    private let setup: InspectorSetup

    @MainActor static func live(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CleanupServices {
        let setup = InspectorSetup.current(home: home)
        let apps = WorkspaceAppChecker()
        let log = CleanupLog.default
        // The policy looks tools up through `tools.locate`, so it accepts exactly the paths this
        // runner finds, the same paths the inspectors' planning context finds.
        let engine = CleanupEngine(
            validator: PathValidator(home: home),
            tools: setup.toolRunner(),
            apps: apps,
            files: RealFileOperations(),
            sizer: ScannerSizer(),
            log: log,
            policy: ToolPolicy(home: home),
            freeSpace: FreeSpace.reader())
        return CleanupServices(home: home, engine: engine, apps: apps, inspectors: setup.inspectors, log: log,
                               setup: setup)
    }

    /// A fresh context for planning (file identities and sizes are read now, not at scan time).
    func planningContext() -> InspectorContext {
        InspectorContext(home: home, tools: setup.toolRunner(), sizer: ScannerSizer())
    }

    /// Newest first. Throws when the log exists but can't be read; the History view shows why.
    func readHistory() throws -> [LogEntry] {
        try log.readAll().sorted { $0.date > $1.date }
    }
}

/// Available space for measuring what a tool step freed (before vs. after).
enum FreeSpace {
    /// A failed read returns the last good value, never 0: a 0 "before" would make the whole
    /// free space look like it was freed by the step.
    static func reader() -> @Sendable () -> Int64 {
        let last = Mutex<Int64>((try? VolumeInfo.availableBytes()) ?? 0)
        return {
            if let now = try? VolumeInfo.availableBytes() {
                last.withLock { $0 = now }
                return now
            }
            return last.withLock { $0 }
        }
    }
}
