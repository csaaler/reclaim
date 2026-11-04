import Foundation
import Testing
import StorageCore
import StorageTestKit

@Suite struct AttributionTests {
    let fx: FixtureHome
    var home: URL { fx.home }
    func p(_ rel: String) -> String { home.appendingPathComponent(rel).path }

    init() throws { fx = try FixtureHome() }

    @Test func cachesRule() {
        let m = LocationRules.match(p("Library/Caches/com.spotify.client"), home: home)
        #expect(m?.kind == .cache)
        #expect(m?.ownerToken == "com.spotify.client")
        #expect(LocationRules.match(p("Library/Caches/com.spotify.client/sub"), home: home) == nil)
        #expect(LocationRules.match(p("Library/Caches"), home: home) == nil)
        #expect(LocationRules.match(p("library/caches/COM.Spotify.client"), home: home)?.kind == .cache)
    }

    @Test func logsRule() {
        let m = LocationRules.match(p("Library/Logs/Foo"), home: home)
        #expect(m?.kind == .logs)
        #expect(m?.ownerToken == "Foo")
    }

    @Test func containerCachesRule() {
        let m = LocationRules.match(p("Library/Containers/com.x/Data/Library/Caches/foo"), home: home)
        #expect(m?.kind == .cache)
        #expect(m?.ownerToken == "com.x")
        #expect(LocationRules.match(p("Library/Containers/com.x/Data/Library/Caches/foo/bar"), home: home) == nil)
    }

    @Test func groupContainerCachesRule() {
        let m = LocationRules.match(
            p("Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/Library/Caches/x"), home: home)
        #expect(m?.ownerToken == "ru.keepcoder.Telegram")
        #expect(m?.kind == .cache)
    }

    @Test func appleExcluded() {
        #expect(LocationRules.match(p("Library/Caches/com.apple.Safari"), home: home)?.isAppleOwned == true)
        #expect(LocationRules.match(p("Library/Caches/COM.APPLE.x"), home: home)?.isAppleOwned == true)
        #expect(LocationRules.match(p("Library/Caches/com.spotify.client"), home: home)?.isAppleOwned == false)
    }

    @Test func appleGroupContainersExcluded() {
        func apple(_ token: String) -> Bool? {
            LocationRules.match(p("Library/Group Containers/\(token)/Library/Caches/x"), home: home)?.isAppleOwned
        }
        #expect(apple("group.com.apple.foo") == true)
        #expect(apple("groups.com.apple.foo") == true)
        #expect(apple("ABCDE12345.groups.com.apple.foo") == true)
        #expect(apple("ABCDE12345.com.apple.foo") == true)
        #expect(apple("group.is.workflow.shortcuts") == true)
        #expect(apple("ABCDE12345.group.com.spotify.client") == false)
        #expect(apple("group.net.whatsapp.WhatsApp.shared") == false)
        #expect(LocationRules.match(p("Library/Caches/group.com.apple.foo"), home: home)?.isAppleOwned == true)
    }

    @Test func reverseDNSOwnerTokens() {
        #expect(OwnerToken.looksLikeBundleID("us.zoom.xos"))
        #expect(OwnerToken.looksLikeBundleID("com.gone-app.helper"))
        #expect(!OwnerToken.looksLikeBundleID("node-v18.0.1"))
        #expect(!OwnerToken.looksLikeBundleID("Sublime Text 3.2.1"))
        #expect(!OwnerToken.looksLikeBundleID("com.example"))
        #expect(!OwnerToken.looksLikeBundleID("com..example.app"))
    }

    @Test func teamPrefixIsTenUppercaseCharacters() {
        #expect(OwnerToken.stripTeamPrefix("UBF8T346G9.com.microsoft.oneauth") == "com.microsoft.oneauth")
        #expect(OwnerToken.stripTeamPrefix("consulting.acme.tool") == "consulting.acme.tool")
        #expect(OwnerToken.stripTeamPrefix("ubf8t346g9.com.x.y") == "ubf8t346g9.com.x.y")
    }

    /// A lowercase 10-letter first segment is part of the bundle ID, not a team prefix, in every
    /// place that reads group container names.
    @Test func lowercaseFirstSegmentIsNotATeamPrefix() {
        let app = InstalledApp(bundleID: "consulting.acme.tool", name: "Acme Tool", path: "/Applications/Acme Tool.app")
        let index = AppIndex(apps: [app])
        #expect(index.app(teamPrefixedGroup: "consulting.acme.tool") == app)
        #expect(index.app(teamPrefixedGroup: "ABCDE12345.consulting.acme.tool") == app)

        let cache = p("Library/Group Containers/consulting.acme.tool/Library/Caches/x")
        #expect(LocationRules.match(cache, home: home)?.ownerToken == "consulting.acme.tool")
        let a = Attributor(index: index, definitions: [], home: home)
        #expect(a.attribute(cache)?.appKey == "consulting.acme.tool")
        #expect(a.attribute(p("Library/Group Containers/consulting.acme.tool"))?.appKey == "consulting.acme.tool")
        // An uppercase team prefix is still removed.
        #expect(a.attribute(p("Library/Group Containers/ABCDE12345.consulting.acme.tool"))?.appKey == "consulting.acme.tool")
    }

