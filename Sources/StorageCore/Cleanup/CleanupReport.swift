import Foundation

/// Why a step cannot run right now.
public enum Blocker: Sendable, Hashable {
    case appRunning(name: String, bundleIDs: [String])
    case appNotRunning(reason: String)
    case needsAcknowledgement
    /// A path that fails `PathValidator`, or a command or file edit that `ToolPolicy` does not allow.
    case invalidPath(SafetyViolation)

    // `SafetyViolation` is Equatable but not Hashable, so Hashable is written by hand.
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .appRunning(let name, let bundleIDs):
            hasher.combine(0)
            hasher.combine(name)
            hasher.combine(bundleIDs)
        case .appNotRunning(let reason):
            hasher.combine(1)
            hasher.combine(reason)
        case .needsAcknowledgement:
            hasher.combine(2)
        case .invalidPath(let violation):
            hasher.combine(3)
            hasher.combine(violation.message)
        }
    }

    /// Shown to the user and used as the `.skipped` reason.
    public var message: String {
        switch self {
        case .appRunning(let name, _): "\(name) is running. Quit it first."
        case .appNotRunning(let reason): reason
        case .needsAcknowledgement: "Needs your confirmation: this is your data or config."
        case .invalidPath(let violation): violation.message
        }
    }
}

extension SafetyViolation {
    var message: String {
        switch self {
        case .protected(let path): "\(path) is protected."
        case .outsideAllowedRoots(let path): "\(path) is outside the locations cleanup may touch."
        case .notFound(let path): "\(path) no longer exists."
        case .identityChanged(let path): "\(path) changed since it was reviewed."
        case .notAbsolute(let path): "\(path) is not an absolute path."
        case .notStandardized(let path): "\(path) contains \".\", \"..\" or a NUL character."
        case .toolNotAllowed(let command): "\(command) is not a command cleanup may run."
        case .editNotAllowed(let path): "\(path) is not a file cleanup may edit this way."
        }
    }
}

public enum StepOutcome: Sendable, Hashable, Codable {
    /// Deleted permanently (or freed by a tool); the space is available now.
    case freed(bytes: Int64)
    /// Moved to the Trash; frees space after emptying Trash.
    case trashed(bytes: Int64, trashPath: String)
    /// A file edited in place (`removeJSONKeys`); the original was moved to the Trash first.
    /// Frees no space by itself, so it counts toward neither total.
    case edited(backupTrashPath: String)
    case skipped(reason: String)
    case failed(message: String)
}

public struct CleanupReport: Sendable {
    /// One result per plan step, in plan order.
    public let results: [(step: CleanupStep, outcome: StepOutcome)]
    /// One message per log entry that could not be written. Execution continues regardless,
    /// so the UI must show these: the steps ran, but the history is incomplete.
    public let logFailures: [String]

    public init(results: [(step: CleanupStep, outcome: StepOutcome)], logFailures: [String] = []) {
        self.results = results
        self.logFailures = logFailures
    }

    public var freedBytes: Int64 {
        results.reduce(0) { total, result in
            if case .freed(let bytes) = result.outcome { total + bytes } else { total }
        }
    }

    /// Counted separately: these bytes are only freed after emptying the Trash.
    public var trashedBytes: Int64 {
        results.reduce(0) { total, result in
            if case .trashed(let bytes, _) = result.outcome { total + bytes } else { total }
        }
    }
}
