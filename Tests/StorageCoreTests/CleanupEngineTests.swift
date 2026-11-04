import Foundation
import Synchronization
import Testing
import StorageCore
import StorageTestKit

/// A `PathValidating` that delegates to a closure. The default accepts every path unchanged.
private struct ClosureValidator: PathValidating {
    let body: @Sendable (String, FileID?) throws(SafetyViolation) -> String

    init(_ body: @escaping @Sendable (String, FileID?) throws(SafetyViolation) -> String = { path, _ in path }) {
        self.body = body
    }

    func validate(_ path: String, expectedFileID: FileID?) throws(SafetyViolation) -> String {
        try body(path, expectedFileID)
    }
}

private struct InjectedFailure: Error {}

/// Real file operations on temp dirs, except `trash`, which moves into a fixture "Trash" folder.
private final class FakeTrashFileOps: FileOperating {
    private struct Options {
        var failRemove = false
        var failTrash = false
        var onTrash: (@Sendable (String) -> Void)?
    }

    let trashDir: URL
    private let trashedPaths = Mutex<[String]>([])
    private let options = Mutex(Options())
    private let real = RealFileOperations()

    init(trashDir: URL) throws {
        self.trashDir = trashDir
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    var trashed: [String] { trashedPaths.withLock { $0 } }
    var failRemove: Bool {
        get { options.withLock { $0.failRemove } }
        set { options.withLock { $0.failRemove = newValue } }
    }
    var failTrash: Bool {
        get { options.withLock { $0.failTrash } }
        set { options.withLock { $0.failTrash = newValue } }
    }
    /// Runs after an item was moved to the fake trash, with the trashed location.
    var onTrash: (@Sendable (String) -> Void)? {
        get { options.withLock { $0.onTrash } }
        set { options.withLock { $0.onTrash = newValue } }
    }

    func remove(_ path: String) throws {
        if failRemove { throw InjectedFailure() }
        try real.remove(path)
    }

    func trash(_ path: String) throws -> String {
        if failTrash { throw InjectedFailure() }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let destination = trashDir.appendingPathComponent("\(UUID().uuidString)-\(name)").path
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        trashedPaths.withLock { $0.append(destination) }
        onTrash?(destination)
        return destination
    }

    func read(_ path: String) throws -> Data { try real.read(path) }
    func write(_ data: Data, to path: String) throws { try real.write(data, to: path) }
}

/// Returns the queued values in order, then repeats the last one.
private final class FreeSpaceSequence: Sendable {
    private let values: Mutex<[Int64]>
    init(_ values: [Int64]) { self.values = Mutex(values) }
    func next() -> Int64 {
        values.withLock { values in
            values.count > 1 ? values.removeFirst() : (values.first ?? 0)
        }
    }
}

/// Runs `onMeasure` (e.g. to swap the path) while measuring, then measures with `LogicalSizer`.
private struct HookedSizer: SizeMeasuring {
    let onMeasure: @Sendable (String) -> Void
    func allocatedSize(of path: String) async -> Int64 {
        onMeasure(path)
        return await LogicalSizer().allocatedSize(of: path)
    }
}

/// Suspends every measurement until `release()`; `entered` yields once per measurement.
private final class GatedSizer: SizeMeasuring {
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (entered, enteredContinuation) = AsyncStream.makeStream()
        (released, releaseContinuation) = AsyncStream.makeStream()
    }

    func release() { releaseContinuation.finish() }

    func allocatedSize(of path: String) async -> Int64 {
        enteredContinuation.yield()
        for await _ in released {}
        return await LogicalSizer().allocatedSize(of: path)
    }

    func waitUntilEntered() async {
        for await _ in entered { return }
    }
}

/// Wraps a `FakeToolRunner`: every run waits until `release()`. Like `ProcessToolRunner`, a run
/// whose task is cancelled meanwhile is abandoned (the real runner kills the process) and throws.
private final class GatedToolRunner: ToolRunning {
    let fake: FakeToolRunner
    private let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init(_ fake: FakeToolRunner) {
        self.fake = fake
        (entered, enteredContinuation) = AsyncStream.makeStream()
        (released, releaseContinuation) = AsyncStream.makeStream()
    }

    func release() { releaseContinuation.finish() }

    func waitUntilEntered() async {
        for await _ in entered { return }
    }

    func locate(_ name: String) -> String? { fake.locate(name) }

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> ToolOutput {
        enteredContinuation.yield()
        for await _ in released {}  // Ends early when the calling task is cancelled.
        try Task.checkCancellation()
        return try await fake.run(executable, arguments, timeout: timeout)
    }
}

/// Accepts every path, but rejects the given one with the given violation.
private func rejecting(_ match: @escaping @Sendable (String) -> Bool) -> ClosureValidator {
    ClosureValidator { path, _ throws(SafetyViolation) in
        if match(path) { throw .outsideAllowedRoots(path) }
        return path
    }
}

/// Rejects a path whose current identity differs from the expected one.
private let identityValidator = ClosureValidator { path, expected throws(SafetyViolation) in
    if let expected, FileID.of(path: path) != expected { throw .identityChanged(path) }
    return path
}

/// Where the fake tool runner finds each tool, as `ToolLocator` would.
private let locatedTools = [
    "docker": "/usr/local/bin/docker", "xcrun": "/usr/bin/xcrun", "go": "/opt/go", "rustup": "/opt/rustup",
]

/// Chrome's support folder, relative to the fixture home: `ToolPolicy` only allows JSON edits to
/// its `Local State`.
private let chrome = "Library/Application Support/Google/Chrome"

private struct Harness {
    let fixture: FixtureHome
    let files: FakeTrashFileOps
    let tools: FakeToolRunner
    let apps: FakeAppChecker
    let log: CleanupLog
    let engine: CleanupEngine

