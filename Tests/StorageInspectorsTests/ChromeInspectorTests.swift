import Foundation
import Synchronization
import Testing
import StorageCore
import StorageInspectors
import StorageTestKit

@Suite struct ChromeInspectorTests {
    static let support = "Library/Application Support/Google/Chrome"
    static let caches = "Library/Caches/Google/Chrome"
    static let quit = AppStateRequirement.mustBeQuit(bundleIDs: ["com.google.Chrome"], processNames: ["Google Chrome"])
    static let profile11Edits: [JSONEdit] = [
        .removeKey(["profile", "info_cache", "Profile 11"]),
        .removeArrayValue(keyPath: ["profile", "profiles_order"], value: "Profile 11"),
        .removeArrayValue(keyPath: ["profile", "last_active_profiles"], value: "Profile 11"),
    ]

    func context(_ fixture: FixtureHome) -> InspectorContext {
        InspectorContext(home: fixture.home, tools: FakeToolRunner(), sizer: LogicalSizer())
    }

    func makeFixture() throws -> FixtureHome {
        let fixture = try FixtureHome()
        let s = Self.support
        try fixture.file("\(s)/Default/History", bytes: 100)
        try fixture.file("\(s)/Profile 2/History", bytes: 200)
        try fixture.file("\(s)/Profile 11/History", bytes: 300)
        try fixture.file("\(s)/Profile 11/Bookmarks", bytes: 50)
        try fixture.file("\(s)/OptGuideOnDeviceModel/weights.bin", bytes: 4000)
        try fixture.file("\(Self.caches)/Profile 11/Cache_Data/f", bytes: 70)
        try fixture.file("\(s)/Profile 11/Code Cache/js/f", bytes: 10)
        try fixture.file("\(s)/Profile 11/GPUCache/f", bytes: 20)
        try fixture.file("\(s)/Profile 11/Service Worker/CacheStorage/f", bytes: 30)
        try fixture.json("\(s)/Local State", [
            "profile": [
                "info_cache": [
                    "Default": ["name": "Person 1", "user_name": "a@example.test", "gaia_name": "Alice", "active_time": 1_700_000_300.0],
                    "Profile 2": ["name": "Work", "user_name": "b@example.test", "gaia_name": "Bob", "active_time": 1_700_000_200.0],
                    "Profile 11": ["name": "Side", "user_name": "c@example.test", "gaia_name": "Cy", "active_time": 1_700_000_100.0],
                ],
                "profiles_order": ["Default", "Profile 2", "Profile 11"],
                "last_active_profiles": ["Default", "Profile 11"],
                "last_used": "Default",
            ],
        ])
        return fixture
    }

    @Test func discoversProfilesCachesAndModel() async throws {
        let fixture = try makeFixture()
        let items = try await ChromeInspector().discover(in: context(fixture))
        let home = fixture.home.path
        let profiles = items.filter { $0.id.hasPrefix("chrome.profile.") }
        #expect(profiles.map(\.id) == ["chrome.profile.Default", "chrome.profile.Profile 2", "chrome.profile.Profile 11"])
        let p11 = try #require(profiles.last)
        #expect(p11.title == "Side")
        #expect(p11.subtitle == "c@example.test")
        #expect(p11.risk == .userData)
        #expect(p11.actionTitle == "Remove profile")
        #expect(p11.isActionable)
        #expect(p11.requirement == Self.quit)
        #expect(p11.allocatedBytes == 10 + 20 + 30 + 300 + 50)
        #expect(p11.lastUsed == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(p11.whatYouLose == "Bookmarks, history, saved passwords, cookies and extensions of this profile (synced data stays in your Google account)")
        #expect(p11.paths == ["\(home)/\(Self.support)/Profile 11"])

        let active = try #require(profiles.first)
        #expect(active.subtitle == "Currently active profile — switch away in Chrome first")
        #expect(profiles[1].subtitle == "b@example.test")

        let cache = try #require(items.first { $0.id == "chrome.cache.Profile 11" })
        #expect(cache.risk == .cache)
        #expect(cache.allocatedBytes == 70 + 10 + 20 + 30)
        #expect(items.filter { $0.id.hasPrefix("chrome.cache.") }.count == 1)

        let model = try #require(items.first { $0.id == "chrome.model" })
        #expect(model.risk == .cache)
        #expect(model.allocatedBytes == 4000)
        #expect(model.whatYouLose.contains("Chrome may download it again"))
    }