    @Test func orphanDetected() {
        let path = p("Library/Application Support/com.gone.App")
        let orphan = Attributor(index: AppIndex(apps: []), definitions: [], home: home).attribute(path)
        #expect(orphan?.isOrphan == true)
        #expect(orphan?.isInstalled == false)
        let app = InstalledApp(bundleID: "com.gone.App", name: "Gone", path: "/Applications/Gone.app")
        let found = Attributor(index: AppIndex(apps: [app]), definitions: [], home: home).attribute(path)
        #expect(found?.isInstalled == true)
        #expect(found?.isOrphan == false)
    }

    @Test func appleNotOrphan() {
        let a = Attributor(index: AppIndex(apps: []), definitions: [], home: home)
        #expect(a.attribute(p("Library/Caches/com.apple.Safari")) == nil)
    }

    @Test func nameMatch() {
        let app = InstalledApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app")
        let a = Attributor(index: AppIndex(apps: [app]), definitions: [], home: home)
        let r = a.attribute(p("Library/Application Support/slack"))
        #expect(r?.appKey == "com.tinyspeck.slackmacgap")
        #expect(r?.isInstalled == true)
    }

    @Test func definitionWins() {
        let def = AppDefinition(
            id: "claude", displayName: "Claude", bundleIDs: ["com.anthropic.claudefordesktop"],
            processNames: ["Claude"],
            locations: [DefinedLocation(pattern: "~/Library/Application Support/Claude/*", kind: .rebuildable, note: "")])
        let a = Attributor(index: AppIndex(apps: []), definitions: [def], home: home)
        let r = a.attribute(p("Library/Application Support/Claude/vm_bundles"))
        #expect(r?.appKey == "claude")
        #expect(r?.isOrphan == false)
        #expect(a.attribute(p("Library/Application Support/Claude/vm_bundles/deep"))?.appKey == "claude")
    }

    @Test func containerMetadata() throws {
        let plist: [String: Any] = ["MCMMetadataIdentifier": "com.docker.docker"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let meta = home.appendingPathComponent(
            "Library/Containers/ABC-UUID/.com.apple.containermanagerd.metadata.plist")
        try FileManager.default.createDirectory(at: meta.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: meta)
        let app = InstalledApp(bundleID: "com.docker.docker", name: "Docker", path: "/Applications/Docker.app")
        let a = Attributor(index: AppIndex(apps: [app]), definitions: [], home: home)
        let r = a.attribute(p("Library/Containers/ABC-UUID/Data/Library/Caches/foo"))
        #expect(r?.appKey == "com.docker.docker")
        #expect(r?.displayName == "Docker")
    }

    /// A container the scan could not open is not read again: without Full Disk Access the read
    /// would wait on a privacy prompt.
    @Test func containerMetadataSkippedForUnreadableContainer() throws {
        let plist: [String: Any] = ["MCMMetadataIdentifier": "com.docker.docker"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let meta = home.appendingPathComponent(
            "Library/Containers/ABC-UUID/.com.apple.containermanagerd.metadata.plist")
        try FileManager.default.createDirectory(at: meta.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: meta)
        let app = InstalledApp(bundleID: "com.docker.docker", name: "Docker", path: "/Applications/Docker.app")
        let a = Attributor(index: AppIndex(apps: [app]), definitions: [], home: home,
                           unreadablePaths: [p("Library/Containers/ABC-UUID")])
        let r = a.attribute(p("Library/Containers/ABC-UUID/Data/Library/Caches/foo"))
        #expect(r?.appKey != "com.docker.docker")
    }

    @Test func scanInstalledReadsFixtureApps() throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.x.App", "CFBundleName": "X", "CFBundleShortVersionString": "1.2",
        ]
        func makeApp(_ rel: String) throws {
            let dir = home.appendingPathComponent(rel + "/Contents")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: dir.appendingPathComponent("Info.plist"))
        }
        try makeApp("Apps/X.app")
        try makeApp("Apps/Suite/Y.app")
        try makeApp("Flat/Z.app")
        try makeApp("Flat/Sub/W.app")
        let index = AppIndex.scanInstalled(
            home: home, nestedRoots: [home.appendingPathComponent("Apps")],
            flatRoots: [home.appendingPathComponent("Flat")])
        #expect(index.apps.count == 3)
        #expect(index.app(bundleID: "COM.X.APP")?.version == "1.2")
        #expect(index.app(named: "y") != nil)
        #expect(index.app(teamPrefixedGroup: "6N38VWS5BX.com.x.App") != nil)
    }
}