    init(
        validator: any PathValidating = ClosureValidator(),
        running: Set<String> = [],
        freeSpace: FreeSpaceSequence = FreeSpaceSequence([0]),
        sizer: any SizeMeasuring = LogicalSizer(),
        logRelativePath: String = "log/cleanup-log.jsonl",
        fixture: FixtureHome? = nil,
        apps: FakeAppChecker? = nil
    ) throws {
        let fixture = try fixture ?? FixtureHome()
        let files = try FakeTrashFileOps(trashDir: fixture.home.appendingPathComponent("FakeTrash"))
        let tools = FakeToolRunner(tools: locatedTools)
        let apps = apps ?? FakeAppChecker(running: running)
        let log = CleanupLog(fileURL: fixture.home.appendingPathComponent(logRelativePath))
        self.fixture = fixture
        self.files = files
        self.tools = tools
        self.apps = apps
        self.log = log
        self.engine = CleanupEngine(
            validator: validator, tools: tools, apps: apps, files: files,
            sizer: sizer, log: log, policy: ToolPolicy(home: fixture.home), freeSpace: { freeSpace.next() }
        )
    }

    func path(_ relative: String) -> String { fixture.home.path + "/" + relative }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path(relative)) }
}

private func step(
    _ title: String = "Step",
    risk: RiskLevel,
    requirement: AppStateRequirement = .none,
    _ action: CleanupAction
) -> CleanupStep {
    CleanupStep(title: title, risk: risk, estimatedBytes: 0, requirement: requirement, action: action)
}

