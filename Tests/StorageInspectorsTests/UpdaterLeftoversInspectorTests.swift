import Foundation
import Testing
import StorageCore
import StorageInspectors
import StorageTestKit

@Suite struct UpdaterLeftoversInspectorTests {
    private func makeApp(_ fixture: FixtureHome, root: String, name: String, bundleID: String, displayName: String?) throws {
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
        if let displayName { plist["CFBundleDisplayName"] = displayName }
        let dir = fixture.home.appendingPathComponent("\(root)/\(name).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Info.plist"))
    }

    private func context(_ fixture: FixtureHome) -> InspectorContext {
        InspectorContext(home: fixture.home, tools: FakeToolRunner(), sizer: LogicalSizer())
    }

    @Test func shipItFolderResolvesAppNameAndRequiresQuit() async throws {
        let fixture = try FixtureHome()
        try makeApp(fixture, root: "Apps", name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", displayName: "Visual Studio Code")
        try fixture.file("Library/Caches/com.microsoft.VSCode.ShipIt/update.zip", bytes: 4096)
        let inspector = UpdaterLeftoversInspector(applicationsRoots: [fixture.home.path + "/Apps"])
        let ctx = context(fixture)

        let items = try await inspector.discover(in: ctx)
        #expect(items.count == 1)
        let item = try #require(items.first)
        let path = fixture.home.path + "/Library/Caches/com.microsoft.VSCode.ShipIt"
        #expect(item.id == "updaters.leftover.\(path)")
        #expect(item.title == "Visual Studio Code")
        #expect(item.risk == .cache)
        #expect(item.allocatedBytes == 4096)
        #expect(item.paths == [path])
        #expect(item.requirement == .mustBeQuit(bundleIDs: ["com.microsoft.VSCode"], processNames: []))
        #expect(item.whatYouLose == "Leftover auto-update download; the app re-downloads updates when needed")

        let plan = try await inspector.plan(for: items, in: ctx)
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].action == .delete(path: path, expectedFileID: nil))
        #expect(plan.steps[0].requirement == item.requirement)
    }

    @Test func updaterFolderFallsBackToFolderNameWithNoRequirement() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/@lineardesktop-updater/pending/x.dmg", bytes: 2048)
        try fixture.file("Library/Application Support/Caches/notion-updater/y.zip", bytes: 512)
        let inspector = UpdaterLeftoversInspector(applicationsRoots: [fixture.home.path + "/Apps", "~/Applications"])
        let ctx = context(fixture)

        let items = try await inspector.discover(in: ctx)
        let linear = try #require(items.first { $0.title == "@lineardesktop-updater" })
        #expect(linear.requirement == .none)
        #expect(linear.risk == .cache)
        #expect(linear.allocatedBytes == 2048)
        #expect(items.contains { $0.title == "notion-updater" && $0.allocatedBytes == 512 })

        let plan = try await inspector.plan(for: [linear], in: ctx)
        #expect(plan.steps.map(\.action) == [.delete(path: fixture.home.path + "/Library/Caches/@lineardesktop-updater", expectedFileID: nil)])
    }

    @Test func unresolvableShipItFolderUsesFolderNameAndNoRequirement() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt/a.zip", bytes: 100)
        let inspector = UpdaterLeftoversInspector(applicationsRoots: [fixture.home.path + "/Apps"])
        let items = try await inspector.discover(in: context(fixture))
        #expect(items.map(\.title) == ["com.todesktop.230313mzl4w4u92.ShipIt"])
        #expect(items.first?.requirement == AppStateRequirement.none)
    }

    @Test func noMatchesYieldsNoItems() async throws {
        let fixture = try FixtureHome()
        try fixture.dir("Library/Caches/com.other.thing")
        let items = try await UpdaterLeftoversInspector(applicationsRoots: []).discover(in: context(fixture))
        #expect(items.isEmpty)
    }
}
