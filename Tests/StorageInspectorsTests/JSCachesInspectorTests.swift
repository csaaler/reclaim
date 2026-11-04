import Foundation
import Testing
import StorageCore
import StorageInspectors
import StorageTestKit

@Suite struct JSCachesInspectorTests {
    static let allTools = [
        "npm": "/opt/node/bin/npm",
        "pnpm": "/opt/pnpm/pnpm",
        "brew": "/opt/homebrew/bin/brew",
        "yarn": "/opt/yarn/yarn",
        "bun": "/opt/bun/bun",
    ]

    func makeFixture(alias: String? = "v20.10.0") throws -> FixtureHome {
        let f = try FixtureHome()
        try f.file(".npm/_cacache/a", bytes: 100)
        try f.file("Library/pnpm/store/v10/files/a", bytes: 200)
        try f.file("Library/Caches/Homebrew/a", bytes: 300)
        try f.file("Library/Caches/Yarn/a", bytes: 400)
        try f.file(".bun/install/cache/a", bytes: 500)
        try f.file(".nvm/versions/node/v20.10.0/bin/node", bytes: 600)
        try f.file(".nvm/versions/node/v18.20.8/bin/node", bytes: 700)
        if let alias {
            try f.file(".nvm/alias/default", bytes: 0)
            try alias.write(toFile: f.home.path + "/.nvm/alias/default", atomically: true, encoding: .utf8)
        }
        return f
    }

    func context(_ f: FixtureHome, tools: [String: String] = allTools) -> InspectorContext {
        InspectorContext(home: f.home, tools: FakeToolRunner(tools: tools), sizer: LogicalSizer())
    }

    @Test func itemsAndExactPlan() async throws {
        let f = try makeFixture()
        let ctx = context(f)
        let inspector = JSCachesInspector()
        let items = try await inspector.discover(in: ctx)
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        #expect(items.count == 6)
        #expect(byID["js-caches.npm.cache"]?.title == "npm cache")
        #expect(byID["js-caches.npm.cache"]?.risk == .rebuildable)
        #expect(byID["js-caches.npm.cache"]?.allocatedBytes == 100)
        #expect(byID["js-caches.pnpm.store"]?.risk == .rebuildable)
        #expect(byID["js-caches.pnpm.store"]?.allocatedBytes == 200)
        #expect(byID["js-caches.pnpm.store"]?.subtitle == "Removes only packages no project references")
        #expect(byID["js-caches.homebrew.cache"]?.risk == .cache)
        #expect(byID["js-caches.homebrew.cache"]?.allocatedBytes == 300)
        #expect(byID["js-caches.yarn.cache"]?.allocatedBytes == 400)
        #expect(byID["js-caches.bun.cache"]?.risk == .cache)
        #expect(byID["js-caches.bun.cache"]?.allocatedBytes == 500)
        let nvm = byID["js-caches.nvm.v18.20.8"]
        #expect(nvm?.risk == .rebuildable)
        #expect(nvm?.allocatedBytes == 700)
        #expect(nvm?.subtitle == "Global packages installed in this version will be removed")
        #expect(items.allSatisfy { $0.lastUsed == nil && $0.requirement == .none })

        let plan = try await inspector.plan(for: items, in: ctx)
        let actions = Set(plan.steps.map(\.action))
        #expect(plan.steps.count == 6)
        #expect(actions == [
            .runTool(executable: "/opt/node/bin/npm", arguments: ["cache", "clean", "--force"]),
            .runTool(executable: "/opt/pnpm/pnpm", arguments: ["store", "prune"]),
            .runTool(executable: "/opt/homebrew/bin/brew", arguments: ["cleanup", "--prune=all", "-s"]),
            .runTool(executable: "/opt/yarn/yarn", arguments: ["cache", "clean"]),
            .runTool(executable: "/opt/bun/bun", arguments: ["pm", "cache", "rm"]),
            .delete(path: f.home.path + "/.nvm/versions/node/v18.20.8", expectedFileID: nil),
        ])
    }

    @Test func defaultNvmVersionIsExcluded() async throws {
        let f = try makeFixture()
        let items = try await JSCachesInspector().discover(in: context(f))
        #expect(!items.contains { $0.id == "js-caches.nvm.v20.10.0" })
        #expect(items.contains { $0.id == "js-caches.nvm.v18.20.8" })
    }

    @Test func ltsAliasResolvesThroughAliasChain() async throws {
        let f = try makeFixture(alias: "lts/*")
        try f.dir(".nvm/alias/lts")
        try "lts/hydrogen".write(toFile: f.home.path + "/.nvm/alias/lts/*", atomically: true, encoding: .utf8)
        try "v18.20.8".write(toFile: f.home.path + "/.nvm/alias/lts/hydrogen", atomically: true, encoding: .utf8)
        let items = try await JSCachesInspector().discover(in: context(f))
        #expect(!items.contains { $0.id == "js-caches.nvm.v18.20.8" })
        #expect(items.contains { $0.id == "js-caches.nvm.v20.10.0" })
    }

    @Test func ltsAliasWithoutChainPicksNewestDir() async throws {
        let f = try makeFixture(alias: "lts/*")
        let items = try await JSCachesInspector().discover(in: context(f))
        #expect(!items.contains { $0.id == "js-caches.nvm.v20.10.0" })
        #expect(items.contains { $0.id == "js-caches.nvm.v18.20.8" })
    }

    @Test func unresolvableDefaultExcludesNoneAndWarns() async throws {
        let f = try makeFixture(alias: "nonsense-alias")
        let items = try await JSCachesInspector().discover(in: context(f))
        let nvm = items.filter { $0.id.hasPrefix("js-caches.nvm.") }
        #expect(nvm.count == 2)
        #expect(nvm.allSatisfy { $0.subtitle == "Check this isn't your default" })
    }

    @Test func missingPnpmShowsItemButPlanIsEmpty() async throws {
        let f = try FixtureHome()
        try f.file("Library/pnpm/store/v10/files/a", bytes: 200)
        let ctx = context(f, tools: [:])
        let inspector = JSCachesInspector()
        let items = try await inspector.discover(in: ctx)
        #expect(items.count == 1)
        #expect(items[0].subtitle == "pnpm not found")
        #expect(!items[0].isActionable)
        #expect(items[0].allocatedBytes == 200)
        let plan = try await inspector.plan(for: items, in: ctx)
        #expect(plan.steps.isEmpty)
    }

    @Test func absentPathsProduceNoItems() async throws {
        let f = try FixtureHome()
        let items = try await JSCachesInspector().discover(in: context(f))
        #expect(items.isEmpty)
    }
}