private func jsonObject(at path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct CleanupEngineTests {
    @Test func userDataRequiresAck() async throws {
        let h = try Harness()
        try h.fixture.file("Docs/notes.txt", bytes: 500)
        let s = step(risk: .userData, .trash(path: h.path("Docs/notes.txt"), expectedFileID: nil))
        let plan = CleanupPlan(steps: [s])

        let blockers = await h.engine.preflight(plan, acknowledged: [])
        #expect(blockers[s.id] == [.needsAcknowledgement])

        let report = await h.engine.execute(plan, acknowledged: [])
        guard case .skipped = report.results[0].outcome else {
            Issue.record("expected skipped, got \(report.results[0].outcome)")
            return
        }
        #expect(h.exists("Docs/notes.txt"))
        #expect(h.files.trashed.isEmpty)
    }

    @Test func userDataDeleteBecomesTrash() async throws {
        let h = try Harness()
        try h.fixture.file("Docs/notes.txt", bytes: 500)
        let s = step(risk: .userData, .delete(path: h.path("Docs/notes.txt"), expectedFileID: nil))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        guard case .trashed(let bytes, let trashPath) = report.results[0].outcome else {
            Issue.record("expected trashed, got \(report.results[0].outcome)")
            return
        }
        #expect(bytes == 500)
        #expect(!h.exists("Docs/notes.txt"))
        #expect(FileManager.default.fileExists(atPath: trashPath))
        #expect(h.files.trashed == [trashPath])
        #expect(report.trashedBytes == 500)
        #expect(report.freedBytes == 0)
        let entry = try #require(try h.log.readAll().first)
        #expect(entry.action == .trash(path: h.path("Docs/notes.txt"), expectedFileID: nil))
    }

    @Test func cacheDeleted() async throws {
        let h = try Harness()
        try h.fixture.file("Library/Caches/com.x/blob", bytes: 4096)
        let s = step(risk: .cache, .delete(path: h.path("Library/Caches/com.x"), expectedFileID: nil))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        #expect(report.results[0].outcome == .freed(bytes: 4096))
        #expect(report.freedBytes == 4096)
        #expect(!h.exists("Library/Caches/com.x"))
        #expect(h.files.trashed.isEmpty)
    }

    @Test func appRunningBlocks() async throws {
        let h = try Harness(running: ["com.x"])
        try h.fixture.file("Library/Caches/com.x/blob", bytes: 100)
        let s = step(
            risk: .cache, requirement: .mustBeQuit(bundleIDs: ["com.x"], processNames: []),
            .delete(path: h.path("Library/Caches/com.x"), expectedFileID: nil)
        )
        let plan = CleanupPlan(steps: [s])

        let blockers = await h.engine.preflight(plan, acknowledged: [])[s.id] ?? []
        #expect(blockers.contains { if case .appRunning(_, let ids) = $0 { ids == ["com.x"] } else { false } })

        let report = await h.engine.execute(plan, acknowledged: [])
        guard case .skipped = report.results[0].outcome else {
            Issue.record("expected skipped, got \(report.results[0].outcome)")
            return
        }
        #expect(h.exists("Library/Caches/com.x/blob"))
    }

    /// Measuring can take minutes; an app launched meanwhile must still block the step.
    @Test func appLaunchedWhileMeasuringBlocks() async throws {
        let apps = FakeAppChecker()
        let sizer = HookedSizer { _ in apps.running = ["com.x"] }
        let h = try Harness(sizer: sizer, apps: apps)
        try h.fixture.file("Library/Caches/com.x/blob", bytes: 100)
        let s = step(
            risk: .cache, requirement: .mustBeQuit(bundleIDs: ["com.x"], processNames: []),
            .delete(path: h.path("Library/Caches/com.x"), expectedFileID: nil)
        )

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        guard case .skipped(let reason) = report.results[0].outcome else {
            Issue.record("expected skipped, got \(report.results[0].outcome)")
            return
        }
        #expect(reason.contains("com.x"))
        #expect(h.exists("Library/Caches/com.x/blob"))
    }

    @Test func mustBeRunningBlocks() async throws {
        let h = try Harness()
        let s = step(
            risk: .rebuildable,
            requirement: .mustBeRunning(bundleIDs: ["com.docker.docker"], processNames: ["Docker"], reason: "Docker must be running"),
            .runTool(executable: "/usr/local/bin/docker", arguments: ["builder", "prune", "-a", "-f"])
        )
        let plan = CleanupPlan(steps: [s])

        let blockers = await h.engine.preflight(plan, acknowledged: [])
        #expect(blockers[s.id] == [.appNotRunning(reason: "Docker must be running")])

        let report = await h.engine.execute(plan, acknowledged: [])
        #expect(report.results[0].outcome == .skipped(reason: "Docker must be running"))
        #expect(h.tools.invocations.isEmpty)
    }

    @Test func changedBetweenReviewAndExecute() async throws {
        let h = try Harness(validator: identityValidator)
        try h.fixture.file("Library/Caches/com.x/blob", bytes: 100)
        try h.fixture.file("Precious/data.bin", bytes: 300)
        let cachePath = h.path("Library/Caches/com.x")
        let s = step(risk: .cache, .delete(path: cachePath, expectedFileID: FileID.of(path: cachePath)))
        let plan = CleanupPlan(steps: [s])

        try FileManager.default.removeItem(atPath: cachePath)
        try h.fixture.symlink("Library/Caches/com.x", to: h.path("Precious"))

        let report = await h.engine.execute(plan, acknowledged: [])

        guard case .skipped = report.results[0].outcome else {
            Issue.record("expected skipped, got \(report.results[0].outcome)")
            return
        }
        #expect(h.exists("Precious/data.bin"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: cachePath)) == h.path("Precious"))
    }

    @Test func toolFailureReported() async throws {
        let h = try Harness()
        h.tools.stub("/usr/local/bin/docker", ["image", "prune", "-a", "-f"],
                     output: ToolOutput(exitCode: 1, stdout: "", stderr: "daemon not running\n"))
        let s = step(risk: .rebuildable, .runTool(executable: "/usr/local/bin/docker", arguments: ["image", "prune", "-a", "-f"]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        #expect(report.results[0].outcome == .failed(message: "daemon not running"))
    }

    @Test func toolSuccessMeasuresFreeSpace() async throws {
        let h = try Harness(freeSpace: FreeSpaceSequence([100, 600]))
        h.tools.stub("/usr/bin/xcrun", ["simctl", "delete", "unavailable"],
                     output: ToolOutput(exitCode: 0, stdout: "", stderr: ""))
        let s = step(risk: .rebuildable, .runTool(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        #expect(report.results[0].outcome == .freed(bytes: 500))
        #expect(h.tools.invocations.count == 1)
    }

    @Test func jsonKeysRemovedWithBackup() async throws {
        let h = try Harness()
        try h.fixture.json("\(chrome)/Local State", [
            "browser": ["enabled_labs_experiments": []],
            "profile": [
                "info_cache": [
                    "Default": ["name": "Person 1"],
                    "Profile 2": ["name": "Work"],
                    "Profile 3": ["name": "Old"],
                ],
                "last_used": "Default",
            ],
        ])
        let path = h.path("\(chrome)/Local State")
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let s = step(risk: .userData, .removeJSONKeys(path: path, edits: [.removeKey(["profile", "info_cache", "Profile 2"])]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        guard case .edited(let backupPath) = report.results[0].outcome else {
            Issue.record("expected edited, got \(report.results[0].outcome)")
            return
        }
        let root = try jsonObject(at: path)
        let profile = try #require(root["profile"] as? [String: Any])
        let cache = try #require(profile["info_cache"] as? [String: Any])
        #expect(Set(cache.keys) == ["Default", "Profile 3"])
        #expect(profile["last_used"] as? String == "Default")
        #expect(root["browser"] != nil)
        #expect(h.files.trashed == [backupPath])
        #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == original)
        #expect(report.freedBytes == 0)
        #expect(report.trashedBytes == 0)
        // The temporary sibling copy does not linger next to the original.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: h.path(chrome))
        #expect(siblings == ["Local State"])
    }

    @Test func jsonArrayValueRemoved() async throws {
        let h = try Harness()
        try h.fixture.json("\(chrome)/Local State", [
            "profile": ["profiles_order": ["Default", "Profile 2"], "last_used": "Default"],
        ])
        let path = h.path("\(chrome)/Local State")
        let s = step(risk: .userData, .removeJSONKeys(path: path, edits: [
            .removeArrayValue(keyPath: ["profile", "profiles_order"], value: "Profile 2"),
            .removeArrayValue(keyPath: ["profile", "last_active_profiles"], value: "Profile 2"),
            .removeKey(["profile", "info_cache", "Profile 9"]),
        ]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        guard case .edited = report.results[0].outcome else {
            Issue.record("expected edited, got \(report.results[0].outcome)")
            return
        }
        let profile = try #require(try jsonObject(at: path)["profile"] as? [String: Any])
        #expect(profile["profiles_order"] as? [String] == ["Default"])
        #expect(profile["last_used"] as? String == "Default")
    }

    @Test func jsonOnlyMissingKeysIsNoOp() async throws {
        let h = try Harness()
        try h.fixture.json("\(chrome)/Local State", ["profile": ["last_used": "Default"]])
        let path = h.path("\(chrome)/Local State")
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let s = step(risk: .userData, .removeJSONKeys(path: path, edits: [.removeKey(["profile", "info_cache", "Profile 9"])]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        #expect(report.results[0].outcome == .skipped(reason: "Nothing to remove"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        #expect(h.files.trashed.isEmpty)
    }

    @Test func jsonParseFailureLeavesFileUntouched() async throws {
        let h = try Harness()
        try h.fixture.file("\(chrome)/Local State", bytes: 64)  // "aaaa…", not JSON
        let path = h.path("\(chrome)/Local State")
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let s = step(risk: .userData, .removeJSONKeys(path: path, edits: [.removeKey(["profile", "info_cache", "Profile 2"])]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        guard case .failed = report.results[0].outcome else {
            Issue.record("expected failed, got \(report.results[0].outcome)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        #expect(h.files.trashed.isEmpty)
    }

    @Test func everyStepLogged() async throws {
        let h = try Harness(running: ["com.y"])
        try h.fixture.file("Library/Caches/com.x/blob", bytes: 10)
        try h.fixture.file("Library/Caches/com.y/blob", bytes: 10)
        try h.fixture.file("Docs/old.txt", bytes: 10)
        let steps = [
            step("A", risk: .cache, .delete(path: h.path("Library/Caches/com.x"), expectedFileID: nil)),
            step("B", risk: .cache, requirement: .mustBeQuit(bundleIDs: ["com.y"], processNames: []),
                 .delete(path: h.path("Library/Caches/com.y"), expectedFileID: nil)),
            step("C", risk: .userData, .trash(path: h.path("Docs/old.txt"), expectedFileID: nil)),
        ]

        let report = await h.engine.execute(CleanupPlan(steps: steps), acknowledged: [steps[2].id])

        let entries = try h.log.readAll()
        #expect(entries.count == 3)
        #expect(entries.map(\.title) == ["A", "B", "C"])
        #expect(entries.map(\.outcome) == report.results.map(\.outcome))
        #expect(entries[2].risk == .userData)
        guard case .skipped = entries[1].outcome else {
            Issue.record("expected B skipped, got \(entries[1].outcome)")
            return
        }
    }

    @Test func invalidPathBlocksInPreflight() async throws {
        let validator = ClosureValidator { path, _ throws(SafetyViolation) in throw .protected(path) }
        let h = try Harness(validator: validator)
        try h.fixture.file("Library/Keychains/login.keychain-db", bytes: 10)
        let s = step(risk: .cache, .delete(path: h.path("Library/Keychains"), expectedFileID: nil))
        let plan = CleanupPlan(steps: [s])

        let blockers = await h.engine.preflight(plan, acknowledged: [])
        #expect(blockers[s.id] == [.invalidPath(.protected(h.path("Library/Keychains")))])

        let report = await h.engine.execute(plan, acknowledged: [])
        guard case .skipped = report.results[0].outcome else {
            Issue.record("expected skipped, got \(report.results[0].outcome)")
            return
        }
        #expect(h.exists("Library/Keychains/login.keychain-db"))
    }

    @Test func relativeToolPathRejected() async throws {
        let h = try Harness()
        let s = step(risk: .cache, .runTool(executable: "docker", arguments: ["system", "prune"]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        guard case .skipped = report.results[0].outcome else {
            Issue.record("expected skipped, got \(report.results[0].outcome)")
            return
        }
        #expect(h.tools.invocations.isEmpty)
    }

    @Test func logRoundTripsAndMissingFileIsEmpty() throws {
        let fixture = try FixtureHome()
        let log = CleanupLog(fileURL: fixture.home.appendingPathComponent("a/b/log.jsonl"))
        #expect(try log.readAll().isEmpty)
        let entry = LogEntry(
            id: UUID(), date: Date(timeIntervalSince1970: 1_800_000_000), title: "T",
            action: .runTool(executable: "/usr/bin/true", arguments: []), risk: .rebuildable,
            outcome: .trashed(bytes: 5, trashPath: "/x")
        )
        try log.append(entry)
        try log.append(entry)
        let read = try log.readAll()
        #expect(read.count == 2)
        #expect(read[0].id == entry.id)
        #expect(read[0].date == entry.date)
        #expect(read[0].outcome == entry.outcome)
        #expect(read[0].action == entry.action)
    }

    @Test func defaultLogPointsAtApplicationSupport() {
        #expect(CleanupLog.default.fileURL.path.hasSuffix("/Library/Application Support/Reclaim/cleanup-log.jsonl"))
    }

    @Test func realFileOperationsOnTempDir() throws {
        let fixture = try FixtureHome()
        let ops = RealFileOperations()
        let path = fixture.home.path + "/f.json"
        try ops.write(Data("{}".utf8), to: path)
        #expect(try ops.read(path) == Data("{}".utf8))
        try ops.write(Data("[]".utf8), to: path)
        #expect(try ops.read(path) == Data("[]".utf8))
        try fixture.symlink("link", to: path)
        try ops.remove(fixture.home.path + "/link")
        #expect(FileManager.default.fileExists(atPath: path))
        try ops.remove(path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Races, cancellation and failures

    @Test func pathSwappedWhileMeasuringIsSkipped() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/com.x/blob", bytes: 100)
        try fixture.file("Precious/data.bin", bytes: 300)
        let cachePath = fixture.home.path + "/Library/Caches/com.x"
        let precious = fixture.home.path + "/Precious"
        let sizer = HookedSizer { path in
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: precious)
        }
        let h = try Harness(validator: identityValidator, sizer: sizer, fixture: fixture)
        let s = step(risk: .cache, .delete(path: cachePath, expectedFileID: FileID.of(path: cachePath)))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        guard case .skipped = report.results[0].outcome else {
            Issue.record("expected skipped, got \(report.results[0].outcome)")
            return
        }
        #expect(h.exists("Precious/data.bin"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: cachePath)) == precious)
    }

    @Test func logFailureSurfacedAndExecutionContinues() async throws {
        let fixture = try FixtureHome()
        try fixture.file("not-a-directory", bytes: 1)
        try fixture.file("Library/Caches/com.x/blob", bytes: 10)
        let h = try Harness(logRelativePath: "not-a-directory/cleanup-log.jsonl", fixture: fixture)
        let steps = [
            step("A", risk: .cache, .delete(path: h.path("Library/Caches/com.x"), expectedFileID: nil)),
            step("B", risk: .userData, .trash(path: h.path("Docs/missing"), expectedFileID: nil)),
        ]

        let report = await h.engine.execute(CleanupPlan(steps: steps), acknowledged: [])

        #expect(report.results[0].outcome == .freed(bytes: 10))
        #expect(report.results.count == 2)
        #expect(report.logFailures.count == 2)
        #expect(report.logFailures.allSatisfy { !$0.isEmpty })
    }

    @Test(.timeLimit(.minutes(1))) func concurrentExecuteIsRejected() async throws {
        let sizer = GatedSizer()
        let h = try Harness(sizer: sizer)
        try h.fixture.file("Library/Caches/com.a/blob", bytes: 10)
        try h.fixture.file("Library/Caches/com.b/blob", bytes: 10)
        let first = step(risk: .cache, .delete(path: h.path("Library/Caches/com.a"), expectedFileID: nil))
        let second = step(risk: .cache, .delete(path: h.path("Library/Caches/com.b"), expectedFileID: nil))
        let engine = h.engine

        let running = Task { await engine.execute(CleanupPlan(steps: [first]), acknowledged: []) }
        await sizer.waitUntilEntered()
        let rejected = await engine.execute(CleanupPlan(steps: [second, second]), acknowledged: [])
        sizer.release()
        let report = await running.value

        #expect(rejected.results.map(\.outcome) == Array(repeating: .skipped(reason: "Another cleanup is running"), count: 2))
        #expect(h.exists("Library/Caches/com.b/blob"))
        #expect(report.results[0].outcome == .freed(bytes: 10))
        #expect(!h.exists("Library/Caches/com.a"))
    }

    @Test(.timeLimit(.minutes(1))) func cancellationSkipsAndLogsRemainingSteps() async throws {
        let sizer = GatedSizer()
        let h = try Harness(sizer: sizer)
        for name in ["a", "b", "c"] { try h.fixture.file("Library/Caches/com.\(name)/blob", bytes: 10) }
        let steps = ["a", "b", "c"].map {
            step($0, risk: .cache, .delete(path: h.path("Library/Caches/com.\($0)"), expectedFileID: nil))
        }
        let engine = h.engine

        let task = Task { await engine.execute(CleanupPlan(steps: steps), acknowledged: []) }
        await sizer.waitUntilEntered()
        task.cancel()
        sizer.release()
        let report = await task.value

        #expect(report.results.map(\.outcome) == [
            .freed(bytes: 10), .skipped(reason: "Cancelled"), .skipped(reason: "Cancelled"),
        ])
        #expect(h.exists("Library/Caches/com.b/blob"))
        #expect(h.exists("Library/Caches/com.c/blob"))
        #expect(try h.log.readAll().map(\.outcome) == report.results.map(\.outcome))
    }

    @Test(.timeLimit(.minutes(1))) func cancellationLetsRunningToolStepFinish() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/com.b/blob", bytes: 10)
        let fake = FakeToolRunner(tools: locatedTools)
        fake.stub("/opt/go", ["clean", "-cache"], output: ToolOutput(exitCode: 0, stdout: "", stderr: ""))
        fake.stub("/opt/rustup", ["toolchain", "uninstall", "x"], output: ToolOutput(exitCode: 0, stdout: "", stderr: ""))
        let tools = GatedToolRunner(fake)
        let freeSpace = FreeSpaceSequence([100, 700])
        let log = CleanupLog(fileURL: fixture.home.appendingPathComponent("log/cleanup-log.jsonl"))
        let engine = CleanupEngine(
            validator: ClosureValidator(), tools: tools, apps: FakeAppChecker(running: []),
            files: try FakeTrashFileOps(trashDir: fixture.home.appendingPathComponent("FakeTrash")),
            sizer: LogicalSizer(), log: log, policy: ToolPolicy(home: fixture.home), freeSpace: { freeSpace.next() }
        )
        let steps = [
            step("go", risk: .cache, .runTool(executable: "/opt/go", arguments: ["clean", "-cache"])),
            step("b", risk: .cache, .delete(path: fixture.home.path + "/Library/Caches/com.b", expectedFileID: nil)),
            step("rustup", risk: .rebuildable, .runTool(executable: "/opt/rustup", arguments: ["toolchain", "uninstall", "x"])),
        ]

        let task = Task { await engine.execute(CleanupPlan(steps: steps), acknowledged: []) }
        await tools.waitUntilEntered()
        task.cancel()
        // Give a cancelled tool run the chance to be abandoned before the tool "finishes".
        try await Task.sleep(for: .milliseconds(100))
        tools.release()
        let report = await task.value

        #expect(report.results.map(\.outcome) == [
            .freed(bytes: 600), .skipped(reason: "Cancelled"), .skipped(reason: "Cancelled"),
        ])
        #expect(fake.invocations.map(\.0) == ["/opt/go"])
        #expect(FileManager.default.fileExists(atPath: fixture.home.path + "/Library/Caches/com.b/blob"))
        #expect(try log.readAll().map(\.outcome) == report.results.map(\.outcome))
    }

    @Test func dependentStepRunsOnlyAfterItsDependencyCompleted() async throws {
        let h = try Harness()
        try h.fixture.file("Profile 11/Preferences", bytes: 10)
        try h.fixture.json("\(chrome)/Local State", ["profile": ["info_cache": ["Profile 11": [:]]]])
        let trash = step("Move profile", risk: .userData, .trash(path: h.path("Profile 11"), expectedFileID: nil))
        let edit = CleanupStep(
            title: "Remove from list", risk: .userData, estimatedBytes: 0, requirement: .none,
            action: .removeJSONKeys(path: h.path("\(chrome)/Local State"), edits: [.removeKey(["profile", "info_cache", "Profile 11"])]),
            dependsOn: trash.id)

        let report = await h.engine.execute(CleanupPlan(steps: [trash, edit]), acknowledged: [trash.id, edit.id])

        guard case .trashed = report.results[0].outcome, case .edited = report.results[1].outcome else {
            Issue.record("expected trashed then edited, got \(report.results.map(\.outcome))")
            return
        }
    }

    @Test func dependentStepIsSkippedWhenItsDependencyDidNotComplete() async throws {
        let h = try Harness()
        try h.fixture.file("Profile 11/Preferences", bytes: 10)
        try h.fixture.json("\(chrome)/Local State", ["profile": ["info_cache": ["Profile 11": [:]]]])
        let original = try Data(contentsOf: URL(fileURLWithPath: h.path("\(chrome)/Local State")))
        h.files.failTrash = true
        let trash = step("Move profile", risk: .userData, .trash(path: h.path("Profile 11"), expectedFileID: nil))
        let edit = CleanupStep(
            title: "Remove from list", risk: .userData, estimatedBytes: 0, requirement: .none,
            action: .removeJSONKeys(path: h.path("\(chrome)/Local State"), edits: [.removeKey(["profile", "info_cache", "Profile 11"])]),
            dependsOn: trash.id)
        // A dependency that is not in the plan (or comes later) never counts as completed.
        let orphan = CleanupStep(
            title: "Orphan", risk: .cache, estimatedBytes: 0, requirement: .none,
            action: .runTool(executable: "/opt/go", arguments: ["clean", "-cache"]), dependsOn: UUID())

        let report = await h.engine.execute(CleanupPlan(steps: [trash, edit, orphan]), acknowledged: [trash.id, edit.id])

        guard case .failed = report.results[0].outcome else {
            Issue.record("expected failed, got \(report.results[0].outcome)")
            return
        }
        #expect(report.results[1].outcome == .skipped(reason: "Skipped because Move profile did not complete"))
        #expect(report.results[2].outcome == .skipped(reason: "Skipped because a step it depends on did not complete"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: h.path("\(chrome)/Local State"))) == original)
        #expect(h.tools.invocations.isEmpty)
        #expect(try h.log.readAll().map(\.outcome) == report.results.map(\.outcome))
    }

    @Test func dependsOnIsOptionalWhenDecoding() throws {
        let old = CleanupStep(title: "x", risk: .cache, estimatedBytes: 1, requirement: .none,
                              action: .delete(path: "/tmp/x", expectedFileID: nil))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["dependsOn"] = nil
        let decoded = try JSONDecoder().decode(CleanupStep.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.dependsOn == nil)
        let dependent = CleanupStep(title: "y", risk: .cache, estimatedBytes: 1, requirement: .none,
                                    action: .runTool(executable: "/bin/true", arguments: []), dependsOn: old.id)
        #expect(try JSONDecoder().decode(CleanupStep.self, from: JSONEncoder().encode(dependent)) == dependent)
    }

    @Test func removeFailureReported() async throws {
        let h = try Harness()
        try h.fixture.file("Library/Caches/com.x/blob", bytes: 10)
        h.files.failRemove = true
        let s = step(risk: .cache, .delete(path: h.path("Library/Caches/com.x"), expectedFileID: nil))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        guard case .failed = report.results[0].outcome else {
            Issue.record("expected failed, got \(report.results[0].outcome)")
            return
        }
        #expect(h.exists("Library/Caches/com.x/blob"))
        #expect(report.freedBytes == 0)
    }

    @Test func trashFailureReported() async throws {
        let h = try Harness()
        try h.fixture.file("Docs/notes.txt", bytes: 10)
        h.files.failTrash = true
        let s = step(risk: .userData, .trash(path: h.path("Docs/notes.txt"), expectedFileID: nil))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        guard case .failed = report.results[0].outcome else {
            Issue.record("expected failed, got \(report.results[0].outcome)")
            return
        }
        #expect(h.exists("Docs/notes.txt"))
        #expect(report.trashedBytes == 0)
    }

    @Test func userDataToolNeedsAck() async throws {
        let h = try Harness()
        h.tools.stub("/opt/go", ["clean", "-cache"], output: ToolOutput(exitCode: 0, stdout: "", stderr: ""))
        let s = step(risk: .userData, .runTool(executable: "/opt/go", arguments: ["clean", "-cache"]))

        let blockers = await h.engine.preflight(CleanupPlan(steps: [s]), acknowledged: [])
        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        #expect(blockers[s.id] == [.needsAcknowledgement])
        guard case .skipped = report.results[0].outcome else {
            Issue.record("expected skipped, got \(report.results[0].outcome)")
            return
        }
        #expect(h.tools.invocations.isEmpty)
    }

    @Test func negativeFreeSpaceDeltaFlooredAtZero() async throws {
        let h = try Harness(freeSpace: FreeSpaceSequence([600, 100]))
        h.tools.stub("/opt/go", ["clean", "-cache"], output: ToolOutput(exitCode: 0, stdout: "", stderr: ""))
        let s = step(risk: .rebuildable, .runTool(executable: "/opt/go", arguments: ["clean", "-cache"]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        #expect(report.results[0].outcome == .freed(bytes: 0))
    }

    @Test func thrownToolErrorReported() async throws {
        let h = try Harness()  // nothing stubbed: FakeToolRunner throws `Unstubbed`
        let s = step(risk: .rebuildable, .runTool(executable: "/usr/local/bin/docker", arguments: ["image", "prune", "-a", "-f"]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        guard case .failed(let message) = report.results[0].outcome else {
            Issue.record("expected failed, got \(report.results[0].outcome)")
            return
        }
        #expect(!message.isEmpty)
        #expect(h.tools.invocations.count == 1)
    }

    @Test func jsonBackupPathRejectedLeavesOriginalAndReportsLeftover() async throws {
        let h = try Harness(validator: rejecting { $0.contains("Reclaim backup") })
        try h.fixture.json("\(chrome)/Local State", ["profile": ["info_cache": ["Profile 2": [:]]]])
        let path = h.path("\(chrome)/Local State")
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let s = step(risk: .userData, .removeJSONKeys(path: path, edits: [.removeKey(["profile", "info_cache", "Profile 2"])]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        guard case .failed(let message) = report.results[0].outcome else {
            Issue.record("expected failed, got \(report.results[0].outcome)")
            return
        }
        let leftover = try #require(
            try FileManager.default.contentsOfDirectory(atPath: h.path(chrome)).first { $0 != "Local State" }
        )
        #expect(message.contains(h.path(chrome + "/" + leftover)))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        #expect(h.files.trashed.isEmpty)
    }

    @Test func jsonBackupTrashFailureRemovesCopyAndLeavesOriginal() async throws {
        let h = try Harness()
        try h.fixture.json("\(chrome)/Local State", ["profile": ["info_cache": ["Profile 2": [:]]]])
        let path = h.path("\(chrome)/Local State")
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        h.files.failTrash = true
        let s = step(risk: .userData, .removeJSONKeys(path: path, edits: [.removeKey(["profile", "info_cache", "Profile 2"])]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        guard case .failed = report.results[0].outcome else {
            Issue.record("expected failed, got \(report.results[0].outcome)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.path(chrome)) == ["Local State"])
    }

    @Test func jsonTargetReplacedBeforeWriteIsNotOverwritten() async throws {
        let h = try Harness(validator: identityValidator)
        try h.fixture.json("\(chrome)/Local State", ["profile": ["info_cache": ["Profile 2": [:]]]])
        let path = h.path("\(chrome)/Local State")
        let replacement = Data(#"{"replaced":true}"#.utf8)
        h.files.onTrash = { _ in
            try? FileManager.default.removeItem(atPath: path)
            try? replacement.write(to: URL(fileURLWithPath: path))
        }
        let s = step(risk: .userData, .removeJSONKeys(path: path, edits: [.removeKey(["profile", "info_cache", "Profile 2"])]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        guard case .failed(let message) = report.results[0].outcome else {
            Issue.record("expected failed, got \(report.results[0].outcome)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == replacement)
        #expect(h.files.trashed.count == 1)
        #expect(message.contains(h.files.trashed[0]))
    }

    // MARK: - ToolPolicy enforcement

    @Test func toolOutsideThePolicyIsBlockedAndNeverRuns() async throws {
        let h = try Harness()
        try h.fixture.file("Documents/thesis.txt", bytes: 10)
        let documents = h.path("Documents")
        h.tools.stub("/bin/rm", ["-rf", documents], output: ToolOutput(exitCode: 0, stdout: "", stderr: ""))
        let s = step(risk: .cache, .runTool(executable: "/bin/rm", arguments: ["-rf", documents]))
        let plan = CleanupPlan(steps: [s])

        let blockers = await h.engine.preflight(plan, acknowledged: [])
        #expect(blockers[s.id] == [.invalidPath(.toolNotAllowed("/bin/rm -rf \(documents)"))])

        let report = await h.engine.execute(plan, acknowledged: [])
        #expect(report.results[0].outcome == .skipped(reason: "/bin/rm -rf \(documents) is not a command cleanup may run."))
        #expect(h.tools.invocations.isEmpty)
        #expect(h.exists("Documents/thesis.txt"))
        #expect(try h.log.readAll().map(\.outcome) == [report.results[0].outcome])
    }

    @Test func allowedToolWithOtherArgumentsIsBlocked() async throws {
        let h = try Harness()
        let s = step(risk: .rebuildable, .runTool(
            executable: "/usr/local/bin/docker", arguments: ["system", "prune", "-a", "-f", "--volumes"]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        guard case .skipped = report.results[0].outcome else {
            Issue.record("expected skipped, got \(report.results[0].outcome)")
            return
        }
        #expect(h.tools.invocations.isEmpty)
    }

    @Test func allowedToolAtAnotherPathIsBlocked() async throws {
        let h = try Harness()
        let s = step(risk: .cache, .runTool(executable: h.path("bin/go"), arguments: ["clean", "-cache"]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [])

        #expect(report.results[0].outcome == .skipped(reason: "\(h.path("bin/go")) clean -cache is not a command cleanup may run."))
        #expect(h.tools.invocations.isEmpty)
    }

    @Test func jsonEditOfAnotherFileIsBlocked() async throws {
        let h = try Harness()
        try h.fixture.json("Library/Application Support/Example/settings.json", ["profile": ["info_cache": ["Profile 2": [:]]]])
        let path = h.path("Library/Application Support/Example/settings.json")
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let s = step(risk: .userData, .removeJSONKeys(path: path, edits: [.removeKey(["profile", "info_cache", "Profile 2"])]))

        let blockers = await h.engine.preflight(CleanupPlan(steps: [s]), acknowledged: [s.id])
        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        #expect(blockers[s.id] == [.invalidPath(.editNotAllowed(path))])
        guard case .skipped = report.results[0].outcome else {
            Issue.record("expected skipped, got \(report.results[0].outcome)")
            return
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        #expect(h.files.trashed.isEmpty)
    }

    @Test func jsonEditOfOtherKeysIsBlocked() async throws {
        let h = try Harness()
        try h.fixture.json("\(chrome)/Local State", ["profile": ["info_cache": ["Profile 2": [:]], "last_used": "Profile 2"]])
        let path = h.path("\(chrome)/Local State")
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let s = step(risk: .userData, .removeJSONKeys(path: path, edits: [.removeKey(["profile"])]))

        let report = await h.engine.execute(CleanupPlan(steps: [s]), acknowledged: [s.id])

        #expect(report.results[0].outcome == .skipped(reason: "\(path) is not a file cleanup may edit this way."))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original)
        #expect(h.files.trashed.isEmpty)
    }

    // MARK: - CleanupStep and CleanupAction

    @Test func effectiveActionTrashesOnlyUserDataDeletes() {
        let delete = CleanupAction.delete(path: "/Users/sample/x", expectedFileID: nil)
        let tool = CleanupAction.runTool(executable: "/opt/go", arguments: ["clean", "-cache"])
        #expect(step(risk: .userData, delete).effectiveAction == .trash(path: "/Users/sample/x", expectedFileID: nil))
        #expect(step(risk: .cache, delete).effectiveAction == delete)
        #expect(step(risk: .rebuildable, delete).effectiveAction == delete)
        #expect(step(risk: .userData, tool).effectiveAction == tool)
    }

    @Test func orderedForExecutionTrashesAFolderBeforeStepsInsideIt() {
        let profile = "/Users/sample/Library/Application Support/Demo/Profile 1"
        let cache = step("cache", risk: .cache, .delete(path: profile + "/Cache", expectedFileID: nil))
        let other = step("other", risk: .cache, .delete(path: "/Users/sample/Library/Caches/Other", expectedFileID: nil))
        let trash = step("profile", risk: .userData, .trash(path: profile, expectedFileID: nil))
        let edit = CleanupStep(title: "list", risk: .userData, estimatedBytes: 0, requirement: .none,
                               action: .removeJSONKeys(path: "/Users/sample/Library/Application Support/Demo/Local State",
                                                       edits: [.removeKey(["profile"])]),
                               dependsOn: trash.id)
        let plan = CleanupPlan(steps: [cache, other, trash, edit]).orderedForExecution()
        #expect(plan.steps.map(\.title) == ["profile", "cache", "other", "list"])
    }

    @Test func orderedForExecutionCountsARedDeleteAsTrash() {
        let folder = "/Users/sample/Library/Application Support/Demo"
        let inner = step("inner", risk: .cache, .delete(path: folder + "/Cache", expectedFileID: nil))
        let outer = step("outer", risk: .userData, .delete(path: folder, expectedFileID: nil))
        #expect(CleanupPlan(steps: [inner, outer]).orderedForExecution().steps.map(\.title) == ["outer", "inner"])
    }

    @Test func orderedForExecutionKeepsOrderOtherwise() {
        let folder = "/Users/sample/Library/Application Support/Demo"
        let inner = step("inner", risk: .cache, .delete(path: folder + "/Cache", expectedFileID: nil))
        // A permanent delete of the folder is not moved: nothing would be kept in the Trash.
        let green = step("green", risk: .cache, .delete(path: folder, expectedFileID: nil))
        let sibling = step("sibling", risk: .userData, .trash(path: folder + "-2", expectedFileID: nil))
        let same = step("same", risk: .userData, .trash(path: folder + "/Cache", expectedFileID: nil))
        let tool = step("tool", risk: .userData, .runTool(executable: "/opt/go", arguments: ["clean"]))
        let steps = [inner, green, sibling, same, tool]
        #expect(CleanupPlan(steps: steps).orderedForExecution().steps == steps)
    }

    @Test func orderedForExecutionNeverMovesAStepAheadOfItsDependency() {
        let folder = "/Users/sample/Library/Application Support/Demo"
        let first = step("first", risk: .cache, .delete(path: "/Users/sample/Library/Caches/Demo", expectedFileID: nil))
        let inner = step("inner", risk: .cache, .delete(path: folder + "/Cache", expectedFileID: nil))
        let outer = CleanupStep(title: "outer", risk: .userData, estimatedBytes: 0, requirement: .none,
                                action: .trash(path: folder, expectedFileID: nil), dependsOn: first.id)
        let steps = [first, inner, outer]
        #expect(CleanupPlan(steps: steps).orderedForExecution().steps == steps)
    }

    /// Clearing a profile's cache and removing the profile in one cleanup keeps the cache in the
    /// Trash with the profile, whichever was added first.
    @Test func cacheInsideATrashedProfileGoesToTheTrashWithIt() async throws {
        let h = try Harness()
        try h.fixture.file("Profile/Cache/data.bin", bytes: 300)
        try h.fixture.file("Profile/Bookmarks", bytes: 10)
        let cache = step("cache", risk: .cache, .delete(path: h.path("Profile/Cache"), expectedFileID: nil))
        let profile = step("profile", risk: .userData, .trash(path: h.path("Profile"), expectedFileID: nil))
        let plan = CleanupPlan(steps: [cache, profile]).orderedForExecution()

        let report = await h.engine.execute(plan, acknowledged: [profile.id])

        #expect(report.freedBytes == 0)
        let trashed = try #require(h.files.trashed.first)
        #expect(FileManager.default.fileExists(atPath: trashed + "/Cache/data.bin"))
    }

    @Test func isIrreversibleFollowsTheEffectiveAction() {
        let path = "/Users/sample/x"
        let delete = CleanupAction.delete(path: path, expectedFileID: nil)
        let tool = CleanupAction.runTool(executable: "/opt/go", arguments: ["clean", "-cache"])
        #expect(step(risk: .cache, delete).isIrreversible)
        #expect(step(risk: .rebuildable, delete).isIrreversible)
        // The engine moves a 🔴 delete to the Trash, so it can be put back.
        #expect(!step(risk: .userData, delete).isIrreversible)
        #expect(!step(risk: .cache, .trash(path: path, expectedFileID: nil)).isIrreversible)
        #expect(!step(risk: .userData, .removeJSONKeys(path: path, edits: [.removeKey(["a"])])).isIrreversible)
        #expect(step(risk: .cache, tool).isIrreversible)
        #expect(step(risk: .userData, tool).isIrreversible)
    }

    @Test func isIrreversibleIsNotStoredInJSON() throws {
        let red = step(risk: .userData, .delete(path: "/Users/sample/x", expectedFileID: nil))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(red)) as? [String: Any])
        #expect(json["isIrreversible"] == nil)
        // A value in older data is ignored.
        json["isIrreversible"] = true
        let decoded = try JSONDecoder().decode(CleanupStep.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == red)
        #expect(!decoded.isIrreversible)
    }

    @Test func acknowledgementIsOptionalWhenDecoding() throws {
        let plain = step(risk: .userData, .trash(path: "/Users/sample/x", expectedFileID: nil))
        #expect(plain.acknowledgement == nil)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        json["acknowledgement"] = nil
        let decoded = try JSONDecoder().decode(CleanupStep.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == plain)
        let withText = CleanupStep(title: "t", risk: .userData, estimatedBytes: 0, requirement: .none,
                                   action: plain.action, acknowledgement: "The list will be edited")
        #expect(try JSONDecoder().decode(CleanupStep.self, from: JSONEncoder().encode(withText)) == withText)
    }

    @Test func actionsRoundTripThroughJSON() throws {
        let actions: [CleanupAction] = [
            .delete(path: "/Users/sample/a", expectedFileID: nil),
            .trash(path: "/Users/sample/b", expectedFileID: FileID(device: 1, inode: 2)),
            .runTool(executable: "/opt/go", arguments: ["clean", "-cache"]),
            .removeJSONKeys(path: "/Users/sample/c", edits: [
                .removeKey(["a", "b"]), .removeArrayValue(keyPath: ["a", "list"], value: "x"),
            ]),
        ]
        for action in actions {
            #expect(try JSONDecoder().decode(CleanupAction.self, from: JSONEncoder().encode(action)) == action)
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(actions[0])) as? [String: Any]
        #expect(encoded?.keys.sorted() == ["delete"])
    }

    @Test func legacyKeyPathLogEntryDecodes() throws {
        let line = ##"{"removeJSONKeys":{"path":"/Users/sample/Local State","keyPaths":[["profile","info_cache","Profile 2"],["profile","profiles_order","#value:Profile 2"]]}}"##
        let action = try JSONDecoder().decode(CleanupAction.self, from: Data(line.utf8))
        #expect(action == .removeJSONKeys(path: "/Users/sample/Local State", edits: [
            .removeKey(["profile", "info_cache", "Profile 2"]),
            .removeArrayValue(keyPath: ["profile", "profiles_order"], value: "Profile 2"),
        ]))
    }
}
