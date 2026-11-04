import Foundation
import Testing
import StorageCore
import StorageTestKit
@testable import StorageInspectors

@Suite struct XcodeInspectorTests {
    static let xcrun = "/usr/bin/xcrun"
    static let xcodeSelect = "/usr/bin/xcode-select"

    /// Command line tools installed: `xcode-select -p` succeeds.
    static func runner() -> FakeToolRunner {
        let runner = FakeToolRunner(tools: ["xcrun": xcrun])
        runner.stub(xcodeSelect, ["-p"], output: ToolOutput(exitCode: 0, stdout: "/Library/Developer/CommandLineTools\n", stderr: ""))
        return runner
    }
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let old = now.addingTimeInterval(-200 * 86_400)
    static let recent = now.addingTimeInterval(-5 * 86_400)

    static let devicesJSON = """
    Install Started
    {
      "devices" : {
        "com.apple.CoreSimulator.SimRuntime.iOS-17-5" : [
          { "dataPath" : "/x/A1A1A1A1-0000-4000-8000-00000000000A/data", "dataPathSize" : 100, "udid" : "A1A1A1A1-0000-4000-8000-00000000000A", "isAvailable" : true,
            "deviceTypeIdentifier" : "t", "state" : "Shutdown", "name" : "iPhone Old" },
          { "lastBootedAt" : "2026-10-30T10:00:00Z", "udid" : "B2B2B2B2-0000-4000-8000-00000000000B", "isAvailable" : true,
            "state" : "Shutdown", "name" : "iPhone Recent" }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-16-0" : [
          { "udid" : "C3C3C3C3-0000-4000-8000-00000000000C", "isAvailable" : false, "availabilityError" : "runtime profile not found",
            "state" : "Shutdown", "name" : "iPhone Gone" },
          { "udid" : "D4D4D4D4-0000-4000-8000-00000000000D", "isAvailable" : false, "state" : "Shutdown", "name" : "iPad Gone" }
        ]
      }
    }
    """

    static let runtimesJSON = """
    {
      "5E3B6C1A-7D2F-4A8B-9C0D-1E2F3A4B5C6D" : { "build" : "21F79", "deletable" : true, "identifier" : "5E3B6C1A-7D2F-4A8B-9C0D-1E2F3A4B5C6D",
        "lastUsedAt" : "2024-10-18T14:50:34Z", "platformIdentifier" : "com.apple.platform.iphonesimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.iOS-17-5", "sizeBytes" : 7336630623, "version" : "17.5" },
      "0B1C2D3E-4F5A-4B6C-8D7E-9F0A1B2C3D4E" : { "deletable" : true, "identifier" : "0B1C2D3E-4F5A-4B6C-8D7E-9F0A1B2C3D4E", "platformIdentifier" : "com.apple.platform.watchsimulator",
        "runtimeIdentifier" : "com.apple.CoreSimulator.SimRuntime.watchOS-10-0", "sizeBytes" : 2000, "version" : "10.0" }
    }
    """

    func setup() throws -> (FixtureHome, InspectorContext, XcodeInspector) {
        let fixture = try FixtureHome()
        let runner = Self.runner()
        runner.stub(Self.xcrun, ["simctl", "list", "devices", "--json"], output: ToolOutput(exitCode: 0, stdout: Self.devicesJSON, stderr: ""))
        runner.stub(Self.xcrun, ["simctl", "runtime", "list", "-j"], output: ToolOutput(exitCode: 0, stdout: Self.runtimesJSON, stderr: ""))
        let sim = "Library/Developer/CoreSimulator/Devices"
        try fixture.file("\(sim)/A1A1A1A1-0000-4000-8000-00000000000A/data/a.bin", bytes: 1000, modified: nil)
        try FileManager.default.setAttributes([.modificationDate: Self.old], ofItemAtPath: fixture.home.path + "/\(sim)/A1A1A1A1-0000-4000-8000-00000000000A/data")
        try fixture.file("\(sim)/B2B2B2B2-0000-4000-8000-00000000000B/data/b.bin", bytes: 500)
        try FileManager.default.setAttributes([.modificationDate: Self.recent], ofItemAtPath: fixture.home.path + "/\(sim)/B2B2B2B2-0000-4000-8000-00000000000B/data")
        try fixture.file("\(sim)/C3C3C3C3-0000-4000-8000-00000000000C/data/c.bin", bytes: 300)
        try fixture.file("\(sim)/D4D4D4D4-0000-4000-8000-00000000000D/data/d.bin", bytes: 200)
        try fixture.file("Library/Developer/Xcode/DerivedData/MyApp-abcdefghijklmnopqrstuvwxyzab/Build/x", bytes: 400)
        try fixture.file("Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79)/sym", bytes: 600)
        try fixture.file("Library/Developer/CoreSimulator/Caches/dyld/blob", bytes: 700)
        try fixture.file("Library/Developer/Xcode/Archives/2026-01-01/MyApp.xcarchive/Info.plist", bytes: 800)
        try fixture.file("SystemLib/Caches/root.bin", bytes: 900)
        let context = InspectorContext(home: fixture.home, tools: runner, sizer: LogicalSizer(), now: Self.now)
        let inspector = XcodeInspector(adminCachesRoot: fixture.home.path + "/SystemLib/Caches")
        return (fixture, context, inspector)
    }

