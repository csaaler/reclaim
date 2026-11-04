import Foundation
import StorageCore
import StorageTestKit
import Testing
@testable import StorageInspectors

@Suite struct JetBrainsInspectorTests {
    private func writeApp(_ fixture: FixtureHome, _ path: String, bundleID: String, version: String, name: String, dataDirectoryName: String?) throws {
        try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent("\(path)/Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundleName": name,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: fixture.home.appendingPathComponent("\(path)/Contents/Info.plist"))
        if let dataDirectoryName {
            try fixture.json("\(path)/Contents/Resources/product-info.json", ["name": name, "dataDirectoryName": dataDirectoryName])
        }
    }

    private func makeContext(_ fixture: FixtureHome) -> InspectorContext {
        InspectorContext(home: fixture.home, tools: FakeToolRunner(), sizer: LogicalSizer())
    }

    private func inspector(_ fixture: FixtureHome) -> JetBrainsInspector {
        JetBrainsInspector(applicationRoots: [
            fixture.home.appendingPathComponent("Applications").path,
            "~/UserApps",
        ])
    }

    @Test func cachesForAllVersionsAndSettingsOnlyForUninstalled() async throws {
        let fixture = try FixtureHome()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try writeApp(fixture, "Applications/WebStorm.app", bundleID: "com.jetbrains.WebStorm", version: "2025.2", name: "WebStorm", dataDirectoryName: "WebStorm2025.2")
        try fixture.file("Library/Caches/JetBrains/WebStorm2025.2/index.bin", bytes: 1000)
        try fixture.file("Library/Logs/JetBrains/WebStorm2025.2/idea.log", bytes: 200)
        try fixture.file("Library/Caches/JetBrains/WebStorm2024.1/index.bin", bytes: 500, modified: old)
        try fixture.file("Library/Application Support/JetBrains/WebStorm2025.2/options/a.xml", bytes: 30)
        try fixture.file("Library/Application Support/JetBrains/WebStorm2024.1/options/a.xml", bytes: 40, modified: old)
        // Not version-named: must be ignored.
        try fixture.file("Library/Caches/JetBrains/Daemon/x", bytes: 5)
        try fixture.file("Library/Application Support/JetBrains/consentOptions/x", bytes: 5)

        let context = makeContext(fixture)
        let subject = inspector(fixture)
        let items = try await subject.discover(in: context)
        let home = fixture.home.path

        #expect(items.map(\.id).sorted() == [
            "jetbrains.cache.WebStorm2024.1",
            "jetbrains.cache.WebStorm2025.2",
            "jetbrains.settings.WebStorm2024.1",
        ])
        let current = try #require(items.first { $0.id == "jetbrains.cache.WebStorm2025.2" })
        #expect(current.title == "WebStorm 2025.2 caches")
        #expect(current.risk == .cache)
        #expect(current.allocatedBytes == 1200)
        #expect(current.requirement == .mustBeQuit(bundleIDs: ["com.jetbrains.WebStorm"], processNames: []))
        #expect(current.paths == ["\(home)/Library/Caches/JetBrains/WebStorm2025.2", "\(home)/Library/Logs/JetBrains/WebStorm2025.2"])

        let oldCache = try #require(items.first { $0.id == "jetbrains.cache.WebStorm2024.1" })
        #expect(oldCache.risk == .cache)
        #expect(oldCache.allocatedBytes == 500)
        #expect(oldCache.requirement == .none)
        #expect(oldCache.lastUsed != nil)

        let settings = try #require(items.first { $0.id == "jetbrains.settings.WebStorm2024.1" })
        #expect(settings.risk == .userData)
        #expect(settings.subtitle == "IDE version not installed")
        #expect(settings.allocatedBytes == 40)
        #expect(settings.paths == ["\(home)/Library/Application Support/JetBrains/WebStorm2024.1"])

        let plan = try await subject.plan(for: items.filter { $0.id != "jetbrains.cache.WebStorm2024.1" }, in: context)
        let actions = plan.steps.map(\.action)
        #expect(actions.contains(.delete(path: "\(home)/Library/Caches/JetBrains/WebStorm2025.2", expectedFileID: nil)))
        #expect(actions.contains(.delete(path: "\(home)/Library/Logs/JetBrains/WebStorm2025.2", expectedFileID: nil)))
        #expect(actions.contains(.trash(path: "\(home)/Library/Application Support/JetBrains/WebStorm2024.1", expectedFileID: nil)))
        #expect(plan.steps.count == 3)
        #expect(plan.steps.first { if case .trash = $0.action { true } else { false } }?.risk == .userData)
    }

    @Test func derivesDataDirectoryWhenProductInfoMissingAndScansUserApplications() async throws {
        let fixture = try FixtureHome()
        try writeApp(fixture, "UserApps/Toolbox/GoLand.app", bundleID: "com.jetbrains.goland", version: "2025.1.3", name: "GoLand", dataDirectoryName: nil)
        try writeApp(fixture, "UserApps/Other.app", bundleID: "com.example.Other", version: "2024.1", name: "Other", dataDirectoryName: nil)
        try fixture.file("Library/Caches/JetBrains/GoLand2025.1/c", bytes: 10)
        try fixture.file("Library/Application Support/JetBrains/GoLand2025.1/s", bytes: 10)

        let items = try await inspector(fixture).discover(in: makeContext(fixture))
        #expect(items.map(\.id) == ["jetbrains.cache.GoLand2025.1"])
        #expect(items[0].requirement == .mustBeQuit(bundleIDs: ["com.jetbrains.goland"], processNames: []))
    }

    @Test func noJetBrainsDataYieldsNoItems() async throws {
        let fixture = try FixtureHome()
        let items = try await inspector(fixture).discover(in: makeContext(fixture))
        #expect(items.isEmpty)
    }
}
