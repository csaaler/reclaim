import AppKit
import Observation
import StorageCore

/// The review → execute → results flow for one opening of the cleanup sheet.
///
/// Each candidate is planned on its own, so every step row belongs to exactly one candidate and
/// removing a row removes the whole candidate (never half of an inspector's multi-step plan).
/// Planning alone means an inspector cannot skip a path inside a folder another candidate
/// trashes, so `confirm` runs the plan in `orderedForExecution` order.
/// Plans are made once, when the sheet opens; step IDs (and the acknowledgements tied to them)
/// stay stable until the sheet closes.
@MainActor @Observable
final class CleanupReviewModel {
    struct Entry: Identifiable {
        let candidate: CleanupCandidate
        let steps: [CleanupStep]
        /// Why this candidate could not be planned. Confirm stays disabled until it is removed.
        let planError: String?
        /// Set when planning produced no step ("Nothing to do for <title>…").
        let nothingToDo: String?
        /// Planner messages for steps it dropped although others remain ("<path> no longer exists.").
        var planNotes: [String] = []
        var id: String { candidate.id }
    }

    enum Phase: Equatable {
        case planning, reviewing, executing, finished
    }

    private(set) var phase: Phase = .planning
    private(set) var entries: [Entry] = []
    var acknowledged: Set<UUID> = []
    /// From `engine.preflight`, without `.needsAcknowledgement` (that is the checkbox).
    private(set) var blockers: [UUID: [Blocker]] = [:]
    private(set) var isCheckingBlockers = false
    /// Names of apps a graceful quit was requested for and is still pending.
    private(set) var quitting: Set<String> = []
    /// Apps that did not quit within the engine's wait.
    private(set) var quitFailures: Set<String> = []
    /// Shown when the re-check right before execution found something new.
    private(set) var preExecutionMessage: String?
    private(set) var cancelRequested = false
    private(set) var report: CleanupReport?

    private let services: CleanupServices
    private let list: CleanupList
    private var execution: Task<CleanupReport, Never>?
    private var planning: Task<Void, Never>?
    /// Refreshes in flight; only the newest one's result is applied.
    private var checkGeneration = 0

    init(services: CleanupServices, list: CleanupList) {
        self.services = services
        self.list = list
    }

    var plan: CleanupPlan { CleanupPlan(steps: entries.flatMap(\.steps)) }

    var userDataSteps: [CleanupStep] { plan.steps.filter { $0.risk == .userData } }

    var hasBlockers: Bool { blockers.values.contains { !$0.isEmpty } }

    var hasPlanErrors: Bool { entries.contains { $0.planError != nil } }

    var allUserDataAcknowledged: Bool { userDataSteps.allSatisfy { acknowledged.contains($0.id) } }

    var canConfirm: Bool {
        phase == .reviewing && !isCheckingBlockers && quitting.isEmpty && !plan.steps.isEmpty
            && allUserDataAcknowledged && !hasBlockers && !hasPlanErrors
    }

    /// Why Confirm is disabled, in priority order.
    var confirmHint: String? {
        guard phase == .reviewing else { return nil }
        if plan.steps.isEmpty { return "Nothing to clean up." }
        if hasPlanErrors { return "Remove the items that could not be planned." }
        if let blocked = firstBlocked { return Self.hint(for: blocked.blocker, item: blocked.entry?.candidate.displayTitle) }
        if hasBlockers { return "Resolve the blocked items to continue." }
        if !allUserDataAcknowledged {
            let missing = userDataSteps.filter { !acknowledged.contains($0.id) }.count
            return "Confirm \(missing) item\(missing == 1 ? "" : "s") marked 🔴 to continue."
        }
        if isCheckingBlockers || !quitting.isEmpty { return "Checking…" }
        return nil
    }

    /// Effective bytes: 🔴 `.delete` is trashed by the engine, so it counts as Trash here too.
    var freesNowBytes: Int64 {
        plan.steps.reduce(0) { $1.method == .delete || $1.method == .runTool ? $0 + $1.estimatedBytes : $0 }
    }

    var trashBytes: Int64 {
        plan.steps.reduce(0) { $1.method == .trash ? $0 + $1.estimatedBytes : $0 }
    }

    /// The first blocker in list order, with the entry it belongs to.
    private var firstBlocked: (blocker: Blocker, entry: Entry?)? {
        for step in plan.steps {
            if let blocker = blockers[step.id]?.first { return (blocker, entry(for: step)) }
        }
        return nil
    }

    /// "Quit Simulator or remove this item to continue."
    static func hint(for blocker: Blocker, item: String?) -> String {
        let which = item.map { "“\($0)”" } ?? "this item"
        switch blocker {
        case .appRunning(let name, let bundleIDs):
            return "Quit \(appDisplayName(name, bundleIDs: bundleIDs)) or remove \(which) to continue."
        case .appNotRunning(let reason):
            return "\(reason) Or remove \(which) to continue."
        case .invalidPath:
            return "\(blocker.message) Remove \(which) to continue."
        case .needsAcknowledgement:
            return "Check the 🔴 box for \(which) to continue."
        }
    }

    /// The engine names an app by process name or, failing that, bundle ID; show the app's name.
    static func appDisplayName(_ name: String, bundleIDs: [String]) -> String {
        guard bundleIDs.contains(name) else { return name }
        return NSRunningApplication.runningApplications(withBundleIdentifier: name).first?.localizedName ?? name
    }

