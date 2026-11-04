import Foundation

/// The only code in the app that deletes anything.
///
/// Per step, in order: measure a path step's size (slow), then re-run preflight, app state
/// included (any blocker skips the step); 🔴 steps need an
/// acknowledgement and a 🔴 `.delete` becomes `.trash` (`CleanupStep.effectiveAction`); paths
/// are checked by the `PathValidating` validator and tool runs and JSON edits by `ToolPolicy`,
/// each immediately before acting, with no suspension point between that check and the action;
/// every step, skipped ones included, gets one log entry.
///
/// A step with `dependsOn` runs only when that earlier step was trashed, freed or edited.
///
/// One `execute` at a time: a call made while another is running skips every step. Cancelling the
/// calling task skips (and logs) every step that has not started yet; a step that has started
/// (a running tool included) is shielded from the cancellation and finishes.
public actor CleanupEngine {
    /// Upper bound for a single cleanup tool run (e.g. `docker builder prune`).
    static let toolTimeout: Duration = .seconds(30 * 60)
    static let busyReason = "Another cleanup is running"
    static let cancelledReason = "Cancelled"
    static let nothingToRemoveReason = "Nothing to remove"

    private var isExecuting = false

    private let validator: any PathValidating
    private let tools: any ToolRunning
    private let apps: any RunningAppChecking
    private let files: any FileOperating
    private let sizer: any SizeMeasuring
    private let log: CleanupLog
    private let policy: ToolPolicy
    private let freeSpace: @Sendable () -> Int64

    /// - Parameter policy: which tool runs and JSON edits are allowed. Build it with the same
    ///   home as the validator; the default uses the current user's home.
    public init(
        validator: any PathValidating,
        tools: any ToolRunning,
        apps: any RunningAppChecking,
        files: any FileOperating,
        sizer: any SizeMeasuring,
        log: CleanupLog,
        policy: ToolPolicy = ToolPolicy(home: FileManager.default.homeDirectoryForCurrentUser),
        freeSpace: @escaping @Sendable () -> Int64
    ) {
        self.validator = validator
        self.tools = tools
        self.apps = apps
        self.files = files
        self.sizer = sizer
        self.log = log
        self.policy = policy
        self.freeSpace = freeSpace
    }

    /// Blockers per step ID. Steps that can run are absent from the result.
    public func preflight(_ plan: CleanupPlan, acknowledged: Set<UUID>) async -> [UUID: [Blocker]] {
        var result: [UUID: [Blocker]] = [:]
        for step in plan.steps {
            let blockers = await blockers(for: step, acknowledged: acknowledged)
            if !blockers.isEmpty { result[step.id] = blockers }
        }
        return result
    }

    public func execute(_ plan: CleanupPlan, acknowledged: Set<UUID>) async -> CleanupReport {
        var results: [(step: CleanupStep, outcome: StepOutcome)] = []
        var logFailures: [String] = []

        // The actor is reentrant across every `await` below, so this flag (checked and set with
        // no suspension in between) is what keeps two executions from interleaving.
        if isExecuting {
            for step in plan.steps {
                let outcome = StepOutcome.skipped(reason: Self.busyReason)
                results.append((step: step, outcome: outcome))
                record(step, action: step.effectiveAction, outcome: outcome, failures: &logFailures)
            }
            return CleanupReport(results: results, logFailures: logFailures)
        }
        isExecuting = true
        defer { isExecuting = false }

        var completed: Set<UUID> = []
        for step in plan.steps {
            let action = step.effectiveAction
            let outcome: StepOutcome = if Task.isCancelled {
                .skipped(reason: Self.cancelledReason)
            } else if let dependency = step.dependsOn, !completed.contains(dependency) {
                // Fail safe: a dependency that failed, was skipped, or is not earlier in this plan.
                .skipped(reason: Self.dependencyReason(dependency, in: plan))
            } else {
                // An unstructured task does not inherit the caller's cancellation, so Stop never
                // interrupts a started step (e.g. kills `rustup toolchain uninstall` midway). A
                // tool's own timeout still applies.
                await Task { await self.run(step, action: action, acknowledged: acknowledged) }.value
            }
            switch outcome {
            case .trashed, .freed, .edited: completed.insert(step.id)
            case .skipped, .failed: break
            }
            results.append((step: step, outcome: outcome))
            record(step, action: action, outcome: outcome, failures: &logFailures)
        }
        return CleanupReport(results: results, logFailures: logFailures)
    }

    private static func dependencyReason(_ dependency: UUID, in plan: CleanupPlan) -> String {
        guard let title = plan.steps.first(where: { $0.id == dependency })?.title else {
            return "Skipped because a step it depends on did not complete"
        }
        return "Skipped because \(title) did not complete"
    }

    /// Logs one step. A failed write does not stop execution (what happened on disk has
    /// happened); it is reported in `CleanupReport.logFailures` instead.
    private func record(_ step: CleanupStep, action: CleanupAction, outcome: StepOutcome, failures: inout [String]) {
        let entry = LogEntry(
            id: UUID(), date: Date(), title: step.title, action: action, risk: step.risk, outcome: outcome
        )
        do {
            try log.append(entry)
        } catch {
            failures.append("Could not record \"\(step.title)\" in the cleanup log: \(Self.describe(error))")
        }
    }

    // MARK: - Preflight

    private func blockers(for step: CleanupStep, acknowledged: Set<UUID>) async -> [Blocker] {
        var blockers: [Blocker] = []
        switch step.requirement {
        case .mustBeQuit(let bundleIDs, let processNames):
            if await apps.isRunning(bundleIDs: bundleIDs, processNames: processNames) {
                let name = processNames.first ?? bundleIDs.first ?? "The owning app"
                blockers.append(.appRunning(name: name, bundleIDs: bundleIDs))
            }
        case .mustBeRunning(let bundleIDs, let processNames, let reason):
            if !(await apps.isRunning(bundleIDs: bundleIDs, processNames: processNames)) {
                blockers.append(.appNotRunning(reason: reason))
            }
        case .none:
            break
        }
        if step.risk == .userData && !acknowledged.contains(step.id) {
            blockers.append(.needsAcknowledgement)
        }
        switch step.action {
        case .delete(let path, let expectedFileID), .trash(let path, let expectedFileID):
            if case .failure(let violation) = validate(path, expectedFileID) {
                blockers.append(.invalidPath(violation))
            }
        case .removeJSONKeys(let path, _):
            if case .failure(let violation) = validate(path, nil) {
                blockers.append(.invalidPath(violation))
            } else if let violation = policyViolation(step.action) {
                blockers.append(.invalidPath(violation))
            }
        case .runTool:
            if let violation = policyViolation(step.action) {
                blockers.append(.invalidPath(violation))
            }
        }
        return blockers
    }

    private func policyViolation(_ action: CleanupAction) -> SafetyViolation? {
        policy.violation(for: action, locate: { tools.locate($0) })
    }

    private func validate(_ path: String, _ expectedFileID: FileID?) -> Result<String, SafetyViolation> {
        do throws(SafetyViolation) {
            return .success(try validator.validate(path, expectedFileID: expectedFileID))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Execution

    /// Every action follows the same order: measure (may suspend), check the app state and the
    /// other blockers, check the path or command (synchronous), act (synchronous for file
    /// operations; for a tool, the run is the first suspension). Nothing can change the path or
    /// the command between the check and the action, and an app launched while a large folder
    /// was being measured still blocks the step.
    private func run(_ step: CleanupStep, action: CleanupAction, acknowledged: Set<UUID>) async -> StepOutcome {
        // Measuring can take minutes, so it comes before the app-state check. A path that fails
        // validation is not measured; the blockers below report it.
        var bytes: Int64 = 0
        switch action {
        case .delete(let path, let expectedFileID), .trash(let path, let expectedFileID):
            if case .success = validate(path, expectedFileID) {
                bytes = await sizer.allocatedSize(of: path)
            }
        case .runTool, .removeJSONKeys:
            break
        }
        let blockers = await blockers(for: step, acknowledged: acknowledged)
        if !blockers.isEmpty {
            return .skipped(reason: blockers.map(\.message).joined(separator: " "))
        }
        // Redundant with preflight on purpose: never act on unacknowledged user data.
        guard step.risk != .userData || acknowledged.contains(step.id) else {
            return .skipped(reason: Blocker.needsAcknowledgement.message)
        }

        switch action {
        case .delete(let path, let expectedFileID):
            return removeItem(at: path, expectedFileID: expectedFileID, toTrash: false, bytes: bytes)

        case .trash(let path, let expectedFileID):
            return removeItem(at: path, expectedFileID: expectedFileID, toTrash: true, bytes: bytes)

        case .runTool(let executable, let arguments):
            if let violation = policyViolation(action) { return .skipped(reason: violation.message) }
            let before = freeSpace()  // Synchronous: nothing between the check and the run suspends.
            let output: ToolOutput
            do {
                output = try await tools.run(executable, arguments, timeout: Self.toolTimeout)
            } catch {
                return .failed(message: Self.describe(error))
            }
            guard output.exitCode == 0 else {
                let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed(message: stderr.isEmpty ? "Exited with status \(output.exitCode)." : stderr)
            }
            return .freed(bytes: max(0, freeSpace() - before))

        case .removeJSONKeys(let path, let edits):
            let resolved: String
            switch validate(path, nil) {
            case .success(let path): resolved = path
            case .failure(let violation): return .skipped(reason: violation.message)
            }
            if let violation = policyViolation(.removeJSONKeys(path: resolved, edits: edits)) {
                return .skipped(reason: violation.message)
            }
            return removeJSONKeys(at: resolved, edits: edits)  // Synchronous throughout.
        }
    }

    /// `.delete` and `.trash`, with `bytes` measured by `run` beforehand (the sizer only reads; it
    /// never follows symlinks). Synchronous: the path is validated again and acted on with no
    /// `await` in between.
    private func removeItem(at path: String, expectedFileID: FileID?, toTrash: Bool, bytes: Int64) -> StepOutcome {
        let resolved: String
        switch validate(path, expectedFileID) {
        case .success(let path): resolved = path
        case .failure(let violation): return .skipped(reason: violation.message)
        }
        do {
            if toTrash {
                return .trashed(bytes: bytes, trashPath: try files.trash(resolved))
            }
            try files.remove(resolved)
            return .freed(bytes: bytes)
        } catch {
            return .failed(message: Self.describe(error))
        }
    }

    /// Success: `.edited(backupTrashPath:)`. No edit matched: `.skipped("Nothing to remove")`,
    /// with no backup and no write. Synchronous, so nothing else can run on the actor meanwhile.
    private func removeJSONKeys(at path: String, edits: [JSONEdit]) -> StepOutcome {
        // Identity at read time; checked again right before the rewrite so a file replaced in the
        // meantime is never overwritten with content derived from the old one.
        let identity = FileID.of(path: path)
        let original: Data
        do {
            original = try files.read(path)
        } catch {
            return .failed(message: Self.describe(error))
        }
        // Parsing only reads memory, so a parse failure leaves the file and the Trash untouched.
        guard var root = try? JSONSerialization.jsonObject(with: original) else {
            return .failed(message: "\(path) is not valid JSON; left unchanged.")
        }
        var changed = false
        for edit in edits {
            if let updated = Self.applying(edit, to: root) {
                root = updated
                changed = true
            }
        }
        guard changed else { return .skipped(reason: Self.nothingToRemoveReason) }

        let updated: Data
        do {
            updated = try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
        } catch {
            return .failed(message: Self.describe(error))
        }

        // Back up first: write a timestamped sibling copy (same volume, so it can be trashed)
        // and move it to the Trash. Only then is the original rewritten.
        let backupPath = Self.backupPath(for: path)
        do {
            try files.write(original, to: backupPath)
        } catch {
            return .failed(message: "Could not back up \(path): \(Self.describe(error)) \(path) was left unchanged.")
        }
        let validBackup: String
        switch validate(backupPath, nil) {
        case .success(let resolved): validBackup = resolved
        case .failure(let violation):
            return .failed(message: "The backup of \(path) failed validation (\(violation.message)) "
                + "\(path) was left unchanged. A backup copy was left at \(backupPath).")
        }
        let trashedBackup: String
        do {
            trashedBackup = try files.trash(validBackup)
        } catch {
            let reason = "Could not move the backup of \(path) to the Trash: \(Self.describe(error)) "
                + "\(path) was left unchanged."
            guard case .success(let removable) = validate(validBackup, nil), (try? files.remove(removable)) != nil else {
                return .failed(message: "\(reason) A backup copy was left at \(validBackup).")
            }
            return .failed(message: reason)
        }

        let target: String
        switch validate(path, identity) {
        case .success(let resolved): target = resolved
        case .failure(let violation):
            return .failed(message: "\(violation.message) It was not modified. "
                + "The backup of the original is in the Trash at \(trashedBackup).")
        }
        do {
            try files.write(updated, to: target)
        } catch {
            return .failed(message: "\(Self.describe(error)) The original is in the Trash at \(trashedBackup).")
        }
        return .edited(backupTrashPath: trashedBackup)
    }

    /// Returns the updated value, or nil when the edit matched nothing (a no-op, not a failure).
    static func applying(_ edit: JSONEdit, to value: Any) -> Any? {
        switch edit {
        case .removeKey(let keyPath):
            return updating(keyPath[...], in: value) { object, key in
                object.removeValue(forKey: key) != nil
            }
        case .removeArrayValue(let keyPath, let target):
            return updating(keyPath[...], in: value) { object, key in
                guard let array = object[key] as? [Any] else { return false }
                let filtered = array.filter { ($0 as? String) != target }
                guard filtered.count != array.count else { return false }
                object[key] = filtered
                return true
            }
        }
    }

    /// Walks the objects along `keyPath` and calls `change` on the object holding the last key.
    /// Nil when a key on the way is missing or not an object, or when `change` returns false.
    private static func updating(
        _ keyPath: ArraySlice<String>, in value: Any, change: (inout [String: Any], String) -> Bool
    ) -> Any? {
        guard let key = keyPath.first, var object = value as? [String: Any] else { return nil }
        let rest = keyPath.dropFirst()
        if rest.isEmpty {
            return change(&object, key) ? object : nil
        }
        guard let child = object[key], let updatedChild = updating(rest, in: child, change: change) else { return nil }
        object[key] = updatedChild
        return object
    }

    private static func backupPath(for path: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "\(path) (Reclaim backup \(formatter.string(from: Date())))"
        // `FileID.of` is `lstat`: a dangling symlink at this name counts as taken, unlike
        // `FileManager.fileExists`, which follows symlinks. It only reads, so it does not need to
        // go through `FileOperating`.
        guard FileID.of(path: base) != nil else { return base }
        return "\(base) \(UUID().uuidString)"
    }

    private static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
