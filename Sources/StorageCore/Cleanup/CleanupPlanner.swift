import Foundation

/// Turns what the user put on the cleanup list into a `CleanupPlan` for review.
///
/// Locations become one step each: 🔴 is moved to the Trash, 🟢/🟡 deleted, with the item's
/// `FileID` captured now so the engine refuses to act if the path is replaced after review.
/// Inspector items are grouped by `inspectorID` and planned by their own inspector.
///
/// Defense in depth: locations that are not `.cleanable` and inspector items that are not
/// `isActionable` are dropped here even if the UI let them through. Tool-based items may have
/// empty `paths`; that alone does not make them informational.
public struct CleanupPlanner: Sendable {
    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        /// An item names an inspector that is not in the list passed to `plan`.
        case inspectorMissing(String)

        public var errorDescription: String? {
            switch self {
            case .inspectorMissing(let id): "No inspector named \"\(id)\" is available to plan this item."
            }
        }
    }

    /// A plan plus what was asked for but produced no step.
    public struct Result: Sendable {
        public let plan: CleanupPlan
        /// "Nothing to do for <title>…", one per location or item that yielded no step. For an
        /// inspector group of several items this is reported only when the whole group yields
        /// nothing; plan one item at a time for an exact per-item answer. Also "<path> no longer
        /// exists." for each inspector path step dropped because its path is gone.
        public let nothingToDo: [String]
    }

    public init() {}

    public func plan(
        locations: [AttributedLocation],
        items: [InspectorItem],
        inspectors: [any Inspector],
        context: InspectorContext
    ) async throws -> CleanupPlan {
        try await planReporting(locations: locations, items: items, inspectors: inspectors, context: context).plan
    }

    public func planReporting(
        locations: [AttributedLocation],
        items: [InspectorItem],
        inspectors: [any Inspector],
        context: InspectorContext
    ) async throws -> Result {
        var steps: [CleanupStep] = []
        var nothingToDo: [String] = []

        var seenPaths: Set<String> = []
        for location in locations where location.cleanability == .cleanable {
            guard seenPaths.insert(location.path).inserted else { continue }
            // Nothing there now: without an identity to check, whatever appears at this path
            // later could be removed, so no step at all.
            let display = Self.displayPath(location.path, home: context.home)
            guard let fileID = FileID.of(path: location.path) else {
                nothingToDo.append("Nothing to do for \(display): it no longer exists.")
                continue
            }
            let isUserData = location.risk == .userData
            steps.append(CleanupStep(
                title: isUserData ? "Move \(display) to Trash" : "Delete \(display)",
                risk: location.risk,
                estimatedBytes: location.allocatedBytes,
                requirement: location.requirement,
                action: isUserData
                    ? .trash(path: location.path, expectedFileID: fileID)
                    : .delete(path: location.path, expectedFileID: fileID),
                sideEffectNote: location.note
            ))
        }

        var groupOrder: [String] = []
        var groups: [String: [InspectorItem]] = [:]
        var seenItems: Set<String> = []
        for item in items where item.isActionable {
            guard seenItems.insert(item.inspectorID + "\u{0}" + item.id).inserted else { continue }
            if groups[item.inspectorID] == nil { groupOrder.append(item.inspectorID) }
            groups[item.inspectorID, default: []].append(item)
        }
        for inspectorID in groupOrder {
            guard let inspector = inspectors.first(where: { $0.id == inspectorID }) else {
                throw Failure.inspectorMissing(inspectorID)
            }
            let group = groups[inspectorID] ?? []
            let plan = try await inspector.plan(for: group, in: context)
            // An item the inspector lists but does not plan is reported, never silently dropped.
            if plan.steps.isEmpty {
                nothingToDo += group.map { "Nothing to do for \($0.title)." }
            }
            for step in plan.steps {
                switch Self.capturingIdentity(step) {
                case .success(let captured): steps.append(captured)
                case .failure(let missing):
                    nothingToDo.append("\(Self.displayPath(missing.path, home: context.home)) no longer exists.")
                }
            }
        }
        return Result(plan: CleanupPlan(steps: steps), nothingToDo: nothingToDo)
    }

    struct PathMissing: Error {
        let path: String
    }

    /// Fills in the identity of a path step the inspector left without one, so a path replaced
    /// between review and execution is skipped. Every other field is kept, including the id
    /// (acknowledgements use it).
    /// Fails when that path no longer exists: with no identity to check, whatever appears there
    /// later could be removed. Tool and JSON-edit steps pass through unchanged.
    static func capturingIdentity(_ step: CleanupStep) -> Swift.Result<CleanupStep, PathMissing> {
        let action: CleanupAction
        switch step.action {
        case .delete(let path, nil):
            guard let id = FileID.of(path: path) else { return .failure(PathMissing(path: path)) }
            action = .delete(path: path, expectedFileID: id)
        case .trash(let path, nil):
            guard let id = FileID.of(path: path) else { return .failure(PathMissing(path: path)) }
            action = .trash(path: path, expectedFileID: id)
        default:
            return .success(step)
        }
        return .success(CleanupStep(
            id: step.id, title: step.title, risk: step.risk, estimatedBytes: step.estimatedBytes,
            requirement: step.requirement, action: action, sideEffectNote: step.sideEffectNote,
            dependsOn: step.dependsOn, acknowledgement: step.acknowledgement))
    }

    /// Home-relative display form of a path (`~/Library/...`); paths outside `home` stay absolute.
    public static func displayPath(_ path: String, home: URL) -> String {
        let h = home.path
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }
}