    func entry(for step: CleanupStep) -> Entry? {
        entries.first { $0.steps.contains { $0.id == step.id } }
    }

    // MARK: Planning and checks

    /// Starts planning; `cancelPlanning` stops it.
    func start() {
        guard planning == nil, phase == .planning else { return }
        planning = Task { await self.prepare() }
    }

    /// Cancel while "Preparing the review…": nothing has been planned or run.
    func cancelPlanning() {
        planning?.cancel()
        planning = nil
    }

    func prepare() async {
        phase = .planning
        let planner = CleanupPlanner()
        let context = services.planningContext()
        var planned: [Entry] = []
        for candidate in list.candidates where candidate.isAddable {
            if Task.isCancelled { return }
            var locations: [AttributedLocation] = []
            var items: [InspectorItem] = []
            switch candidate {
            case .location(let location, _): locations = [location]
            case .inspectorItem(let item): items = [item]
            }
            do {
                let result = try await planner.planReporting(
                    locations: locations, items: items, inspectors: services.inspectors, context: context)
                let nothing = result.plan.steps.isEmpty
                    ? (result.nothingToDo.first ?? "Nothing to do for \(candidate.displayTitle).") : nil
                planned.append(Entry(candidate: candidate, steps: result.plan.steps, planError: nil, nothingToDo: nothing,
                                     planNotes: result.plan.steps.isEmpty ? [] : result.nothingToDo))
            } catch {
                let message = (error as? any LocalizedError)?.errorDescription
                    ?? (error as? InspectorUnavailable)?.reason ?? String(describing: error)
                planned.append(Entry(candidate: candidate, steps: [], planError: message, nothingToDo: nil))
            }
        }
        if Task.isCancelled { return }
        entries = planned
        phase = .reviewing
        planning = nil
        await refreshBlockers()
    }

    /// Overlapping refreshes are fine: only the newest result is applied, `isCheckingBlockers`
    /// stays true until that one is back, and blockers are kept only for steps still listed.
    func refreshBlockers() async {
        guard phase == .reviewing else { return }
        checkGeneration += 1
        let mine = checkGeneration
        isCheckingBlockers = true
        let found = await services.engine.preflight(plan, acknowledged: acknowledged)
        guard mine == checkGeneration else { return }
        isCheckingBlockers = false
        guard phase == .reviewing else { return }
        blockers = currentOnly(Self.withoutAcknowledgement(found))
    }

    private func currentOnly(_ blockers: [UUID: [Blocker]]) -> [UUID: [Blocker]] {
        let ids = Set(plan.steps.map(\.id))
        return blockers.filter { ids.contains($0.key) }
    }

    func remove(_ entry: Entry) {
        guard phase == .reviewing else { return }
        for step in entry.steps {
            acknowledged.remove(step.id)
            blockers[step.id] = nil
        }
        entries.removeAll { $0.id == entry.id }
        list.remove(entry.candidate)
    }

    func setAcknowledged(_ value: Bool, for step: CleanupStep) {
        guard phase == .reviewing else { return }
        if value { acknowledged.insert(step.id) } else { acknowledged.remove(step.id) }
    }

    /// Graceful quit only (`requestQuit` never force-quits), then the checks run again.
    func quit(name: String, bundleIDs: [String]) async {
        guard phase == .reviewing, !bundleIDs.isEmpty, !quitting.contains(name) else { return }
        quitting.insert(name)
        quitFailures.remove(name)
        let quit = await services.apps.requestQuit(bundleIDs: bundleIDs)
        quitting.remove(name)
        if !quit { quitFailures.insert(name) }
        await refreshBlockers()
    }

    // MARK: Execution

    func confirm() async {
        // Set before any suspension: a second click finds the phase changed and does nothing.
        guard canConfirm else { return }
        phase = .executing
        preExecutionMessage = nil
        let plan = self.plan
        let acknowledged = self.acknowledged

        // Re-check right before execution; the engine checks again per step.
        let fresh = Self.withoutAcknowledgement(await services.engine.preflight(plan, acknowledged: acknowledged))
        let unacknowledged = plan.steps.contains { $0.risk == .userData && !acknowledged.contains($0.id) }
        if cancelRequested {
            cancelRequested = false
            preExecutionMessage = "Stopped before anything ran. Nothing was removed."
            phase = .reviewing
            return
        }
        if !fresh.isEmpty || unacknowledged {
            blockers = currentOnly(fresh)
            preExecutionMessage = "Something changed since you reviewed this list. Nothing was removed."
            phase = .reviewing
            return
        }

        let engine = services.engine
        // Candidates were planned one at a time, so a folder one of them trashes can hold paths
        // another deletes; trash the folder first so those paths go to the Trash with it.
        let ordered = plan.orderedForExecution()
        let task = Task { await engine.execute(ordered, acknowledged: acknowledged) }
        execution = task
        let report = await task.value
        execution = nil
        self.report = report
        phase = .finished
    }

    /// The engine stops before the next step; the step running now finishes (it is not undone).
    /// Also works during the re-check before the engine starts: then nothing runs at all.
    func cancelExecution() {
        guard phase == .executing else { return }
        cancelRequested = true
        execution?.cancel()
    }

    private static func withoutAcknowledgement(_ blockers: [UUID: [Blocker]]) -> [UUID: [Blocker]] {
        blockers.compactMapValues { list in
            let rest = list.filter { $0 != .needsAcknowledgement }
            return rest.isEmpty ? nil : rest
        }
    }
}
