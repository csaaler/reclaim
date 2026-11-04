import Foundation

public struct ToolOutput: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ToolRunning: Sendable {
    /// Absolute path of the tool, or nil when it is not installed.
    func locate(_ name: String) -> String?
    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> ToolOutput
}

public protocol RunningAppChecking: Sendable {
    func isRunning(bundleIDs: [String], processNames: [String]) async -> Bool
    /// Graceful quit only. True if the apps quit within 10 s.
    func requestQuit(bundleIDs: [String]) async -> Bool
}

public protocol SizeMeasuring: Sendable {
    func allocatedSize(of path: String) async -> Int64
}

/// Why the engine refused to act on a step. The associated value is the path, or for
/// `toolNotAllowed` the command line.
public enum SafetyViolation: Error, Sendable, Equatable {
    case protected(String)
    case outsideAllowedRoots(String)
    case notFound(String)
    case identityChanged(String)
    /// The path does not start with `/`.
    case notAbsolute(String)
    /// The path has a `.` or `..` component or a NUL byte.
    case notStandardized(String)
    /// A `runTool` step that `ToolPolicy` does not allow.
    case toolNotAllowed(String)
    /// A `removeJSONKeys` step that `ToolPolicy` does not allow (file or edits).
    case editNotAllowed(String)
}

public protocol PathValidating: Sendable {
    /// Returns the resolved path.
    func validate(_ path: String, expectedFileID: FileID?) throws(SafetyViolation) -> String
}

public protocol FileOperating: Sendable {
    func remove(_ path: String) throws
    /// Returns the trashed location.
    func trash(_ path: String) throws -> String
    func read(_ path: String) throws -> Data
    func write(_ data: Data, to path: String) throws
}