    @Test func profilePlanIsTrashThenJSONEdit() async throws {
        let fixture = try makeFixture()
        let ctx = context(fixture)
        let inspector = ChromeInspector()
        let items = try await inspector.discover(in: ctx)
        let item = try #require(items.first { $0.id == "chrome.profile.Profile 11" })
        let plan = try await inspector.plan(for: [item], in: ctx)
        let root = "\(fixture.home.path)/\(Self.support)"
        #expect(plan.steps.map(\.action) == [
            .trash(path: "\(root)/Profile 11", expectedFileID: nil),
            .removeJSONKeys(path: "\(root)/Local State", edits: Self.profile11Edits),
        ])
        #expect(plan.steps.allSatisfy { $0.requirement == Self.quit })
        #expect(plan.steps.allSatisfy { $0.risk == .userData })
        // The list edit runs only if the profile really went to the Trash.
        #expect(plan.steps[0].dependsOn == nil)
        #expect(plan.steps[1].dependsOn == plan.steps[0].id)
        // The review asks to confirm the list edit with its own wording, not the profile's.
        #expect(plan.steps[0].acknowledgement == nil)
        #expect(plan.steps[1].acknowledgement == "Chrome's profile list will be edited (a backup goes to the Trash)")
    }

    @Test func activeProfileIsNeverPlanned() async throws {
        let fixture = try makeFixture()
        let ctx = context(fixture)
        let inspector = ChromeInspector()
        let items = try await inspector.discover(in: ctx)
        let active = try #require(items.first { $0.id == "chrome.profile.Default" })
        let plan = try await inspector.plan(for: [active], in: ctx)
        #expect(plan.steps.isEmpty)
    }

    @Test func cacheAndModelPlansDeleteExistingPaths() async throws {
        let fixture = try makeFixture()
        let ctx = context(fixture)
        let inspector = ChromeInspector()
        let items = try await inspector.discover(in: ctx)
        let cache = try #require(items.first { $0.id == "chrome.cache.Profile 11" })
        let model = try #require(items.first { $0.id == "chrome.model" })
        let plan = try await inspector.plan(for: [cache, model], in: ctx)
        let home = fixture.home.path
        let s = "\(home)/\(Self.support)"
        #expect(plan.steps.map(\.action) == [
            .delete(path: "\(home)/\(Self.caches)/Profile 11", expectedFileID: nil),
            .delete(path: "\(s)/Profile 11/Code Cache", expectedFileID: nil),
            .delete(path: "\(s)/Profile 11/GPUCache", expectedFileID: nil),
            .delete(path: "\(s)/Profile 11/Service Worker/CacheStorage", expectedFileID: nil),
            .delete(path: "\(s)/OptGuideOnDeviceModel", expectedFileID: nil),
        ])
    }

    @Test func missingLocalStateListsDirsByName() async throws {
        let fixture = try FixtureHome()
        try fixture.file("\(Self.support)/Default/History", bytes: 10)
        try fixture.file("\(Self.support)/Profile 3/History", bytes: 10)
        try fixture.file("\(Self.support)/Crashpad/x", bytes: 10)
        let items = try await ChromeInspector().discover(in: context(fixture))
        let profiles = items.filter { $0.id.hasPrefix("chrome.profile.") }
        #expect(profiles.map(\.title) == ["Default", "Profile 3"])
        #expect(profiles.allSatisfy { $0.lastUsed == nil })
    }

    @Test func noChromeFolderYieldsNothing() async throws {
        let fixture = try FixtureHome()
        let items = try await ChromeInspector().discover(in: context(fixture))
        #expect(items.isEmpty)
    }

    @Test func activeProfileHasNoRemoveButton() async throws {
        let fixture = try makeFixture()
        let items = try await ChromeInspector().discover(in: context(fixture))
        let active = try #require(items.first { $0.id == "chrome.profile.Default" })
        #expect(active.actionTitle == "Active profile — can't remove")
        #expect(!active.isActionable)
        #expect(items.filter { $0.id.hasPrefix("chrome.cache.") }.allSatisfy { $0.isActionable })
    }

    @Test func missingLocalStateDisablesRemoval() async throws {
        let fixture = try FixtureHome()
        try fixture.file("\(Self.support)/Default/History", bytes: 10)
        try fixture.file("\(Self.support)/Profile 3/History", bytes: 10)
        let ctx = context(fixture)
        let inspector = ChromeInspector()
        let items = try await inspector.discover(in: ctx)
        let profiles = items.filter { $0.id.hasPrefix("chrome.profile.") }
        #expect(profiles.allSatisfy { $0.subtitle == "Chrome's profile list couldn't be read — removal disabled" })
        #expect(!profiles.isEmpty && profiles.allSatisfy { !$0.isActionable })
        let plan = try await inspector.plan(for: profiles, in: ctx)
        #expect(plan.steps.isEmpty)
    }

    @Test func malformedLocalStateDisablesRemoval() async throws {
        let fixture = try FixtureHome()
        try fixture.file("\(Self.support)/Default/History", bytes: 10)
        try fixture.file("\(Self.support)/Profile 3/History", bytes: 10)
        try Data("{ not json".utf8).write(to: fixture.home.appendingPathComponent("\(Self.support)/Local State"))
        let ctx = context(fixture)
        let inspector = ChromeInspector()
        let profiles = try await inspector.discover(in: ctx).filter { $0.id.hasPrefix("chrome.profile.") }
        #expect(profiles.count == 2)
        #expect(profiles.allSatisfy { $0.subtitle == "Chrome's profile list couldn't be read — removal disabled" })
        #expect(profiles.allSatisfy { !$0.isActionable })
        let plan = try await inspector.plan(for: profiles, in: ctx)
        #expect(plan.steps.isEmpty)
    }

    @Test func profileAndItsCacheInOnePlanDoNotDoubleCount() async throws {
        let fixture = try makeFixture()
        let ctx = context(fixture)
        let inspector = ChromeInspector()
        let items = try await inspector.discover(in: ctx)
        let selected = items.filter { $0.id == "chrome.profile.Profile 11" || $0.id == "chrome.cache.Profile 11" }
        #expect(selected.count == 2)
        let plan = try await inspector.plan(for: selected, in: ctx)
        let home = fixture.home.path
        let root = "\(home)/\(Self.support)"
        #expect(plan.steps.map(\.action) == [
            .trash(path: "\(root)/Profile 11", expectedFileID: nil),
            .removeJSONKeys(path: "\(root)/Local State", edits: Self.profile11Edits),
            .delete(path: "\(home)/\(Self.caches)/Profile 11", expectedFileID: nil),
        ])
        #expect(plan.steps.last?.estimatedBytes == 70)
    }

    @Test func nonActiveDefaultIsRemovableAndOmitsAbsentArrays() async throws {
        let fixture = try makeFixture()
        let root = "\(Self.support)"
        try fixture.json("\(root)/Local State", [
            "profile": [
                "info_cache": [
                    "Default": ["name": "Person 1", "user_name": "a@example.test", "active_time": 1.0],
                    "Profile 2": ["name": "Work", "user_name": "b@example.test", "active_time": 2.0],
                ],
                "profiles_order": ["Default", "Profile 2"],
                "last_active_profiles": ["Profile 2"],
                "last_used": "Profile 2",
            ],
        ])
        let ctx = context(fixture)
        let inspector = ChromeInspector()
        let items = try await inspector.discover(in: ctx)
        let item = try #require(items.first { $0.id == "chrome.profile.Default" })
        #expect(item.actionTitle == "Remove profile")
        let plan = try await inspector.plan(for: [item], in: ctx)
        let abs = "\(fixture.home.path)/\(root)"
        #expect(plan.steps.map(\.action) == [
            .trash(path: "\(abs)/Default", expectedFileID: nil),
            .removeJSONKeys(path: "\(abs)/Local State", edits: [
                .removeKey(["profile", "info_cache", "Default"]),
                .removeArrayValue(keyPath: ["profile", "profiles_order"], value: "Default"),
            ]),
        ])
    }

    @Test func unsafeProfileKeysAreIgnored() async throws {
        let fixture = try FixtureHome()
        try fixture.file("\(Self.support)/Default/History", bytes: 10)
        try fixture.json("\(Self.support)/Local State", [
            "profile": [
                "info_cache": [
                    "Default": ["name": "P", "active_time": 1.0],
                    "..": ["name": "Up"],
                    ".": ["name": "Here"],
                    "a/b": ["name": "Nested"],
                ],
                "last_used": "Default",
            ],
        ])
        let items = try await ChromeInspector().discover(in: context(fixture))
        #expect(items.filter { $0.id.hasPrefix("chrome.profile.") }.map(\.id) == ["chrome.profile.Default"])
    }

    // MARK: - Profile removal through the engine

    /// Real `PathValidator`, `ToolPolicy` and engine on the fixture home. Only the Trash is fake:
    /// trashed items move into `FakeTrash` inside the fixture.
    func engine(_ fixture: FixtureHome, chromeRunning: Bool = false) throws -> (CleanupEngine, MovingTrash) {
        let trash = try MovingTrash(folder: fixture.home.appendingPathComponent("FakeTrash"))
        let engine = CleanupEngine(
            validator: PathValidator(home: fixture.home),
            tools: FakeToolRunner(),
            apps: FakeAppChecker(running: chromeRunning ? ["com.google.Chrome"] : []),
            files: trash,
            sizer: LogicalSizer(),
            log: CleanupLog(fileURL: fixture.home.appendingPathComponent("log/cleanup-log.jsonl")),
            policy: ToolPolicy(home: fixture.home),
            freeSpace: { 0 })
        return (engine, trash)
    }

    func profilePlan(_ fixture: FixtureHome, dir: String = "Profile 11") async throws -> CleanupPlan {
        let ctx = context(fixture)
        let item = try #require(try await ChromeInspector().discover(in: ctx).first { $0.id == "chrome.profile.\(dir)" })
        return try await ChromeInspector().plan(for: [item], in: ctx)
    }

    func localState(_ fixture: FixtureHome) throws -> [String: Any] {
        let data = try Data(contentsOf: fixture.home.appendingPathComponent("\(Self.support)/Local State"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A Local State with the keys Chrome writes besides the profile list, which must survive.
    func makeRealisticFixture() throws -> FixtureHome {
        let fixture = try makeFixture()
        try fixture.json("\(Self.support)/Local State", [
            "browser": ["enabled_labs_experiments": [], "last_redirect_origin": ""],
            "os_crypt": ["encrypted_key": "c2FtcGxl"],
            "profile": [
                "info_cache": [
                    "Default": ["name": "Person 1", "user_name": "a@example.test", "active_time": 1_700_000_300.0,
                                "avatar_icon": "chrome://theme/IDR_PROFILE_AVATAR_26", "is_using_default_name": true],
                    "Profile 2": ["name": "Work", "user_name": "b@example.test", "active_time": 1_700_000_200.0],
                    "Profile 11": ["name": "Side", "user_name": "c@example.test", "active_time": 1_700_000_100.0],
                ],
                "profiles_order": ["Default", "Profile 2", "Profile 11"],
                "last_active_profiles": ["Default", "Profile 11"],
                "last_used": "Default",
                "profile_counts_reported": 1_700_000_000.0,
            ],
            "variations_seed_signature": "sample",
        ])
        return fixture
    }

    @Test func profileRemovalTrashesFolderBacksUpAndEditsOnlyThatProfile() async throws {
        let fixture = try makeRealisticFixture()
        let before = try localState(fixture)
        let originalBytes = try Data(contentsOf: fixture.home.appendingPathComponent("\(Self.support)/Local State"))
        let plan = try await profilePlan(fixture)
        let (engine, trash) = try engine(fixture)

        let report = await engine.execute(plan, acknowledged: Set(plan.steps.map(\.id)))

        guard case .trashed(_, let profileTrash) = report.results[0].outcome,
              case .edited(let backup) = report.results[1].outcome else {
            Issue.record("expected trashed then edited, got \(report.results.map(\.outcome))")
            return
        }
        // Profile folder first, then the Local State backup; both are in the Trash.
        #expect(trash.moved == [profileTrash, backup])
        #expect(FileManager.default.fileExists(atPath: profileTrash + "/Bookmarks"))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.path + "/\(Self.support)/Profile 11"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: backup)) == originalBytes)

        let after = try localState(fixture)
        let profile = try #require(after["profile"] as? [String: Any])
        let oldProfile = try #require(before["profile"] as? [String: Any])
        #expect(Set((profile["info_cache"] as? [String: Any] ?? [:]).keys) == ["Default", "Profile 2"])
        #expect(profile["profiles_order"] as? [String] == ["Default", "Profile 2"])
        #expect(profile["last_active_profiles"] as? [String] == ["Default"])
        #expect(profile["last_used"] as? String == "Default")
        // Everything else is unchanged, including the remaining profiles' entries.
        let cache = try #require(profile["info_cache"] as? NSDictionary)
        let oldCache = try #require(oldProfile["info_cache"] as? NSDictionary)
        #expect(cache["Default"] as? NSDictionary == oldCache["Default"] as? NSDictionary)
        #expect(profile["profile_counts_reported"] as? Double == 1_700_000_000.0)
        for key in ["browser", "os_crypt", "variations_seed_signature"] {
            #expect((after[key] as AnyObject).isEqual(before[key]), "\(key)")
        }
        // Other profiles and their folders are untouched.
        #expect(FileManager.default.fileExists(atPath: fixture.home.path + "/\(Self.support)/Profile 2/History"))
        #expect(FileManager.default.fileExists(atPath: fixture.home.path + "/\(Self.support)/Default/History"))
    }

    @Test func profileRemovalRefusesWhileChromeIsRunning() async throws {
        let fixture = try makeRealisticFixture()
        let original = try Data(contentsOf: fixture.home.appendingPathComponent("\(Self.support)/Local State"))
        let plan = try await profilePlan(fixture)
        let (engine, trash) = try engine(fixture, chromeRunning: true)
        let acknowledged = Set(plan.steps.map(\.id))

        let blockers = await engine.preflight(plan, acknowledged: acknowledged)
        let report = await engine.execute(plan, acknowledged: acknowledged)

        #expect(plan.steps.allSatisfy { step in
            blockers[step.id]?.contains { if case .appRunning = $0 { true } else { false } } == true
        })
        #expect(report.results.allSatisfy { if case .skipped = $0.outcome { true } else { false } })
        #expect(trash.moved.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.home.path + "/\(Self.support)/Profile 11/Bookmarks"))
        #expect(try Data(contentsOf: fixture.home.appendingPathComponent("\(Self.support)/Local State")) == original)
    }

    @Test func profileListIsNotEditedWhenTheFolderCouldNotBeTrashed() async throws {
        let fixture = try makeRealisticFixture()
        let original = try Data(contentsOf: fixture.home.appendingPathComponent("\(Self.support)/Local State"))
        let plan = try await profilePlan(fixture)
        let (engine, trash) = try engine(fixture)
        trash.fail = true

        let report = await engine.execute(plan, acknowledged: Set(plan.steps.map(\.id)))

        guard case .failed = report.results[0].outcome, case .skipped = report.results[1].outcome else {
            Issue.record("expected failed then skipped, got \(report.results.map(\.outcome))")
            return
        }
        #expect(try Data(contentsOf: fixture.home.appendingPathComponent("\(Self.support)/Local State")) == original)
    }

    @Test func localStateThatBecameUnparseableIsLeftAlone() async throws {
        let fixture = try makeRealisticFixture()
        let plan = try await profilePlan(fixture)
        // Chrome rewrote the file between review and cleanup, and it is not JSON any more.
        let garbage = Data("{ truncated".utf8)
        try garbage.write(to: fixture.home.appendingPathComponent("\(Self.support)/Local State"))
        let (engine, trash) = try engine(fixture)

        let report = await engine.execute(plan, acknowledged: Set(plan.steps.map(\.id)))

        guard case .trashed = report.results[0].outcome, case .failed = report.results[1].outcome else {
            Issue.record("expected trashed then failed, got \(report.results.map(\.outcome))")
            return
        }
        #expect(trash.moved.count == 1)  // only the profile folder; no backup was made
        #expect(try Data(contentsOf: fixture.home.appendingPathComponent("\(Self.support)/Local State")) == garbage)
    }

    @Test func localStateRemovedBeforeCleanupStopsTheEdit() async throws {
        let fixture = try makeRealisticFixture()
        let plan = try await profilePlan(fixture)
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("\(Self.support)/Local State"))
        let (engine, _) = try engine(fixture)

        let report = await engine.execute(plan, acknowledged: Set(plan.steps.map(\.id)))

        guard case .skipped = report.results[1].outcome else {
            Issue.record("expected the edit skipped, got \(report.results[1].outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.home.path + "/\(Self.support)/Local State"))
    }

    @Test func localStateWithoutLastUsedDisablesRemoval() async throws {
        let fixture = try makeFixture()
        try fixture.json("\(Self.support)/Local State", [
            "profile": ["info_cache": ["Default": ["name": "P"], "Profile 2": ["name": "W"]]],
        ])
        try fixture.file("\(Self.support)/Profile 2/History", bytes: 10)
        let ctx = context(fixture)
        let profiles = try await ChromeInspector().discover(in: ctx).filter { $0.id.hasPrefix("chrome.profile.") }
        #expect(!profiles.isEmpty && profiles.allSatisfy { !$0.isActionable })
        #expect(try await ChromeInspector().plan(for: profiles, in: ctx).steps.isEmpty)
    }
}

/// Real file operations, except `trash`, which moves the item into a folder inside the fixture.
final class MovingTrash: FileOperating {
    let folder: URL
    private let state = Mutex<(moved: [String], fail: Bool)>(([], false))
    private let real = RealFileOperations()

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var moved: [String] { state.withLock { $0.moved } }
    var fail: Bool {
        get { state.withLock { $0.fail } }
        set { state.withLock { $0.fail = newValue } }
    }

    func trash(_ path: String) throws -> String {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(URL(fileURLWithPath: path).lastPathComponent)").path
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        state.withLock { $0.moved.append(destination) }
        return destination
    }

    func remove(_ path: String) throws { try real.remove(path) }
    func read(_ path: String) throws -> Data { try real.read(path) }
    func write(_ data: Data, to path: String) throws { try real.write(data, to: path) }
}
