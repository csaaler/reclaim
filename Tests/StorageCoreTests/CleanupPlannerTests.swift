import Foundation
import Synchronization
import Testing
import StorageCore
import StorageTestKit

/// Stands in for `ChromeInspector`: records what it was asked to plan and returns a fixed plan.
private final class StubInspector: Inspector {
    let id: String
    let displayName = "Stub"
    let bundleIDs: [String] = []
    let claimedPatterns: [String] = []
    private let result: @Sendable ([InspectorItem]) -> CleanupPlan
    private let calls = Mutex<[[InspectorItem]]>([])

    init(id: String, result: @escaping @Sendable ([InspectorItem]) -> CleanupPlan) {
        self.id = id
        self.result = result
    }

    var planCalls: [[InspectorItem]] { calls.withLock { $0 } }

    func discover(in context: InspectorContext) async throws -> [InspectorItem] { [] }

    func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        calls.withLock { $0.append(items) }
        return result(items)
    }
}

private func location(
    _ path: String,
    kind: LocationKind,
    cleanability: Cleanability = .cleanable,
    requirement: AppStateRequirement = .none,
    note: String? = nil
) -> AttributedLocation {
    AttributedLocation(path: path, allocatedBytes: 4096, lastModified: nil, kind: kind, note: note,
                       cleanability: cleanability, source: .locationRule, requirement: requirement)
}

private func item(
    _ id: String, inspectorID: String, paths: [String], risk: RiskLevel = .userData, isActionable: Bool = true
) -> InspectorItem {
    InspectorItem(id: id, inspectorID: inspectorID, title: id, whatYouLose: "everything", allocatedBytes: 10,
                  risk: risk, lastUsed: nil, paths: paths, requirement: .none, actionTitle: "Remove",
                  isActionable: isActionable)
}

@Suite struct CleanupPlannerTests {
    let fixture: FixtureHome
    let context: InspectorContext

    init() throws {
        fixture = try FixtureHome()
        context = InspectorContext(home: fixture.home, tools: FakeToolRunner(), sizer: LogicalSizer())
    }

    private func path(_ relative: String) -> String { fixture.home.appendingPathComponent(relative).path }

    @Test func greenLocationBecomesDeleteWithFileIDCapturedNow() async throws {
        try fixture.file("Library/Caches/com.example.app/blob.bin")
        let cache = path("Library/Caches/com.example.app")
        let requirement = AppStateRequirement.mustBeQuit(bundleIDs: ["com.example.app"], processNames: [])
        let plan = try await CleanupPlanner().plan(
            locations: [location(cache, kind: .cache, requirement: requirement, note: "A note")],
            items: [], inspectors: [], context: context)

        let step = try #require(plan.steps.first)
        #expect(plan.steps.count == 1)
        guard case .delete(let stepPath, let fileID) = step.action else {
            Issue.record("expected .delete, got \(step.action)")
            return
        }
        #expect(stepPath == cache)
        #expect(fileID != nil)
        #expect(fileID == FileID.of(path: cache))
        #expect(step.risk == .cache)
        #expect(step.requirement == requirement)
        #expect(step.estimatedBytes == 4096)
        #expect(step.sideEffectNote == "A note")
    }

