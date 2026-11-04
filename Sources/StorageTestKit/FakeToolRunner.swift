import StorageCore
import Synchronization

/// A `ToolRunning` that returns stubbed output and records every invocation.
public final class FakeToolRunner: ToolRunning {
    public struct Unstubbed: Error, Sendable, Equatable {
        public let executable: String
        public let arguments: [String]
    }

    private struct Key: Hashable {
        let executable: String
        let arguments: [String]
    }

    private struct State {
        var stubs: [Key: ToolOutput] = [:]
        var invocations: [(String, [String])] = []
    }

    private let tools: [String: String]
    private let state = Mutex(State())

    /// `tools` maps tool names to the absolute paths `locate` returns.
    public init(tools: [String: String] = [:]) {
        self.tools = tools
    }

    public func stub(_ executable: String, _ arguments: [String], output: ToolOutput) {
        state.withLock { $0.stubs[Key(executable: executable, arguments: arguments)] = output }
    }

    public var invocations: [(String, [String])] {
        state.withLock { $0.invocations }
    }

    public func locate(_ name: String) -> String? {
        tools[name]
    }

    /// Throws `Unstubbed` when no output was stubbed for this exact executable and argument list.
    public func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> ToolOutput {
        let output = state.withLock { state in
            state.invocations.append((executable, arguments))
            return state.stubs[Key(executable: executable, arguments: arguments)]
        }
        guard let output else { throw Unstubbed(executable: executable, arguments: arguments) }
        return output
    }
}
