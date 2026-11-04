import Foundation
import Synchronization

public struct ToolTimeout: Error, Sendable, Equatable {
    public let executable: String
    public init(executable: String) { self.executable = executable }
}

public struct ProcessToolRunner: ToolRunning {
    private let locator: ToolLocator

    public init(locator: ToolLocator) { self.locator = locator }

    public func locate(_ name: String) -> String? { locator.locate(name) }

    public func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> ToolOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = locator.directories.joined(separator: ":")
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let exited = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in
            exited.continuation.yield()
            exited.continuation.finish()
        }
        try process.run()
        // Checked now, while the tool is certainly alive; see `stop`.
        let ownsGroup = Self.leadsOwnGroup(process.processIdentifier)

        let out = PipeCollector(outPipe.fileHandleForReading)
        let err = PipeCollector(errPipe.fileHandleForReading)

        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exited.stream { return false }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return !Task.isCancelled
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if timedOut || Task.isCancelled {
            await stop(process, ownsGroup: ownsGroup)
            // A grandchild may still hold the pipes open, so the reads are abandoned
            // rather than awaited; they finish on their own when the pipes close.
            if timedOut { throw ToolTimeout(executable: executable) }
            throw CancellationError()
        }
        // The process has exited, but a grandchild it left running may hold the pipes open, so
        // EOF is awaited only briefly; then whatever was read so far is returned.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await out.waitForEOF()
                await err.waitForEOF()
            }
            group.addTask { try? await Task.sleep(for: Self.eofGrace) }
            await group.next()
            group.cancelAll()
        }
        return ToolOutput(
            exitCode: process.terminationStatus,
            stdout: String(decoding: out.data, as: UTF8.self),
            stderr: String(decoding: err.data, as: UTF8.self))
    }

    /// How long to wait for pipe EOF after the process exited.
    static let eofGrace: Duration = .seconds(2)

    /// How long the tool and its workers get to exit after SIGTERM before SIGKILL.
    static let terminationGrace: Duration = .seconds(1)

    /// Stops the tool and every process it started in its process group: SIGTERM, then SIGKILL
    /// for whatever is left after `terminationGrace`.
    ///
    /// `Process` starts the tool as the leader of a new process group (`runnerStartsToolInItsOwnProcessGroup`
    /// checks this), so its pid is the group id, and the group lives on while any worker does, even
    /// after the tool itself exited. When the tool did not lead its own group, signalling a group
    /// could reach this app's own, so only the tool is signalled.
    private func stop(_ process: Process, ownsGroup: Bool) async {
        let pid = process.processIdentifier
        func signal(_ number: Int32) {
            if ownsGroup {
                kill(-pid, number)
            } else if process.isRunning {
                kill(pid, number)
            }
        }
        func anyAlive() -> Bool {
            ownsGroup ? kill(-pid, 0) == 0 : process.isRunning
        }

        signal(SIGTERM)
        let deadline = ContinuousClock.now + Self.terminationGrace
        while anyAlive() && ContinuousClock.now < deadline {
            // When the run was cancelled, `Task.sleep` would throw at once and turn this into a busy
            // loop. An unstructured task does not inherit the cancellation, so its sleep really waits.
            await Task { try? await Task.sleep(for: .milliseconds(10)) }.value
        }
        if anyAlive() { signal(SIGKILL) }
    }

    private static func leadsOwnGroup(_ pid: pid_t) -> Bool {
        getpgid(pid) == pid && pid != getpgrp()
    }
}

/// Collects a pipe's output on a GCD thread, so a blocking read never occupies the cooperative
/// pool, and keeps what has arrived so far readable before EOF.
private final class PipeCollector: Sendable {
    private let received = Mutex(Data())
    private let eof: AsyncStream<Void>
    private let eofContinuation: AsyncStream<Void>.Continuation

    init(_ handle: FileHandle) {
        (eof, eofContinuation) = AsyncStream.makeStream()
        DispatchQueue.global().async { [self] in
            // POSIX `read` returns each chunk as it arrives and reports errors by value (FileHandle's
            // `availableData` raises an exception on error; `read(upToCount:)` waits for a full count).
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    received.withLock { $0.append(contentsOf: buffer[0..<count]) }
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break  // EOF or a read error.
                }
            }
            eofContinuation.finish()
        }
    }

    var data: Data { received.withLock { $0 } }

    /// Returns at EOF, or when the calling task is cancelled.
    func waitForEOF() async {
        for await _ in eof {}
    }
}
