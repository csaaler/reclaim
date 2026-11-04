import Foundation
import Testing
import StorageCore
import StorageTestKit

@Suite struct TestKitTests {
    @Test func fixtureFileWritesByteCount() throws {
        let fixture = try FixtureHome()
        try fixture.file("a/b.bin", bytes: 4321)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.home.path + "/a/b.bin")
        #expect((attributes[.size] as? NSNumber)?.intValue == 4321)
    }

    @Test func fixtureDeletesItselfOnDeinit() throws {
        var fixture: FixtureHome? = try FixtureHome()
        let path = fixture!.home.path
        #expect(FileManager.default.fileExists(atPath: path))
        fixture = nil
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func logicalSizerSumsFixtureFiles() async throws {
        let fixture = try FixtureHome()
        try fixture.file("d/one", bytes: 100)
        try fixture.file("d/two", bytes: 200)
        try fixture.file("d/sub/three", bytes: 300)
        try fixture.symlink("d/link", to: fixture.home.path + "/d/one")
        let size = await LogicalSizer().allocatedSize(of: fixture.home.path + "/d")
        #expect(size == 600)
    }

    @Test func fakeToolRunnerRecordsInvocationsAndThrowsForUnstubbed() async throws {
        let runner = FakeToolRunner(tools: ["docker": "/usr/local/bin/docker"])
        runner.stub("/usr/local/bin/docker", ["ps"], output: ToolOutput(exitCode: 0, stdout: "ok", stderr: ""))

        #expect(runner.locate("docker") == "/usr/local/bin/docker")
        #expect(runner.locate("git") == nil)
        let output = try await runner.run("/usr/local/bin/docker", ["ps"], timeout: .seconds(1))
        #expect(output.stdout == "ok")
        await #expect(throws: (any Error).self) {
            try await runner.run("/usr/local/bin/docker", ["rm"], timeout: .seconds(1))
        }
        let invocations = runner.invocations
        #expect(invocations.count == 2)
        #expect(invocations.first?.0 == "/usr/local/bin/docker")
        #expect(invocations.first?.1 == ["ps"])
    }

    @Test func fakeAppCheckerReportsRunningAndQuits() async {
        let checker = FakeAppChecker()
        checker.running = ["com.x"]
        #expect(await checker.isRunning(bundleIDs: ["com.x"], processNames: []))
        checker.quitSucceeds = false
        #expect(await checker.requestQuit(bundleIDs: ["com.x"]) == false)
        checker.quitSucceeds = true
        #expect(await checker.requestQuit(bundleIDs: ["com.x"]))
        #expect(await checker.isRunning(bundleIDs: ["com.x"], processNames: []) == false)
    }
}