    @Test func discoversExpectedItems() async throws {
        let (fixture, context, inspector) = try setup()
        let items = try await inspector.discover(in: context)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(byID.count == items.count)

        let unavailable = try #require(byID["xcode.unavailable-devices"])
        #expect(unavailable.risk == .rebuildable)
        #expect(unavailable.allocatedBytes == 500)
        #expect(unavailable.paths.count == 2)

        let stale = try #require(byID["xcode.device.A1A1A1A1-0000-4000-8000-00000000000A"])
        #expect(stale.title == "iPhone Old")
        #expect(stale.risk == .userData)
        #expect(stale.allocatedBytes == 1000)
        #expect(stale.lastUsed == Self.old)
        #expect(stale.requirement == .mustBeQuit(bundleIDs: ["com.apple.iphonesimulator"], processNames: []))
        #expect(byID["xcode.device.B2B2B2B2-0000-4000-8000-00000000000B"] == nil)

        let runtime = try #require(byID["xcode.runtime.5E3B6C1A-7D2F-4A8B-9C0D-1E2F3A4B5C6D"])
        #expect(runtime.title == "iOS 17.5")
        #expect(runtime.lastUsed == ISO8601DateFormatter().date(from: "2024-10-18T14:50:34Z"))
        #expect(runtime.risk == .rebuildable)
        #expect(runtime.allocatedBytes == 7_336_630_623)
        #expect(runtime.subtitle == "In use by 2 devices — they'll be deleted too")
        let watch = try #require(byID["xcode.runtime.0B1C2D3E-4F5A-4B6C-8D7E-9F0A1B2C3D4E"])
        #expect(watch.subtitle == nil)

        let derived = try #require(byID["xcode.derived.MyApp-abcdefghijklmnopqrstuvwxyzab"])
        #expect(derived.title == "MyApp")
        #expect(derived.risk == .cache)
        #expect(derived.allocatedBytes == 400)
        #expect(derived.lastUsed != nil)
        #expect(derived.requirement == .mustBeQuit(bundleIDs: ["com.apple.dt.Xcode"], processNames: []))

        let support = try #require(byID["xcode.support.iOS DeviceSupport/17.5 (21F79)"])
        #expect(support.risk == .rebuildable)
        #expect(support.allocatedBytes == 600)

        let cache = try #require(byID["xcode.cache.dyld"])
        #expect(cache.risk == .cache)
        #expect(cache.allocatedBytes == 700)

        let admin = try #require(byID["xcode.system-cache"])
        #expect(admin.subtitle == "requires admin")
        #expect(!admin.isActionable)
        #expect(cache.isActionable)
        #expect(admin.allocatedBytes == 900)

        let archive = try #require(byID["xcode.archive.2026-01-01/MyApp.xcarchive"])
        #expect(archive.risk == .userData)
        #expect(archive.title == "MyApp")
        #expect(archive.lastUsed != nil)
        _ = fixture
    }

    @Test func plansExactActionsAndExcludesAdminCache() async throws {
        let (fixture, context, inspector) = try setup()
        let items = try await inspector.discover(in: context)
        let plan = try await inspector.plan(for: items, in: context)
        let actions = plan.steps.map(\.action)
        let home = fixture.home.path

        #expect(actions.contains(.runTool(executable: Self.xcrun, arguments: ["simctl", "delete", "unavailable"])))
        #expect(actions.contains(.runTool(executable: Self.xcrun, arguments: ["simctl", "delete", "A1A1A1A1-0000-4000-8000-00000000000A"])))
        #expect(actions.contains(.runTool(executable: Self.xcrun, arguments: ["simctl", "runtime", "delete", "5E3B6C1A-7D2F-4A8B-9C0D-1E2F3A4B5C6D"])))
        #expect(actions.contains(.delete(path: home + "/Library/Developer/Xcode/DerivedData/MyApp-abcdefghijklmnopqrstuvwxyzab", expectedFileID: nil)))
        #expect(actions.contains(.delete(path: home + "/Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79)", expectedFileID: nil)))
        #expect(actions.contains(.delete(path: home + "/Library/Developer/CoreSimulator/Caches/dyld", expectedFileID: nil)))
        #expect(actions.contains(.trash(path: home + "/Library/Developer/Xcode/Archives/2026-01-01/MyApp.xcarchive", expectedFileID: nil)))
        #expect(!actions.contains { if case .delete(let path, _) = $0 { path.contains("SystemLib") } else { false } })
        #expect(plan.steps.count == 8)
        let deleteStale = try #require(plan.steps.first { $0.action == .runTool(executable: Self.xcrun, arguments: ["simctl", "delete", "A1A1A1A1-0000-4000-8000-00000000000A"]) })
        #expect(deleteStale.risk == .userData)
        // Every planned tool step is one the engine would run.
        let policy = ToolPolicy(home: fixture.home)
        for step in plan.steps {
            #expect(policy.violation(for: step.action, locate: context.tools.locate) == nil, "\(step.action)")
        }
    }

