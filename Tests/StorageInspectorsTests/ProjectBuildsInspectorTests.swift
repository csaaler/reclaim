import Testing
import Foundation
import StorageCore
import StorageTestKit
@testable import StorageInspectors

@Suite struct ProjectBuildsInspectorTests {
    private func context(_ fixture: FixtureHome) -> InspectorContext {
        InspectorContext(home: fixture.home, tools: FakeToolRunner(), sizer: LogicalSizer())
    }

    @Test func nodeModulesWithPackageJSONIsFound() async throws {
        let fixture = try FixtureHome()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.file("git/a/package.json", bytes: 10, modified: old)
        try fixture.file("git/a/README.md", bytes: 10, modified: newer)
        try fixture.file("git/a/node_modules/x/index.js", bytes: 500)
        try fixture.file("git/a/dist/out.js", bytes: 100)
        try fixture.file("git/a/node_modules/x/node_modules/y/index.js", bytes: 50)
        let inspector = ProjectBuildsInspector(codeRoots: ["~/git"])
        let ctx = context(fixture)

        let items = try await inspector.discover(in: ctx)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.id == "project-builds.project.\(fixture.home.path)/git/a")
        #expect(item.title == "a")
        #expect(item.subtitle == "dist, node_modules")
        #expect(item.risk == .rebuildable)
        #expect(item.allocatedBytes == 650)
        #expect(item.requirement == .none)
        #expect(item.lastUsed == newer)
        #expect(item.paths == ["\(fixture.home.path)/git/a/dist", "\(fixture.home.path)/git/a/node_modules"])

        let plan = try await inspector.plan(for: items, in: ctx)
        #expect(plan.steps.map(\.action) == [
            .trash(path: "\(fixture.home.path)/git/a/dist", expectedFileID: nil),
            .delete(path: "\(fixture.home.path)/git/a/node_modules", expectedFileID: nil),
        ])
        #expect(plan.steps.allSatisfy { $0.risk == .rebuildable && $0.requirement == .none })
        #expect(plan.steps.map(\.sideEffectNote) == [
            ProjectBuildsInspector.trashedNote, "Run your package manager's install/build to restore",
        ])
        #expect(plan.steps.map(\.estimatedBytes) == [100, 550])
    }

    @Test func buildAndDistGoToTheTrash() async throws {
        let fixture = try FixtureHome()
        try fixture.file("git/web/package.json", bytes: 1)
        try fixture.file("git/web/build/index.html", bytes: 100)
        try fixture.file("git/web/dist/app.js", bytes: 100)
        try fixture.file("git/app/build.gradle", bytes: 1)
        try fixture.file("git/app/build/classes/A.class", bytes: 100)
        let inspector = ProjectBuildsInspector(codeRoots: ["~/git"])
        let ctx = context(fixture)
        let plan = try await inspector.plan(for: try await inspector.discover(in: ctx), in: ctx)
        let h = fixture.home.path
        #expect(Set(plan.steps.map(\.action)) == [
            .trash(path: "\(h)/git/web/build", expectedFileID: nil),
            .trash(path: "\(h)/git/web/dist", expectedFileID: nil),
            .trash(path: "\(h)/git/app/build", expectedFileID: nil),
        ])
        #expect(plan.steps.allSatisfy { $0.risk == .rebuildable && !$0.isIrreversible })
        #expect(plan.steps.allSatisfy { $0.sideEffectNote == ProjectBuildsInspector.trashedNote })
        #expect(ProjectBuildsInspector.trashedNote.contains("Trash"))
    }

    @Test func buildWithoutMarkerIsIgnored() async throws {
        let fixture = try FixtureHome()
        try fixture.file("git/b/build/out.o", bytes: 100)
        try fixture.file("git/b/target/out", bytes: 100)
        let inspector = ProjectBuildsInspector(codeRoots: ["~/git"])
        #expect(try await inspector.discover(in: context(fixture)).isEmpty)
        #expect(await inspector.claimedPaths(in: context(fixture)).isEmpty)
    }

    @Test func gitIsSkipped() async throws {
        let fixture = try FixtureHome()
        try fixture.file("git/c/.git/modules/m/package.json", bytes: 1)
        try fixture.file("git/c/.git/modules/m/node_modules/z", bytes: 100)
        let inspector = ProjectBuildsInspector(codeRoots: ["~/git"])
        #expect(try await inspector.discover(in: context(fixture)).isEmpty)
    }

    @Test func customRootAndOtherMarkers() async throws {
        let fixture = try FixtureHome()
        try fixture.file("work/rs/Cargo.toml", bytes: 1)
        try fixture.file("work/rs/target/debug/bin", bytes: 300)
        try fixture.file("work/swift/Package.swift", bytes: 1)
        try fixture.file("work/swift/.build/x", bytes: 200)
        try fixture.file("work/py/requirements.txt", bytes: 1)
        try fixture.file("work/py/.venv/lib", bytes: 100)
        try fixture.file("git/ignored/package.json", bytes: 1)
        try fixture.file("git/ignored/node_modules/z", bytes: 999)
        let inspector = ProjectBuildsInspector(codeRoots: ["~/work"])
        let ctx = context(fixture)
        let items = try await inspector.discover(in: ctx)
        #expect(items.map(\.title) == ["rs", "swift", "py"])
        let claimed = await inspector.claimedPaths(in: ctx)
        #expect(Set(claimed) == Set(items.flatMap(\.paths)))
        #expect(claimed.count == 3)
    }

    @Test func depthLimitIsSix() async throws {
        let fixture = try FixtureHome()
        try fixture.file("r/1/2/3/4/5/package.json", bytes: 1)
        try fixture.file("r/1/2/3/4/5/node_modules/z", bytes: 10)
        try fixture.file("r/1/2/3/4/5/6/7/package.json", bytes: 1)
        try fixture.file("r/1/2/3/4/5/6/7/node_modules/z", bytes: 10)
        let inspector = ProjectBuildsInspector(codeRoots: ["~/r"])
        let items = try await inspector.discover(in: context(fixture))
        #expect(items.map(\.title) == ["5"])
    }
}
