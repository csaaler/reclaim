import Foundation
import Testing
import StorageCore
import StorageTestKit

@Suite struct SnapshotBuilderTests {
    let fx: FixtureHome
    var home: URL { fx.home }
    func h(_ rel: String) -> String { home.appendingPathComponent(rel).path }

    static let gb: Int64 = 1_000_000_000

    init() throws { fx = try FixtureHome() }

    // MARK: Fixtures

    static let spotify = AppDefinition(
        id: "spotify", displayName: "Spotify",
        bundleIDs: ["com.spotify.client"], processNames: ["Spotify"],
        locations: [DefinedLocation(
            pattern: "~/Library/Application Support/Spotify/PersistentCache",
            kind: .cache, note: "Streaming cache")])

    static let slack = AppDefinition(
        id: "slack", displayName: "Slack",
        bundleIDs: ["com.tinyspeck.slackmacgap"], processNames: ["Slack"],
        locations: ["Cache", "Code Cache", "GPUCache"].map {
            DefinedLocation(pattern: "~/Library/Application Support/Slack/\($0)", kind: .cache,
                            note: "Chromium cache; rebuilt automatically")
        })

    var index: AppIndex {
        AppIndex(apps: [
            InstalledApp(bundleID: "com.spotify.client", name: "Spotify", path: "/Applications/Spotify.app"),
            InstalledApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app"),
            InstalledApp(bundleID: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app"),
            InstalledApp(bundleID: "com.docker.docker", name: "Docker", path: "/Applications/Docker.app"),
            InstalledApp(bundleID: "com.microsoft.Word", name: "Microsoft Word", path: "/Applications/Microsoft Word.app"),
        ])
    }

    /// Own (non-descendant) bytes per directory, relative to home unless absolute.
    var layout: [(String, Int64)] {
        [
            ("Library/Containers/com.docker.docker", 20 * Self.gb),
            ("Library/Caches/com.spotify.client", 3 * Self.gb),
            ("Library/Caches/com.apple.Safari", 400_000_000),
            ("Library/Keychains", 50_000_000),
            ("Library/Application Support/Slack", 100_000_000),
            ("Library/Application Support/Slack/Code Cache", 700_000_000),
            ("Library/Application Support/Slack/Cache", 500_000_000),
            ("Library/Application Support/Slack/IndexedDB", 600_000_000),
            ("Library/Application Support/us.zoom.xos", 700_000_000),
            ("Library/Application Support/node-v18.0.1", 90_000_000),
            ("Library/Application Support/Sublime Text 3.2.1", 80_000_000),
            ("Library/Application Support/Spotify", 40_000_000),
            ("Library/Application Support/Spotify/PersistentCache", 2 * Self.gb),
            ("Library/Containers/ExampleHelper", 10_000_000),
            ("Library/Containers/ExampleHelper/Data/Documents", 300_000_000),
            ("Library/Containers/ExampleHelper/Data/Library/Caches/thumbs", 200_000_000),
            ("Library/Logs/Spotify", 20_000_000),
            ("Library/Group Containers/group.com.apple.storekit", 5_000_000),
            ("Library/Application Support/com.spotify.client.helper", 6_000_000),
            ("Library", 5_000_000),
            ("Downloads", 1 * Self.gb),
            ("Downloads/old-project", 2 * Self.gb),
            ("Pictures/Photos Library.photoslibrary", 30 * Self.gb),
            ("Pictures/Trips", 4 * Self.gb),
            ("Documents/Locked", 1 * Self.gb),
            ("Documents/Locked/secret", 0),
            ("git/shop", 1 * Self.gb),
            ("git/shop/node_modules", 3 * Self.gb),
            ("git/shop/src", 200_000_000),
            ("git/notes", 50_000_000),
            ("Library/Group Containers/group.com.docker", 30_000_000),
            ("Library/Group Containers/UBF8T346G9.com.microsoft.oneauth", 20_000_000),
            ("Library/Group Containers/group.is.workflow.shortcuts", 15_000_000),
            ("Library/Application Support/consulting.acme.tool", 9_000_000),
            ("Library/Group Containers/group.6HB5Y2QTA3.com.example.services", 12_000_000),
            ("Library/Application Support/Google/Chrome/Default", 300_000_000),
            ("Library/Application Support/Google/Chrome/Default/Cache", 1 * Self.gb),
            ("Library/Application Support/Steam/steamapps", 500_000_000),
            ("Library/Application Support/Steam/steamapps/downloading", 4 * Self.gb),
            (".Trash", 700_000_000),
            ("/Applications/Utilities", 300_000_000),
            (".gradle/caches", 8 * Self.gb),
            (".config", 10_000_000),
            ("/Applications/Docker.app", 2 * Self.gb),
            ("/Library/Developer/CoreSimulator/Volumes", 6 * Self.gb),
            ("/Library/Audio", 1 * Self.gb),
            ("/private/var/db", 3 * Self.gb),
            ("/usr/local/bin", 100_000_000),
        ]
    }

    var unreadable: Set<String> { [h("Documents/Locked/secret")] }

    var claims: [String: [String]] {
        [
            "docker": [h("Library/Containers/com.docker.docker")],
            "project-builds": [h("git/shop/node_modules")],
            "chrome": [h("Library/Application Support/Google/Chrome/Default")],
            "updaters": [h("Library/Application Support/Steam/steamapps/downloading")],
            "native-caches": [h(".gradle/caches")],
            "xcode": ["/Library/Developer/CoreSimulator/Volumes"],
        ]
    }

    static let chromeQuit = AppStateRequirement.mustBeQuit(bundleIDs: ["com.google.Chrome"], processNames: ["Google Chrome"])

    static let steam = AppDefinition(
        id: "steam", displayName: "Steam", bundleIDs: ["com.valvesoftware.steam"], processNames: ["steam_osx"],
        locations: [DefinedLocation(pattern: "~/Library/Application Support/Steam/steamapps",
                                    kind: .rebuildable, note: "Installed games")])

    var sections: [InspectorSection] {
        [
            InspectorSection(inspectorID: "chrome", displayName: "Google Chrome", items: [
                InspectorItem(id: "chrome.cache", inspectorID: "chrome", title: "Cache", whatYouLose: "Slower loads",
                              allocatedBytes: 1 * Self.gb, risk: .cache, lastUsed: nil,
                              paths: [h("Library/Application Support/Google/Chrome/Default/Cache")],
                              requirement: Self.chromeQuit, actionTitle: "Clear cache"),
                InspectorItem(id: "chrome.profile", inspectorID: "chrome", title: "Profile", whatYouLose: "Bookmarks",
                              allocatedBytes: 300_000_000, risk: .userData, lastUsed: nil,
                              paths: [h("Library/Application Support/Google/Chrome/Default")],
                              requirement: .none, actionTitle: "Remove profile"),
            ], unavailableReason: nil),
            InspectorSection(inspectorID: "docker", displayName: "Docker", items: [], unavailableReason: "Docker is not running",
                             category: .developerTools),
            InspectorSection(inspectorID: "project-builds", displayName: "Project build folders", items: [
                InspectorItem(id: "pb.shop", inspectorID: "project-builds", title: "shop/node_modules",
                              whatYouLose: "Reinstall", allocatedBytes: 3 * Self.gb, risk: .rebuildable,
                              lastUsed: nil, paths: [h("git/shop/node_modules")], requirement: .none,
                              actionTitle: "Delete folder"),
            ], unavailableReason: nil, category: .developerTools),
            InspectorSection(inspectorID: "native-caches", displayName: "Gradle", items: [
                InspectorItem(id: "nc.gradle", inspectorID: "native-caches", title: "Gradle caches",
                              whatYouLose: "Redownload", allocatedBytes: 8 * Self.gb, risk: .cache,
                              lastUsed: nil, paths: [h(".gradle/caches")], requirement: .none,
                              actionTitle: "Delete Gradle caches"),
            ], unavailableReason: nil, category: .developerTools),
            InspectorSection(inspectorID: "xcode", displayName: "Xcode & Simulators", items: [
                // Informational: no paths, never reclaimable.
                InspectorItem(id: "xcode.admin", inspectorID: "xcode", title: "Simulator caches",
                              whatYouLose: "Requires admin", allocatedBytes: 9 * Self.gb, risk: .cache,
                              lastUsed: nil, paths: [], requirement: .none, actionTitle: "Unavailable"),
            ], unavailableReason: nil, category: .developerTools),
        ]
    }

    func scan(extra: [(String, Int64)] = []) -> ScanResult {
        var own: [String: Int64] = [:]
        for (rel, bytes) in layout + extra {
            own[rel.hasPrefix("/") ? rel : h(rel), default: 0] += bytes
        }
        let root = Tree.build(own: own, unreadable: unreadable)
        return ScanResult(root: root, largeFiles: [], unreadablePaths: unreadable.sorted())
    }

    func volume(scanned: Int64) -> VolumeStats {
        let system: Int64 = 12 * Self.gb
        let purgeable: Int64 = 2 * Self.gb
        return VolumeStats(
            totalBytes: 500 * Self.gb,
            usedBytes: scanned + system + purgeable + 3 * Self.gb,
            availableBytes: 50 * Self.gb,
            purgeableBytes: purgeable,
            systemVolumeBytes: system,
            localSnapshotCount: 2)
    }

    func build() -> (StorageSnapshot, ScanResult) {
        build(scan: scan())
    }

    func build(scan: ScanResult) -> (StorageSnapshot, ScanResult) {
        let builder = SnapshotBuilder(
            home: home, index: index, definitions: [Self.slack, Self.spotify, Self.steam],
            protected: ProtectedPaths(home: home), codeRoots: ["~/git"])
        let snapshot = builder.build(
            scan: scan, volume: volume(scanned: scan.root.allocatedBytes),
            inspectorSections: sections, claims: claims,
            inspectorBundleIDs: ["docker": ["com.docker.docker"], "xcode": ["com.apple.dt.Xcode"]])
        return (snapshot, scan)
    }

    func allLocations(_ snapshot: StorageSnapshot) -> [AttributedLocation] {
        snapshot.categories.flatMap(\.locations)
    }

    func location(_ snapshot: StorageSnapshot, _ path: String) -> AttributedLocation? {
        allLocations(snapshot).first { $0.path == path }
    }

    func app(_ snapshot: StorageSnapshot, containing path: String) -> AppFootprint? {
        snapshot.apps.first { $0.locations.contains { $0.path == path } }
    }

    func category(_ snapshot: StorageSnapshot, of path: String) -> StorageCategory? {
        snapshot.categories.first { $0.locations.contains { $0.path == path } }?.category
    }

    // MARK: Tests

    @Test func dockerContainerIsClaimed() {
        let (s, _) = build()
        let loc = location(s, h("Library/Containers/com.docker.docker"))
        #expect(loc?.cleanability == .claimed(inspectorID: "docker"))
        #expect(loc?.source == .inspector("docker"))
        #expect(loc?.allocatedBytes == 20 * Self.gb)
        let docker = app(s, containing: h("Library/Containers/com.docker.docker"))
        #expect(docker?.inspectorIDs.contains("docker") == true)
        #expect(category(s, of: h("Library/Containers/com.docker.docker")) == .developerTools)
        // The bundle joins the same footprint.
        #expect(docker?.locations.contains { $0.path == "/Applications/Docker.app" } == true)
        #expect(category(s, of: "/Applications/Docker.app") == .appBundles)
    }

    @Test func spotifyCacheIsCleanableRuleMatch() {
        let (s, _) = build()
        let loc = location(s, h("Library/Caches/com.spotify.client"))
        #expect(loc?.cleanability == .cleanable)
        #expect(loc?.kind == .cache)
        #expect(loc?.source == .locationRule)
        guard case .mustBeQuit(let ids, _) = loc?.requirement else {
            Issue.record("expected mustBeQuit, got \(String(describing: loc?.requirement))"); return
        }
        #expect(ids.contains("com.spotify.client"))
        #expect(category(s, of: h("Library/Caches/com.spotify.client")) == .caches)
        #expect(app(s, containing: h("Library/Caches/com.spotify.client"))?.id == "spotify")
        #expect(category(s, of: h("Library/Logs/Spotify")) == .logs)
    }

    @Test func appleCacheIsViewOnly() {
        let (s, _) = build()
        let loc = location(s, h("Library/Caches/com.apple.Safari"))
        #expect(loc?.cleanability == .viewOnly(reason: "Apple system cache"))
        #expect(loc?.source == .locationRule)
    }

    @Test func keychainsAreProtected() {
        let (s, _) = build()
        #expect(location(s, h("Library/Keychains"))?.cleanability == .protected)
    }

    @Test func slackDefinitionAndRemainder() {
        let (s, _) = build()
        let code = location(s, h("Library/Application Support/Slack/Code Cache"))
        #expect(code?.cleanability == .cleanable)
        #expect(code?.kind == .cache)
        #expect(code?.source == .definition("slack"))
        #expect(code?.requirement == .mustBeQuit(bundleIDs: ["com.tinyspeck.slackmacgap"], processNames: ["Slack"]))
        let rest = location(s, h("Library/Application Support/Slack"))
        #expect(rest?.cleanability == .viewOnly(reason: "No definition for this app yet"))
        // Remainder = own files + IndexedDB, not the definition folders.
        #expect(rest?.allocatedBytes == 700_000_000)
        let slack = s.apps.first { $0.id == "slack" }
        #expect(slack?.displayName == "Slack")
        #expect(slack?.totalBytes == 1_900_000_000)
        #expect(slack?.isInstalled == true)
    }

    @Test func orphanIsCleanableUserData() {
        let (s, _) = build()
        let path = h("Library/Application Support/us.zoom.xos")
        let loc = location(s, path)
        #expect(loc?.cleanability == .cleanable)
        #expect(loc?.kind == .userData)
        let zoom = app(s, containing: path)
        #expect(zoom?.isOrphan == true)
        #expect(zoom?.isInstalled == false)
    }

    @Test func versionedFolderNamesAreNotOrphans() {
        let (s, _) = build()
        for rel in ["Library/Application Support/node-v18.0.1", "Library/Application Support/Sublime Text 3.2.1"] {
            let loc = location(s, h(rel))
            #expect(loc?.cleanability == .viewOnly(reason: "No definition for this app yet"), "\(rel)")
            #expect(app(s, containing: h(rel))?.isOrphan != true, "\(rel)")
        }
    }

    @Test func appleGroupContainersAndHelpersAreNotOrphans() {
        let (s, _) = build()
        let apple = h("Library/Group Containers/group.com.apple.storekit")
        #expect(location(s, apple)?.cleanability != .cleanable)
        #expect(app(s, containing: apple)?.isOrphan != true)
        let helper = h("Library/Application Support/com.spotify.client.helper")
        #expect(app(s, containing: helper)?.id == "spotify")
        #expect(location(s, helper)?.cleanability == .viewOnly(reason: "No definition for this app yet"))
    }

    @Test func containerCachesRuleAndRemainder() {
        let (s, _) = build()
        let cache = location(s, h("Library/Containers/ExampleHelper/Data/Library/Caches/thumbs"))
        #expect(cache?.cleanability == .cleanable)
        #expect(cache?.kind == .cache)
        #expect(cache?.note == "owner unknown — make sure no related app is running")
        #expect(cache?.requirement == AppStateRequirement.none)
        let rest = location(s, h("Library/Containers/ExampleHelper"))
        #expect(rest?.allocatedBytes == 310_000_000)
        #expect(rest?.cleanability != .cleanable)
    }

    @Test func definitionLocationInsideSpotifyFolder() {
        let (s, _) = build()
        let cache = location(s, h("Library/Application Support/Spotify/PersistentCache"))
        #expect(cache?.source == .definition("spotify"))
        #expect(cache?.cleanability == .cleanable)
        #expect(app(s, containing: h("Library/Application Support/Spotify"))?.id == "spotify")
    }

    @Test func userFiles() {
        let (s, _) = build()
        let project = location(s, h("Downloads/old-project"))
        #expect(project?.cleanability == .cleanable)
        #expect(project?.kind == .userData)
        #expect(category(s, of: h("Downloads/old-project")) == .userFiles)
        #expect(category(s, of: h("Pictures/Trips")) == .userFiles)
        // Loose files directly in Downloads are listed but never cleanable as a folder.
        let loose = location(s, h("Downloads"))
        #expect(loose?.allocatedBytes == 1 * Self.gb)
        #expect(loose?.cleanability != .cleanable)
        #expect(category(s, of: h("Downloads")) == .userFiles)
    }

    @Test func largeTopLevelUserFilesAreCleanable() {
        var scan = scan(extra: [("git", 400_000_000)])
        let now = Date()
        scan.largeFiles = [
            LargeFile(path: h("Downloads/installer.dmg"), allocatedBytes: 600_000_000, modified: now),
            LargeFile(path: h("git/dump.sql"), allocatedBytes: 300_000_000, modified: now),
            // Inside a subfolder: that folder is already a cleanable location of its own.
            LargeFile(path: h("Downloads/old-project/video.mov"), allocatedBytes: 500_000_000, modified: now),
            // Not in a user or code root.
            LargeFile(path: h("Library/Application Support/Steam/steamapps/game.pak"), allocatedBytes: 400_000_000, modified: now),
        ]
        let (s, built) = build(scan: scan)

        let dmg = location(s, h("Downloads/installer.dmg"))
        #expect(dmg?.cleanability == .cleanable)
        #expect(dmg?.kind == .userData)
        #expect(dmg?.allocatedBytes == 600_000_000)
        #expect(category(s, of: h("Downloads/installer.dmg")) == .userFiles)
        #expect(location(s, h("git/dump.sql"))?.cleanability == .cleanable)
        #expect(location(s, h("Downloads/old-project/video.mov")) == nil)
        #expect(location(s, h("Library/Application Support/Steam/steamapps/game.pak")) == nil)

        // The file's bytes leave the "files directly in this folder" remainder: nothing counted twice.
        #expect(location(s, h("Downloads"))?.allocatedBytes == 1 * Self.gb - 600_000_000)
        #expect(location(s, h("Downloads"))?.cleanability != .cleanable)
        #expect(location(s, h("git"))?.allocatedBytes == 100_000_000)
        let categories = s.categories.reduce(Int64(0)) { $0 + $1.bytes }
        #expect(categories == built.root.allocatedBytes)
        let paths = allLocations(s).map(\.path)
        #expect(Set(paths).count == paths.count)
    }

    @Test func largeFileBiggerThanTheRemainderIsNotListed() {
        // A hard link counted elsewhere can make a file look bigger than its folder's own bytes.
        var scan = scan()
        scan.largeFiles = [LargeFile(path: h("Downloads/linked.bin"), allocatedBytes: 5 * Self.gb, modified: Date())]
        let (s, built) = build(scan: scan)
        #expect(location(s, h("Downloads/linked.bin")) == nil)
        #expect(location(s, h("Downloads"))?.allocatedBytes == 1 * Self.gb)
        #expect(s.categories.reduce(Int64(0)) { $0 + $1.bytes } == built.root.allocatedBytes)
    }

    @Test func photosLibraryAndUnreadableAreProtected() {
        let (s, _) = build()
        #expect(location(s, h("Pictures/Photos Library.photoslibrary"))?.cleanability == .protected)
        let locked = location(s, h("Documents/Locked"))
        #expect(locked?.cleanability == .protected)
        #expect(locked?.note == "Contains folders the app can't read")
    }

    @Test func deeplyNestedPhotosLibraryIsProtected() {
        let deep = "Library/Caches/com.spotify.client/a/b/c/d/e/Old.photoslibrary"
        let (s, _) = build(scan: scan(extra: [(deep, 5 * Self.gb)]))
        let cache = location(s, h("Library/Caches/com.spotify.client"))
        #expect(cache?.cleanability == .protected)
        #expect(cache?.note == "Contains a Photos library")
    }

    @Test func inspectorClaimsAndCategories() {
        let (s, _) = build()
        let modules = location(s, h("git/shop/node_modules"))
        #expect(modules?.cleanability == .claimed(inspectorID: "project-builds"))
        #expect(modules?.kind == .rebuildable)
        #expect(category(s, of: h("git/shop/node_modules")) == .developerTools)
        #expect(location(s, h(".gradle/caches"))?.kind == .cache)
        #expect(category(s, of: h(".gradle/caches")) == .developerTools)
        #expect(category(s, of: h(".config")) == .developerTools)
        let sim = location(s, "/Library/Developer/CoreSimulator/Volumes")
        #expect(sim?.cleanability == .claimed(inspectorID: "xcode"))
        #expect(category(s, of: "/Library/Developer/CoreSimulator/Volumes") == .developerTools)
        #expect(category(s, of: "/Library/Audio") == .system)
        #expect(category(s, of: "/private") == .system)
        // Informational inspector items stay in their section and add no bytes.
        #expect(s.inspectors.first { $0.inspectorID == "xcode" }?.items.count == 1)
        #expect(s.inspectors.first { $0.inspectorID == "docker" }?.unavailableReason == "Docker is not running")
    }

    /// By Category follows the section's category, not the inspector's ID.
    @Test func claimCategoryComesFromTheSection() {
        let builder = SnapshotBuilder(home: home, index: index, definitions: [], protected: ProtectedPaths(home: home))
        let scan = scan()
        let sections = [
            InspectorSection(inspectorID: "docker", displayName: "Docker", items: [], unavailableReason: nil),
            InspectorSection(inspectorID: "example-tool", displayName: "Example", items: [], unavailableReason: nil,
                             category: .developerTools),
        ]
        let s = builder.build(
            scan: scan, volume: volume(scanned: scan.root.allocatedBytes), inspectorSections: sections,
            claims: ["docker": [h("Library/Containers/com.docker.docker")],
                     "example-tool": [h("Library/Application Support/Spotify")]])
        #expect(category(s, of: h("Library/Containers/com.docker.docker")) == .appData)
        #expect(category(s, of: h("Library/Application Support/Spotify")) == .developerTools)
        #expect(s.inspectors.map(\.category) == [nil, .developerTools])
    }

    @Test func appTotalsEqualSumOfLocations() {
        let (s, _) = build()
        #expect(!s.apps.isEmpty)
        for app in s.apps {
            #expect(app.totalBytes == app.locations.reduce(0) { $0 + $1.allocatedBytes })
            #expect(app.totalBytes > 0)
        }
        #expect(s.apps.map(\.totalBytes) == s.apps.map(\.totalBytes).sorted(by: >))
        let docker = s.apps.first { $0.id == "com.docker.docker" }
        #expect(docker?.totalBytes == 22 * Self.gb)
    }

    @Test func totalsReconcileWithVolume() {
        let (s, scan) = build()
        let categories = s.categories.reduce(Int64(0)) { $0 + $1.bytes }
        #expect(categories == scan.root.allocatedBytes)
        for total in s.categories {
            #expect(total.bytes == total.locations.reduce(0) { $0 + $1.allocatedBytes })
        }
        let unaccounted = s.unaccounted.reduce(Int64(0)) { $0 + $1.bytes }
        let used = Double(s.volume.usedBytes)
        #expect(abs(Double(categories + unaccounted) - used) <= used * 0.01)

        let titles = s.unaccounted.map(\.title)
        #expect(titles == ["Unreadable (grant Full Disk Access): 1 folder", "macOS system volume",
                           "Purgeable / local snapshots", "Not explained"])
        #expect(s.unaccounted.map(\.kind) == [.unreadable, .systemVolume, .purgeable, .notExplained])
        #expect(s.unaccounted[0].explanation.contains("1"))
        #expect(s.unaccounted[1].bytes == 12 * Self.gb)
        #expect(s.unaccounted[2].bytes == 2 * Self.gb)
        #expect(s.unaccounted[3].bytes == 3 * Self.gb)
    }

    /// With Full Disk Access granted, what stays unreadable is protected by macOS itself, so the
    /// bucket does not tell the user to grant access again.
    @Test func unreadableBucketWithFullDiskAccess() {
        let builder = SnapshotBuilder(
            home: home, index: index, definitions: [], protected: ProtectedPaths(home: home),
            hasFullDiskAccess: true)
        let scan = scan()
        let s = builder.build(scan: scan, volume: volume(scanned: scan.root.allocatedBytes),
                              inspectorSections: [], claims: [:])
        #expect(s.unaccounted[0].title == "Unreadable: 1 folder")
        #expect(s.unaccounted[0].title.hasPrefix(SnapshotBuilder.unreadableTitlePrefix))
        #expect(s.unaccounted[0].kind == .unreadable)
        #expect(!s.unaccounted[0].explanation.contains("Grant Full Disk Access"))
    }

    @Test func noPathIsAttributedTwice() {
        let (s, _) = build()
        let paths = allLocations(s).map(\.path)
        #expect(Set(paths).count == paths.count)
        let appPaths = s.apps.flatMap(\.locations).map(\.path)
        #expect(Set(appPaths).count == appPaths.count)
        #expect(Set(appPaths).isSubset(of: Set(paths)))
        // Cleaning a cleanable location must never remove another listed location.
        let keys = paths.map { PathKey($0) }
        for location in allLocations(s) where location.cleanability == .cleanable {
            let key = PathKey(location.path)
            let nested = zip(paths, keys).filter { $0.1.isInside(key) }.map(\.0)
            #expect(nested.isEmpty, "\(location.path) contains \(nested)")
        }
    }

    @Test func claimKindIsByteWeightedAndRequirementIsStrictest() {
        let (s, _) = build()
        let profile = location(s, h("Library/Application Support/Google/Chrome/Default"))
        #expect(profile?.cleanability == .claimed(inspectorID: "chrome"))
        #expect(profile?.kind == .cache)
        #expect(profile?.requirement == Self.chromeQuit)
        // No covering items: rebuildable, managed by the inspector.
        let docker = location(s, h("Library/Containers/com.docker.docker"))
        #expect(docker?.kind == .rebuildable)
        #expect(docker?.note == "Managed by Docker")
        let sim = location(s, "/Library/Developer/CoreSimulator/Volumes")
        #expect(sim?.kind == .rebuildable)
        #expect(sim?.note == "Managed by Xcode & Simulators")
    }

    @Test func vendorSiblingsAndGroupPrefixesAreNotOrphans() {
        let (s, _) = build()
        let dockerGroup = h("Library/Group Containers/group.com.docker")
        #expect(location(s, dockerGroup)?.cleanability == .viewOnly(reason: "May belong to Docker"))
        #expect(app(s, containing: dockerGroup)?.isOrphan == false)
        let oneauth = h("Library/Group Containers/UBF8T346G9.com.microsoft.oneauth")
        #expect(location(s, oneauth)?.cleanability == .viewOnly(reason: "May belong to Microsoft Word"))
        #expect(app(s, containing: oneauth)?.isOrphan == false)
        // Shortcuts (Apple) is never an orphan; a team prefix after `group.` is looked past.
        let shortcuts = h("Library/Group Containers/group.is.workflow.shortcuts")
        #expect(location(s, shortcuts)?.cleanability != .cleanable)
        #expect(app(s, containing: shortcuts)?.isOrphan != true)
        let teamGroup = h("Library/Group Containers/group.6HB5Y2QTA3.com.example.services")
        #expect(app(s, containing: teamGroup)?.isOrphan == true)
        #expect(location(s, teamGroup)?.cleanability == .cleanable)
        // A real 10-letter first segment is not a team ID and stays part of the token.
        let consulting = h("Library/Application Support/consulting.acme.tool")
        #expect(app(s, containing: consulting)?.isOrphan == true)
        #expect(location(s, consulting)?.cleanability == .cleanable)
        // A real orphan names its own bundle ID as the quit requirement.
        let zoom = location(s, h("Library/Application Support/us.zoom.xos"))
        #expect(zoom?.requirement == .mustBeQuit(bundleIDs: ["us.zoom.xos"], processNames: []))
    }

    /// `consulting.` is a real first segment, not a team ID: the cache belongs to the installed app
    /// with that bundle ID, which must be quit before cleaning.
    @Test func groupContainerCacheWithLowercaseFirstSegmentNamesItsApp() {
        let rel = "Library/Group Containers/consulting.acme.tool/Library/Caches/thumbs"
        let app = InstalledApp(bundleID: "consulting.acme.tool", name: "Acme Tool", path: "/Applications/Acme Tool.app")
        let builder = SnapshotBuilder(home: home, index: AppIndex(apps: index.apps + [app]), definitions: [],
                                      protected: ProtectedPaths(home: home))
        let scan = scan(extra: [(rel, 50_000_000)])
        let s = builder.build(scan: scan, volume: volume(scanned: scan.root.allocatedBytes),
                              inspectorSections: [], claims: [:])
        let cache = location(s, h(rel))
        #expect(cache?.cleanability == .cleanable)
        #expect(cache?.note == nil)
        #expect(cache?.requirement == .mustBeQuit(bundleIDs: ["consulting.acme.tool"], processNames: []))
        #expect(self.app(s, containing: h(rel))?.id == "consulting.acme.tool")
    }

    @Test func onlyDirectChildrenOfUserRootsAreCleanable() {
        let (s, _) = build()
        #expect(location(s, h("git/notes"))?.cleanability == .cleanable)
        let src = location(s, h("git/shop/src"))
        #expect(src?.cleanability == .viewOnly(reason: "Inside a folder whose contents are listed separately"))
        #expect(category(s, of: h("git/shop/src")) == .userFiles)
    }

    @Test func definitionWithClaimInside() {
        let (s, _) = build()
        let downloading = location(s, h("Library/Application Support/Steam/steamapps/downloading"))
        #expect(downloading?.cleanability == .claimed(inspectorID: "updaters"))
        let steamapps = location(s, h("Library/Application Support/Steam/steamapps"))
        #expect(steamapps?.allocatedBytes == 500_000_000)
        #expect(steamapps?.cleanability != .cleanable)
        #expect(app(s, containing: h("Library/Application Support/Steam/steamapps"))?.id == "steam")
    }

    @Test func bundlesTrashAndApplicationsFolders() {
        let (s, _) = build()
        let bundle = location(s, "/Applications/Docker.app")
        #expect(bundle?.kind == .rebuildable)
        #expect(bundle?.note == "App bundle; reinstall to restore")
        #expect(bundle?.cleanability == .viewOnly(reason: "App bundle; uninstall the app to remove it"))
        let utilities = location(s, "/Applications/Utilities")
        #expect(utilities?.note == "Folder in Applications")
        #expect(utilities?.cleanability == .viewOnly(reason: "Not an app bundle"))
        let trash = location(s, h(".Trash"))
        #expect(trash?.note == "Trash")
        #expect(trash?.cleanability == .protected)
        #expect(category(s, of: h(".Trash")) == .userFiles)
    }

    @Test func notExplainedFloorsAtZero() {
        let scan = scan()
        let builder = SnapshotBuilder(home: home, index: index, definitions: [],
                                      protected: ProtectedPaths(home: home))
        let volume = VolumeStats(totalBytes: 100, usedBytes: 10, availableBytes: 90, purgeableBytes: 0,
                                 systemVolumeBytes: 5, localSnapshotCount: 0)
        let s = builder.build(scan: scan, volume: volume, inspectorSections: [], claims: [:])
        #expect(s.unaccounted.first { $0.title == "Not explained" }?.bytes == 0)
    }
}