    @Test func throwsWhenXcrunMissing() async throws {
        let fixture = try FixtureHome()
        let context = InspectorContext(home: fixture.home, tools: FakeToolRunner(), sizer: LogicalSizer(), now: Self.now)
        await #expect(throws: InspectorUnavailable.self) {
            try await XcodeInspector().discover(in: context)
        }
    }

    @Test func failedSimctlYieldsErrorItemsAndKeepsFilesystemItems() async throws {
        let (fixture, _, inspector) = try setup()
        let runner = Self.runner()
        runner.stub(Self.xcrun, ["simctl", "list", "devices", "--json"], output: ToolOutput(exitCode: 1, stdout: "", stderr: " CoreSimulatorService connection invalid\n"))
        runner.stub(Self.xcrun, ["simctl", "runtime", "list", "-j"], output: ToolOutput(exitCode: 0, stdout: "not json", stderr: ""))
        let context = InspectorContext(home: fixture.home, tools: runner, sizer: LogicalSizer(), now: Self.now)
        let items = try await inspector.discover(in: context)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        let devices = try #require(byID["xcode.error.devices"])
        #expect(devices.title == "Simulator devices couldn't be listed")
        #expect(devices.subtitle == "CoreSimulatorService connection invalid")
        #expect(devices.allocatedBytes == 0 && devices.paths.isEmpty)
        #expect(devices.risk == .rebuildable)
        #expect(devices.actionTitle == "Unavailable")
        #expect(!devices.isActionable)
        #expect(items.filter { $0.id.hasPrefix("xcode.error.") }.allSatisfy { !$0.isActionable })
        let runtimes = try #require(byID["xcode.error.runtimes"])
        #expect(runtimes.title == "Simulator runtimes couldn't be listed")
        #expect(byID["xcode.derived.MyApp-abcdefghijklmnopqrstuvwxyzab"] != nil)
        #expect(byID["xcode.unavailable-devices"] == nil)

        let plan = try await inspector.plan(for: items, in: context)
        #expect(plan.steps.count == 4)
        #expect(!plan.steps.contains { $0.title == "Unavailable" })
    }

    @Test func singleDeviceRuntimeSubtitleIsSingular() async throws {
        let (fixture, _, inspector) = try setup()
        let runner = Self.runner()
        let single = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-5":[{"udid":"A1A1A1A1-0000-4000-8000-00000000000A","isAvailable":true,"state":"Shutdown","name":"A"}]}}
        """
        runner.stub(Self.xcrun, ["simctl", "list", "devices", "--json"], output: ToolOutput(exitCode: 0, stdout: single, stderr: ""))
        runner.stub(Self.xcrun, ["simctl", "runtime", "list", "-j"], output: ToolOutput(exitCode: 0, stdout: Self.runtimesJSON, stderr: ""))
        let context = InspectorContext(home: fixture.home, tools: runner, sizer: LogicalSizer(), now: Self.now)
        let items = try await inspector.discover(in: context)
        #expect(items.first { $0.id == "xcode.runtime.5E3B6C1A-7D2F-4A8B-9C0D-1E2F3A4B5C6D" }?.subtitle == "In use by 1 device — they'll be deleted too")
    }

    @Test func missingCommandLineToolsSkipsXcrunAndKeepsFilesystemItems() async throws {
        let (fixture, _, inspector) = try setup()
        let failing = FakeToolRunner(tools: ["xcrun": Self.xcrun])
        failing.stub(Self.xcodeSelect, ["-p"], output: ToolOutput(exitCode: 2, stdout: "", stderr: "xcode-select: error: unable to get active developer directory"))
        // Unstubbed: `run` throws, which counts as not installed too.
        for runner in [failing, FakeToolRunner(tools: ["xcrun": Self.xcrun])] {
            let context = InspectorContext(home: fixture.home, tools: runner, sizer: LogicalSizer(), now: Self.now)
            let items = try await inspector.discover(in: context)
            #expect(!runner.invocations.contains { $0.0 == Self.xcrun })
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let info = try #require(byID["xcode.command-line-tools"])
            #expect(info.title == "Xcode command line tools not installed")
            #expect(!info.isActionable)
            #expect(info.paths.isEmpty && info.allocatedBytes == 0)
            #expect(byID["xcode.derived.MyApp-abcdefghijklmnopqrstuvwxyzab"] != nil)
            #expect(byID["xcode.archive.2026-01-01/MyApp.xcarchive"] != nil)
            #expect(!items.contains { $0.id.hasPrefix("xcode.error.") || $0.id.hasPrefix("xcode.runtime.") })
        }
    }

    @Test func installedCommandLineToolsAreCheckedBeforeXcrun() async throws {
        let (_, context, inspector) = try setup()
        let items = try await inspector.discover(in: context)
        #expect(items.first { $0.id == "xcode.command-line-tools" } == nil)
        let runner = try #require(context.tools as? FakeToolRunner)
        #expect(runner.invocations.first.map { [$0.0] + $0.1 } == [Self.xcodeSelect, "-p"])
    }
}
