import Foundation

public enum CleanupAction: Sendable, Hashable {
    case delete(path: String, expectedFileID: FileID?)
    case trash(path: String, expectedFileID: FileID?)
    /// An absolute executable path plus an argument array; never a shell string. The engine runs
    /// it only if `ToolPolicy` allows that exact command.
    case runTool(executable: String, arguments: [String])
    /// Edits a JSON file in place. The engine backs up the original file to the Trash first, and
    /// only if `ToolPolicy` allows this file and these edits.
    case removeJSONKeys(path: String, edits: [JSONEdit])
}

/// One change inside a JSON file. Key paths are lists of object keys, starting at the root object.
public enum JSONEdit: Sendable, Hashable, Codable {
    /// Removes the key at the end of the key path, with its value.
    case removeKey([String])
    /// Removes every string element equal to `value` from the array at the key path.
    case removeArrayValue(keyPath: [String], value: String)

    /// Older log entries stored edits as plain key paths, with a final `"#value:<v>"` segment
    /// meaning "remove `<v>` from the array".
    init(legacyKeyPath keyPath: [String]) {
        let marker = "#value:"
        if keyPath.count >= 2, let last = keyPath.last, last.hasPrefix(marker) {
            self = .removeArrayValue(keyPath: Array(keyPath.dropLast()), value: String(last.dropFirst(marker.count)))
        } else {
            self = .removeKey(keyPath)
        }
    }
}

extension CleanupAction: Codable {
    // Written by hand so that log entries from before `JSONEdit` (`removeJSONKeys` with
    // `keyPaths`) still decode. The encoded shape is the one Swift synthesizes for enums.
    private enum CaseKey: String, CodingKey { case delete, trash, runTool, removeJSONKeys }
    private enum PathKeys: String, CodingKey { case path, expectedFileID }
    private enum ToolKeys: String, CodingKey { case executable, arguments }
    private enum EditKeys: String, CodingKey { case path, edits, keyPaths }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath, debugDescription: "Expected exactly one cleanup action"))
        }
        switch key {
        case .delete, .trash:
            let values = try container.nestedContainer(keyedBy: PathKeys.self, forKey: key)
            let path = try values.decode(String.self, forKey: .path)
            let id = try values.decodeIfPresent(FileID.self, forKey: .expectedFileID)
            self = key == .delete ? .delete(path: path, expectedFileID: id) : .trash(path: path, expectedFileID: id)
        case .runTool:
            let values = try container.nestedContainer(keyedBy: ToolKeys.self, forKey: key)
            self = .runTool(
                executable: try values.decode(String.self, forKey: .executable),
                arguments: try values.decode([String].self, forKey: .arguments))
        case .removeJSONKeys:
            let values = try container.nestedContainer(keyedBy: EditKeys.self, forKey: key)
            let path = try values.decode(String.self, forKey: .path)
            if let edits = try values.decodeIfPresent([JSONEdit].self, forKey: .edits) {
                self = .removeJSONKeys(path: path, edits: edits)
            } else {
                let keyPaths = try values.decode([[String]].self, forKey: .keyPaths)
                self = .removeJSONKeys(path: path, edits: keyPaths.map(JSONEdit.init(legacyKeyPath:)))
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .delete(let path, let id), .trash(let path, let id):
            let key: CaseKey = if case .delete = self { .delete } else { .trash }
            var values = container.nestedContainer(keyedBy: PathKeys.self, forKey: key)
            try values.encode(path, forKey: .path)
            try values.encodeIfPresent(id, forKey: .expectedFileID)
        case .runTool(let executable, let arguments):
            var values = container.nestedContainer(keyedBy: ToolKeys.self, forKey: .runTool)
            try values.encode(executable, forKey: .executable)
            try values.encode(arguments, forKey: .arguments)
        case .removeJSONKeys(let path, let edits):
            var values = container.nestedContainer(keyedBy: EditKeys.self, forKey: .removeJSONKeys)
            try values.encode(path, forKey: .path)
            try values.encode(edits, forKey: .edits)
        }
    }
}

public struct CleanupStep: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public let title: String
    public let risk: RiskLevel
    public let estimatedBytes: Int64
    public let requirement: AppStateRequirement
    public let action: CleanupAction
    public let sideEffectNote: String?
    /// The id of an earlier step in the same plan that must have completed (trashed, freed or
    /// edited) for this one to run; otherwise the engine skips this step. Absent in older data.
    public let dependsOn: UUID?
    /// What the user confirms for a 🔴 step, when it differs from the item's `whatYouLose`.
    /// For example, a step that edits a settings file rather than removing the item itself.
    /// Nil: the item's `whatYouLose` applies. Absent in older data.
    public let acknowledgement: String?

    public init(
        id: UUID = UUID(),
        title: String,
        risk: RiskLevel,
        estimatedBytes: Int64,
        requirement: AppStateRequirement,
        action: CleanupAction,
        sideEffectNote: String? = nil,
        dependsOn: UUID? = nil,
        acknowledgement: String? = nil
    ) {
        self.id = id
        self.title = title
        self.risk = risk
        self.estimatedBytes = estimatedBytes
        self.requirement = requirement
        self.action = action
        self.sideEffectNote = sideEffectNote
        self.dependsOn = dependsOn
        self.acknowledgement = acknowledgement
    }

    /// What `CleanupEngine` will actually do: a 🔴 (`userData`) `.delete` is moved to the Trash
    /// instead, whatever the plugin asked for. Every other action is performed as planned.
    public var effectiveAction: CleanupAction {
        if risk == .userData, case .delete(let path, let expectedFileID) = action {
            return .trash(path: path, expectedFileID: expectedFileID)
        }
        return action
    }

    /// Whether the step cannot be undone, judged by `effectiveAction`: true for a permanent
    /// delete and for a tool step; false for a move to the Trash (including a 🔴 delete the
    /// engine trashes) and for a JSON edit, whose original is backed up to the Trash.
    /// Computed, so it is not part of the JSON.
    public var isIrreversible: Bool {
        switch effectiveAction {
        case .delete, .runTool: true
        case .trash, .removeJSONKeys: false
        }
    }
}

public struct CleanupPlan: Sendable, Hashable, Codable {
    public var steps: [CleanupStep]

    public init(steps: [CleanupStep]) {
        self.steps = steps
    }

    /// The plan with every step that moves a folder to the Trash ahead of the steps for paths
    /// inside that folder, so what lies inside goes to the Trash with it (and the inner steps
    /// find nothing left to do) instead of being deleted first. Plans made one item at a time,
    /// such as clearing a profile's cache and removing the profile, need this to run safely in
    /// either order. Moved steps keep their relative order; a step with `dependsOn` is never
    /// moved, so it stays after its dependency. Every other step keeps its place.
    public func orderedForExecution() -> CleanupPlan {
        let paths = steps.map(Self.path(of:))
        let first = steps.indices.filter { index in
            guard steps[index].dependsOn == nil,
                  case .trash(let folder, _) = steps[index].effectiveAction else { return false }
            let key = PathKey(folder)
            return paths.contains { $0.map { PathKey($0).isInside(key) } ?? false }
        }
        guard !first.isEmpty else { return self }
        let moved = Set(first)
        return CleanupPlan(steps: first.map { steps[$0] } + steps.indices.filter { !moved.contains($0) }.map { steps[$0] })
    }

    private static func path(of step: CleanupStep) -> String? {
        switch step.action {
        case .delete(let path, _), .trash(let path, _), .removeJSONKeys(let path, _): path
        case .runTool: nil
        }
    }
}