/// Builds a `DirectorySummary` tree from per-directory own bytes; ancestors are created up to `/`.
enum Tree {
    static func build(own: [String: Int64], unreadable: Set<String>) -> DirectorySummary {
        var children: [String: Set<String>] = [:]
        var all = Set<String>(own.keys).union(unreadable)
        for path in Array(all) {
            var current = path
            while current != "/" {
                let parent = (current as NSString).deletingLastPathComponent
                children[parent, default: []].insert(current)
                all.insert(parent)
                current = parent
            }
        }
        func node(_ path: String) -> DirectorySummary {
            let kids = (children[path] ?? []).map(node).sorted { $0.allocatedBytes > $1.allocatedBytes }
            let bytes = (own[path] ?? 0) + kids.reduce(0) { $0 + $1.allocatedBytes }
            return DirectorySummary(path: path, allocatedBytes: bytes, fileCount: 1,
                                    newestModification: nil, isUnreadable: unreadable.contains(path),
                                    children: kids)
        }
        return node("/")
    }
}

@Suite struct ScanTreeSizerTests {
    struct FixedSizer: SizeMeasuring {
        func allocatedSize(of path: String) async -> Int64 { 42 }
    }

    @Test func usesTreeThenFallback() async {
        let root = Tree.build(own: ["/a/b": 100, "/a/b/c": 50, "/a/d": 7], unreadable: [])
        let sizer = ScanTreeSizer(scan: ScanResult(root: root, largeFiles: [], unreadablePaths: []), fallback: FixedSizer())
        #expect(await sizer.allocatedSize(of: "/a/b") == 150)
        #expect(await sizer.allocatedSize(of: "/a/b/") == 150)
        #expect(await sizer.allocatedSize(of: "/a/b/c") == 50)
        #expect(await sizer.allocatedSize(of: "/a") == 157)
        #expect(await sizer.allocatedSize(of: "/a/b/file.txt") == 42)
        #expect(await sizer.allocatedSize(of: "/elsewhere") == 42)
    }
}
