import Foundation
import Testing
import StorageCore
import StorageInspectors
import StorageTestKit

@Suite struct DockerInspectorTests {
    static let docker = "/usr/local/bin/docker"
    static let dfArgs = ["system", "df", "--format", "{{json .}}"]
    static let requirement = AppStateRequirement.mustBeRunning(
        bundleIDs: ["com.docker.docker"],
        processNames: ["com.docker.backend"],
        reason: "Docker must be running to prune"
    )

    static let df = """
    {"Active":"19","Reclaimable":"12.3GB (45%)","Size":"18.55GB","TotalCount":"207","Type":"Images"}
    {"Active":"1","Reclaimable":"107.5MB (99%)","Size":"107.5MB","TotalCount":"20","Type":"Containers"}
    {"Active":"13","Reclaimable":"1.964GB (63%)","Size":"3.095GB","TotalCount":"67","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"39.97MB","Size":"5.939GB","TotalCount":"223","Type":"Build Cache"}
    """

    func context(stdout: String = df, exit: Int32 = 0, stderr: String = "", installed: Bool = true) throws
        -> (InspectorContext, FakeToolRunner, FixtureHome)
    {
        let fixture = try FixtureHome()
        let tools = FakeToolRunner(tools: installed ? ["docker": Self.docker] : [:])
        tools.stub(Self.docker, Self.dfArgs, output: ToolOutput(exitCode: exit, stdout: stdout, stderr: stderr))
        return (InspectorContext(home: fixture.home, tools: tools, sizer: LogicalSizer()), tools, fixture)
    }

    @Test func discoversFourItemsWithParsedBytesThenPlansExactTools() async throws {
        let (ctx, _, _) = try context()
        let inspector = DockerInspector()
        let items = try await inspector.discover(in: ctx)
        #expect(items.map(\.id) == ["docker.images.unused", "docker.containers.stopped", "docker.volumes.unused", "docker.buildcache.all"])
        #expect(items.map(\.title) == ["Unused images", "Stopped containers", "Unused volumes", "Build cache"])
        #expect(items.map(\.risk) == [.rebuildable, .rebuildable, .userData, .cache])
        #expect(items.map(\.allocatedBytes) == [12_300_000_000, 107_500_000, 1_964_000_000, 39_970_000])
        #expect(items.allSatisfy { $0.requirement == Self.requirement && $0.lastUsed == nil })
        #expect(items[1].whatYouLose == "Files changed inside stopped containers")
        #expect(items[2].whatYouLose == "Data in volumes not attached to any container, e.g. local databases")

        let plan = try await inspector.plan(for: items, in: ctx)
        let expected: [[String]] = [
            ["image", "prune", "-a", "-f"],
            ["container", "prune", "-f"],
            ["volume", "prune", "-a", "-f"],
            ["builder", "prune", "-a", "-f"],
        ]
        #expect(plan.steps.map(\.action) == expected.map { .runTool(executable: Self.docker, arguments: $0) })
        #expect(plan.steps.map(\.estimatedBytes) == items.map(\.allocatedBytes))
        #expect(plan.steps.map(\.risk) == items.map(\.risk))
        #expect(plan.steps.allSatisfy { $0.requirement == Self.requirement })
    }

    @Test func zeroOmittedAndInvalidKeptWithUnknownSizeWhenObjectsExist() async throws {
        let out = """
        {"Active":"19","TotalCount":"207","Reclaimable":"-6.732e+10B (-362%)","Type":"Images"}
        {"Active":"1","TotalCount":"1","Reclaimable":"-5B","Type":"Containers"}
        {"Active":"0","TotalCount":"3","Reclaimable":"2.5kB","Type":"Local Volumes"}
        {"Active":"0","TotalCount":"0","Reclaimable":"0B","Type":"Build Cache"}
        """
        let (ctx, _, _) = try context(stdout: out)
        let items = try await DockerInspector().discover(in: ctx)
        #expect(items.map(\.id) == ["docker.images.unused", "docker.volumes.unused"])
        #expect(items.map(\.allocatedBytes) == [0, 2500])
        #expect(items[0].subtitle == "Reclaimable size unknown (Docker reported an invalid value)")
        #expect(items[1].subtitle == nil)
    }

    struct ThrowingRunner: ToolRunning {
        let error: any Error
        func locate(_ name: String) -> String? { "/usr/local/bin/docker" }
        func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> ToolOutput { throw error }
    }
    struct TimedOut: Error {}

    @Test func cancellationPropagates() async throws {
        let ctx = InspectorContext(home: URL(fileURLWithPath: "/nonexistent"), tools: ThrowingRunner(error: CancellationError()), sizer: LogicalSizer())
        await #expect(throws: CancellationError.self) { try await DockerInspector().discover(in: ctx) }
    }

    @Test func otherRunErrorsAreNotReportedAsDaemonDown() async throws {
        let ctx = InspectorContext(home: URL(fileURLWithPath: "/nonexistent"), tools: ThrowingRunner(error: TimedOut()), sizer: LogicalSizer())
        do {
            _ = try await DockerInspector().discover(in: ctx)
            Issue.record("expected throw")
        } catch let e as InspectorUnavailable {
            #expect(e.reason.hasPrefix("Couldn't query Docker: "))
            #expect(!e.reason.contains("not running"))
        }
    }

    @Test func daemonDownThrowsUnavailable() async throws {
        let msg = "Docker is not running — start Docker Desktop to inspect it"
        for (code, err) in [
            (Int32(1), "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"),
            (Int32(1), "failed to connect to the docker API at unix:///x.sock; check if the path is correct and if the daemon is running"),
            (Int32(0), "Cannot connect to the Docker daemon"),
        ] {
            let (ctx, _, _) = try context(stdout: "", exit: code, stderr: err)
            await #expect(throws: InspectorUnavailable.self) { try await DockerInspector().discover(in: ctx) }
            do { _ = try await DockerInspector().discover(in: ctx) } catch let e as InspectorUnavailable {
                #expect(e.reason == msg)
            }
        }
    }

    @Test func missingDockerThrowsNotInstalled() async throws {
        let (ctx, tools, _) = try context(installed: false)
        do {
            _ = try await DockerInspector().discover(in: ctx)
            Issue.record("expected throw")
        } catch let e as InspectorUnavailable {
            #expect(e.reason == "Docker is not installed")
        }
        #expect(tools.invocations.isEmpty)
    }

    @Test func planOnlyIncludesSelectedItems() async throws {
        let (ctx, _, _) = try context()
        let inspector = DockerInspector()
        let items = try await inspector.discover(in: ctx)
        let plan = try await inspector.plan(for: [items[3]], in: ctx)
        #expect(plan.steps.map(\.action) == [.runTool(executable: Self.docker, arguments: ["builder", "prune", "-a", "-f"])])
    }
}