    @Test func yellowLocationIsDeletedPermanently() async throws {
        try fixture.file("Library/Caches/com.example.big/blob.bin")
        let plan = try await CleanupPlanner().plan(
            locations: [location(path("Library/Caches/com.example.big"), kind: .rebuildable)],
            items: [], inspectors: [], context: context)
        guard case .delete = try #require(plan.steps.first).action else {
            Issue.record("expected .delete")
            return
        }
    }

    @Test func redLocationBecomesTrashWithFileID() async throws {
        try fixture.file("Downloads/movie.mov")
        let file = path("Downloads/movie.mov")
        let plan = try await CleanupPlanner().plan(
            locations: [location(file, kind: .userData)], items: [], inspectors: [], context: context)

        let step = try #require(plan.steps.first)
        guard case .trash(let stepPath, let fileID) = step.action else {
            Issue.record("expected .trash, got \(step.action)")
            return
        }
        #expect(stepPath == file)
        #expect(fileID == FileID.of(path: file))
        #expect(step.risk == .userData)
    }

    @Test func missingLocationGetsNoStep() async throws {
        // Without an identity to check, something created at the path later could be deleted.
        let plan = try await CleanupPlanner().plan(
            locations: [location(path("Library/Caches/gone"), kind: .cache)], items: [], inspectors: [], context: context)
        #expect(plan.steps.isEmpty)
    }

    @Test func nonCleanableLocationsNeverBecomeSteps() async throws {
        try fixture.file("Library/Caches/com.apple.thing/a")
        try fixture.file("Library/Keychains/k")
        try fixture.file("Library/Developer/Xcode/x")
        try fixture.file("Library/Caches/ok/a")
        let plan = try await CleanupPlanner().plan(
            locations: [
                location(path("Library/Caches/com.apple.thing"), kind: .cache, cleanability: .viewOnly(reason: "Apple system cache")),
                location(path("Library/Keychains"), kind: .userData, cleanability: .protected),
                location(path("Library/Developer/Xcode"), kind: .rebuildable, cleanability: .claimed(inspectorID: "xcode")),
                location(path("Library/Caches/ok"), kind: .cache),
            ],
            items: [], inspectors: [], context: context)

        #expect(plan.steps.count == 1)
        guard case .delete(let stepPath, _) = try #require(plan.steps.first).action else {
            Issue.record("expected .delete")
            return
        }
        #expect(stepPath == path("Library/Caches/ok"))
    }

    @Test func duplicateLocationsArePlannedOnce() async throws {
        try fixture.file("Library/Caches/dup/a")
        let dup = location(path("Library/Caches/dup"), kind: .cache)
        let plan = try await CleanupPlanner().plan(locations: [dup, dup], items: [], inspectors: [], context: context)
        #expect(plan.steps.count == 1)
    }

    @Test func chromeItemIsDelegatedToItsInspector() async throws {
        try fixture.file("Library/Application Support/Google/Chrome/Profile 11/Preferences")
        let profile = path("Library/Application Support/Google/Chrome/Profile 11")
        let trashProfile = CleanupStep(title: "Move profile to Trash", risk: .userData, estimatedBytes: 10, requirement: .none,
                                       action: .trash(path: profile, expectedFileID: nil))
        let known = CleanupPlan(steps: [
            trashProfile,
            CleanupStep(title: "Remove from list", risk: .userData, estimatedBytes: 0, requirement: .none,
                        action: .removeJSONKeys(path: profile + "/../Local State", edits: [.removeKey(["profile"])]),
                        dependsOn: trashProfile.id),
        ])
        let chrome = StubInspector(id: "chrome") { _ in known }
        let other = StubInspector(id: "docker") { _ in CleanupPlan(steps: []) }
        let profileItem = item("chrome.profile.Profile 11", inspectorID: "chrome", paths: [profile])

        let plan = try await CleanupPlanner().plan(
            locations: [], items: [profileItem], inspectors: [other, chrome], context: context)

        #expect(chrome.planCalls == [[profileItem]])
        #expect(other.planCalls.isEmpty)
        #expect(plan.steps.map(\.id) == known.steps.map(\.id))
        #expect(plan.steps.map(\.title) == known.steps.map(\.title))
        #expect(plan.steps.map(\.dependsOn) == [nil, trashProfile.id])
    }

    @Test func itemsAreGroupedByInspector() async throws {
        let a1 = item("a.1", inspectorID: "a", paths: [path("x/1")])
        let b1 = item("b.1", inspectorID: "b", paths: [path("x/2")])
        let a2 = item("a.2", inspectorID: "a", paths: [path("x/3")])
        let a = StubInspector(id: "a") { _ in CleanupPlan(steps: []) }
        let b = StubInspector(id: "b") { _ in CleanupPlan(steps: []) }

        _ = try await CleanupPlanner().plan(locations: [], items: [a1, b1, a2], inspectors: [a, b], context: context)

        #expect(a.planCalls == [[a1, a2]])
        #expect(b.planCalls == [[b1]])
    }

    @Test func nonActionableItemsNeverReachAnInspector() async throws {
        let chrome = StubInspector(id: "chrome") { items in
            CleanupPlan(steps: items.map {
                CleanupStep(title: $0.id, risk: .cache, estimatedBytes: 0, requirement: .none,
                            action: .delete(path: $0.paths.first ?? "/", expectedFileID: nil))
            })
        }
        // Has a path, so only the flag keeps it out.
        let informational = item("chrome.profile.Default", inspectorID: "chrome", paths: [path("Default")],
                                 isActionable: false)
        let real = item("chrome.cache", inspectorID: "chrome", paths: [path("cache")], risk: .cache)

        let onlyInfo = try await CleanupPlanner().plan(
            locations: [], items: [informational], inspectors: [chrome], context: context)
        #expect(onlyInfo.steps.isEmpty)
        #expect(chrome.planCalls.isEmpty)

        _ = try await CleanupPlanner().plan(
            locations: [], items: [informational, real], inspectors: [chrome], context: context)
        #expect(chrome.planCalls == [[real]])
    }

    @Test func toolItemWithEmptyPathsIsPlanned() async throws {
        let prune = item("docker.volumes", inspectorID: "docker", paths: [], risk: .userData)
        let docker = StubInspector(id: "docker") { _ in
            CleanupPlan(steps: [CleanupStep(title: "Prune volumes", risk: .userData, estimatedBytes: 10, requirement: .none,
                                            action: .runTool(executable: "/usr/local/bin/docker", arguments: ["volume", "prune", "-f"]))])
        }
        let result = try await CleanupPlanner().planReporting(
            locations: [], items: [prune], inspectors: [docker], context: context)
        #expect(docker.planCalls == [[prune]])
        #expect(result.plan.steps.map(\.title) == ["Prune volumes"])
        #expect(result.nothingToDo.isEmpty)
    }

    @Test func itemTheInspectorDoesNotPlanIsReported() async throws {
        let adminOnly = item("xcode.system-cache", inspectorID: "xcode", paths: [path("x")], risk: .cache)
        let xcode = StubInspector(id: "xcode") { _ in CleanupPlan(steps: []) }
        let result = try await CleanupPlanner().planReporting(
            locations: [], items: [adminOnly], inspectors: [xcode], context: context)
        #expect(result.plan.steps.isEmpty)
        #expect(result.nothingToDo == ["Nothing to do for xcode.system-cache."])
    }

    @Test func missingLocationIsReported() async throws {
        let result = try await CleanupPlanner().planReporting(
            locations: [location(path("Library/Caches/gone"), kind: .cache)], items: [], inspectors: [], context: context)
        #expect(result.plan.steps.isEmpty)
        #expect(result.nothingToDo == ["Nothing to do for ~/Library/Caches/gone: it no longer exists."])
    }

    @Test func itemWithoutItsInspectorThrows() async throws {
        let orphan = item("ghost.1", inspectorID: "ghost", paths: [path("x")])
        await #expect(throws: CleanupPlanner.Failure.inspectorMissing("ghost")) {
            _ = try await CleanupPlanner().plan(locations: [], items: [orphan], inspectors: [], context: context)
        }
    }

    @Test func inspectorStepsWithoutIdentityGetOneCapturedNow() async throws {
        try fixture.file("Library/Caches/Google/Chrome/Default/Cache/a")
        let cache = path("Library/Caches/Google/Chrome/Default/Cache")
        let existing = FileID(device: 1, inode: 2)
        let dependency = UUID()
        let steps = [
            CleanupStep(title: "nil id", risk: .cache, estimatedBytes: 1, requirement: .none,
                        action: .delete(path: cache, expectedFileID: nil), dependsOn: dependency),
            CleanupStep(title: "kept id", risk: .cache, estimatedBytes: 1, requirement: .none,
                        action: .delete(path: cache, expectedFileID: existing)),
            CleanupStep(title: "missing", risk: .userData, estimatedBytes: 1, requirement: .none,
                        action: .trash(path: path("nope"), expectedFileID: nil)),
            CleanupStep(title: "tool", risk: .userData, estimatedBytes: 1, requirement: .none,
                        action: .runTool(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "UDID"])),
        ]
        let chrome = StubInspector(id: "chrome") { _ in CleanupPlan(steps: steps) }
        let result = try await CleanupPlanner().planReporting(
            locations: [], items: [item("chrome.cache", inspectorID: "chrome", paths: [cache])],
            inspectors: [chrome], context: context)
        let plan = result.plan

        // A path that no longer exists has no identity to check, so its step is dropped and reported.
        #expect(plan.steps.map(\.id) == [steps[0].id, steps[1].id, steps[3].id])
        #expect(plan.steps[0].action == .delete(path: cache, expectedFileID: FileID.of(path: cache)))
        #expect(plan.steps[1].action == .delete(path: cache, expectedFileID: existing))
        #expect(plan.steps[2].action == steps[3].action)
        #expect(result.nothingToDo == ["~/nope no longer exists."])
        #expect(plan.steps[0].title == "nil id")
        #expect(plan.steps[0].dependsOn == dependency)
        #expect(plan.steps[0].isIrreversible)
    }

    @Test func capturingIdentityKeepsEveryOtherField() async throws {
        try fixture.file("Library/Application Support/Demo/Profile/a")
        let profile = path("Library/Application Support/Demo/Profile")
        let step = CleanupStep(
            title: "Remove profile", risk: .userData, estimatedBytes: 7, requirement: .mustBeQuit(bundleIDs: ["com.example.Demo"], processNames: []),
            action: .trash(path: profile, expectedFileID: nil), sideEffectNote: "Signs you out",
            dependsOn: UUID(), acknowledgement: "Bookmarks in this profile are lost")
        let stub = StubInspector(id: "chrome") { _ in CleanupPlan(steps: [step]) }
        let plan = try await CleanupPlanner().plan(
            locations: [], items: [item("chrome.profile", inspectorID: "chrome", paths: [profile])],
            inspectors: [stub], context: context)

        let captured = try #require(plan.steps.first)
        #expect(captured.action == .trash(path: profile, expectedFileID: FileID.of(path: profile)))
        #expect(captured.id == step.id)
        #expect(captured.title == step.title)
        #expect(captured.risk == step.risk)
        #expect(captured.estimatedBytes == step.estimatedBytes)
        #expect(captured.requirement == step.requirement)
        #expect(captured.sideEffectNote == step.sideEffectNote)
        #expect(captured.dependsOn == step.dependsOn)
        #expect(captured.acknowledgement == step.acknowledgement)
    }

    @Test func locationsComeBeforeInspectorSteps() async throws {
        try fixture.file("Library/Caches/first/a")
        let chrome = StubInspector(id: "chrome") { _ in
            CleanupPlan(steps: [CleanupStep(title: "tool", risk: .rebuildable, estimatedBytes: 1, requirement: .none,
                                            action: .runTool(executable: "/bin/true", arguments: []))])
        }
        let plan = try await CleanupPlanner().plan(
            locations: [location(path("Library/Caches/first"), kind: .cache)],
            items: [item("chrome.x", inspectorID: "chrome", paths: [path("x")])],
            inspectors: [chrome], context: context)
        #expect(plan.steps.map(\.title).last == "tool")
        #expect(plan.steps.count == 2)
    }

    @Test func displayPathIsHomeRelative() {
        let home = URL(fileURLWithPath: "/Users/sample")
        #expect(CleanupPlanner.displayPath("/Users/sample", home: home) == "~")
        #expect(CleanupPlanner.displayPath("/Users/sample/Library/Caches", home: home) == "~/Library/Caches")
        #expect(CleanupPlanner.displayPath("/Users/sampleother/x", home: home) == "/Users/sampleother/x")
        #expect(CleanupPlanner.displayPath("/Library/Caches", home: home) == "/Library/Caches")
    }
}
