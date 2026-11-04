import Testing
import Foundation
@testable import StorageCore

@Suite struct SystemAdapterTests {
    private func makeHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SysAdapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(_ home: URL, _ rel: String, mode: Int) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    @Test func locatorFindsInFixtureDirs() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeFile(home, ".cargo/bin/cargo", mode: 0o755)
        try makeFile(home, ".cargo/bin/plain", mode: 0o644)
        let locator = ToolLocator(home: home, systemDirectories: [])
        #expect(locator.locate("cargo") == home.appendingPathComponent(".cargo/bin/cargo").path)
        #expect(locator.locate("plain") == nil)
        #expect(locator.locate("no-such-tool-xyz") == nil)
    }

    @Test func locatorPrefersNewestNvm() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeFile(home, ".nvm/versions/node/v18.0.0/bin/node", mode: 0o755)
        try makeFile(home, ".nvm/versions/node/v22.1.0/bin/node", mode: 0o755)
        try makeFile(home, ".nvm/versions/node/v9.0.0/bin/node", mode: 0o755)
        let locator = ToolLocator(home: home, systemDirectories: [])
        let found = try #require(locator.locate("node"))
        #expect(found.contains("/v22.1.0/"))
    }

    @Test func runnerCapturesOutput() async throws {
        let runner = ProcessToolRunner(locator: ToolLocator(home: try makeHome()))
        let out = try await runner.run("/bin/echo", ["hi"], timeout: .seconds(5))
        #expect(out.exitCode == 0)
        #expect(out.stdout == "hi\n")
    }

    @Test func runnerNonZeroExit() async throws {
        let runner = ProcessToolRunner(locator: ToolLocator(home: try makeHome()))
        let out = try await runner.run("/usr/bin/false", [], timeout: .seconds(5))
        #expect(out.exitCode == 1)
    }

    // The timeout tests check that the runner did not wait for the child, not that it was fast:
    // the bounds leave room for a loaded machine, and still fail if the runner waits out the sleep.

    @Test(.timeLimit(.minutes(1))) func runnerTimeout() async throws {
        let runner = ProcessToolRunner(locator: ToolLocator(home: try makeHome()))
        let start = ContinuousClock.now
        await #expect(throws: ToolTimeout.self) {
            _ = try await runner.run("/bin/sleep", ["60"], timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(15))
    }

    @Test(.timeLimit(.minutes(1))) func runnerTimeoutWithGrandchildHoldingPipe() async throws {
        let runner = ProcessToolRunner(locator: ToolLocator(home: try makeHome()))
        let start = ContinuousClock.now
        await #expect(throws: ToolTimeout.self) {
            _ = try await runner.run("/bin/sh", ["-c", "sleep 60 & sleep 60"], timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(15))
    }

    @Test(.timeLimit(.minutes(1))) func runnerReturnsAfterExitWhenGrandchildHoldsPipe() async throws {
        let runner = ProcessToolRunner(locator: ToolLocator(home: try makeHome()))
        let start = ContinuousClock.now
        // The shell exits at once; the background sleep inherits stdout and keeps it open.
        let out = try await runner.run("/bin/sh", ["-c", "echo hello; sleep 60 &"], timeout: .seconds(30))
        #expect(ContinuousClock.now - start < .seconds(15))
        #expect(out.exitCode == 0)
        #expect(out.stdout == "hello\n")
    }

    @Test func runnerStartsToolInItsOwnProcessGroup() async throws {
        let runner = ProcessToolRunner(locator: ToolLocator(home: try makeHome()))
        let out = try await runner.run("/bin/sh", ["-c", "echo $$; /bin/ps -o pgid= -p $$"], timeout: .seconds(10))
        let lines = out.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.count == 2)
        #expect(lines.first == lines.last)
        #expect(lines.first.flatMap { Int32($0) } != getpgrp())
    }

    /// The grandchild ignores SIGTERM, so it only dies if the runner escalates to SIGKILL for the group.
    @Test(.timeLimit(.minutes(1))) func runnerTimeoutKillsGrandchildren() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pidFile = home.appendingPathComponent("grandchild.pid").path
        let runner = ProcessToolRunner(locator: ToolLocator(home: home))
        let script = "trap '' TERM; /bin/sleep 60 & echo $! > '\(pidFile)'; wait"
        await #expect(throws: ToolTimeout.self) {
            _ = try await runner.run("/bin/sh", ["-c", script], timeout: .seconds(1))
        }
        let text = try String(contentsOfFile: pidFile, encoding: .utf8)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Once killed, the grandchild is reaped by launchd; give that a moment.
        let deadline = ContinuousClock.now + .seconds(10)
        while kill(pid, 0) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let alive = kill(pid, 0) == 0
        if alive { kill(pid, SIGKILL) }
        #expect(!alive, "grandchild \(pid) survived the timeout")
    }

    /// Cancelling the run stops the tool the same way a timeout does: SIGTERM, the grace period, then
    /// SIGKILL for the group.
    @Test(.timeLimit(.minutes(1))) func runnerCancellationKillsGrandchildren() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pidFile = home.appendingPathComponent("grandchild.pid").path
        let runner = ProcessToolRunner(locator: ToolLocator(home: home))
        let script = "trap '' TERM; /bin/sleep 60 & echo $! > '\(pidFile)'; wait"
        let run = Task { try await runner.run("/bin/sh", ["-c", script], timeout: .seconds(60)) }
        let started = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: pidFile) && ContinuousClock.now < started {
            try await Task.sleep(for: .milliseconds(20))
        }
        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        let text = try String(contentsOfFile: pidFile, encoding: .utf8)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let deadline = ContinuousClock.now + .seconds(10)
        while kill(pid, 0) == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let alive = kill(pid, 0) == 0
        if alive { kill(pid, SIGKILL) }
        #expect(!alive, "grandchild \(pid) survived the cancellation")
    }

    @Test func runnerLocateDelegates() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeFile(home, ".cargo/bin/cargo", mode: 0o755)
        let runner = ProcessToolRunner(locator: ToolLocator(home: home, systemDirectories: []))
        #expect(runner.locate("cargo") == home.appendingPathComponent(".cargo/bin/cargo").path)
    }

    @Test func processNameDetection() async {
        let checker = WorkspaceAppChecker()
        let name = ProcessInfo.processInfo.processName
        #expect(await checker.isRunning(bundleIDs: [], processNames: [name]))
        #expect(await checker.isRunning(bundleIDs: [], processNames: ["definitely-not-a-process-xyz"]) == false)
    }

    @Test func volumeStatsSane() throws {
        let stats = try VolumeInfo.stats()
        #expect(stats.totalBytes > stats.usedBytes)
        #expect(stats.usedBytes > 0)
        #expect(stats.localSnapshotCount >= 0)
        // The system volume is one volume of the container, not the container's whole used space.
        #expect(stats.systemVolumeBytes > 0)
        #expect(stats.systemVolumeBytes < stats.usedBytes / 2)
    }

    @Test func availableBytesMatchesVolumeTotals() throws {
        let stats = try VolumeInfo.stats(for: NSTemporaryDirectory())
        let available = try VolumeInfo.availableBytes(for: NSTemporaryDirectory())
        #expect(available > 0)
        #expect(available < stats.totalBytes)
    }

    @Test func availableBytesThrowsForMissingPath() {
        #expect(throws: (any Error).self) {
            try VolumeInfo.availableBytes(for: "/nonexistent-\(UUID().uuidString)")
        }
    }
}
