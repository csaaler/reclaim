import Foundation

extension StorageSnapshot {
    /// Made-up fixture data for previews and UI work: a 500 GB disk with round sizes.
    /// Home is `/Users/sample`; sizes are decimal GB like Finder.
    public static let sample: StorageSnapshot = SampleData.snapshot()
}

private enum SampleData {
    static let home = "/Users/sample"
    static let now = Date(timeIntervalSince1970: 1_793_664_000) // 2026-11-03

    static func gb(_ value: Double) -> Int64 { Int64(value * 1_000_000_000) }
    static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    static func h(_ relative: String) -> String { home + "/" + relative }

    static func quit(_ bundleIDs: [String], _ processNames: [String] = []) -> AppStateRequirement {
        .mustBeQuit(bundleIDs: bundleIDs, processNames: processNames)
    }

    static func loc(
        _ path: String,
        _ size: Double,
        _ kind: LocationKind,
        days: Double?,
        note: String? = nil,
        _ cleanability: Cleanability = .cleanable,
        _ source: AttributionSource,
        _ requirement: AppStateRequirement
    ) -> AttributedLocation {
        AttributedLocation(
            path: path,
            allocatedBytes: gb(size),
            lastModified: days.map(daysAgo),
            kind: kind,
            note: note,
            cleanability: cleanability,
            source: source,
            requirement: requirement
        )
    }

    static func app(
        _ id: String,
        _ name: String,
        installed: Bool = true,
        orphan: Bool = false,
        inspectors: [String] = [],
        _ locations: [AttributedLocation]
    ) -> AppFootprint {
        AppFootprint(
            id: id,
            displayName: name,
            isInstalled: installed,
            isOrphan: orphan,
            locations: locations.sorted { $0.allocatedBytes > $1.allocatedBytes },
            inspectorIDs: inspectors
        )
    }

    // MARK: Apps

    static func apps() -> [AppFootprint] {
        let chromeQuit = quit(["com.google.Chrome"], ["Google Chrome"])
        let dockerRunning = AppStateRequirement.mustBeRunning(
            bundleIDs: ["com.docker.docker"],
            processNames: ["com.docker.backend"],
            reason: "Docker must be running so it can prune its own data"
        )
        let xcodeQuit = quit(["com.apple.dt.Xcode", "com.apple.iphonesimulator"], ["Xcode", "Simulator"])
        let studioQuit = quit(["com.google.android.studio"], ["studio", "qemu-system-aarch64"])
        let claudeQuit = quit(["com.anthropic.claudefordesktop"], ["Claude"])
        let codeQuit = quit(["com.microsoft.VSCode"], ["Code"])

        let list = [
            app("xcode", "Xcode & Simulators", inspectors: ["xcode"], [
                loc(h("Library/Developer/CoreSimulator"), 20, .rebuildable, days: 2,
                    note: "Simulator devices and their data", .claimed(inspectorID: "xcode"), .inspector("xcode"), xcodeQuit),
                loc("/Library/Developer/CoreSimulator", 10, .rebuildable, days: 40,
                    note: "Simulator runtimes, removed with xcrun simctl", .claimed(inspectorID: "xcode"), .inspector("xcode"), xcodeQuit),
                loc(h("Library/Developer/Xcode/DerivedData"), 5, .cache, days: 1,
                    note: "Build products; Xcode rebuilds them", .claimed(inspectorID: "xcode"), .inspector("xcode"), xcodeQuit),
                loc(h("Library/Developer/Xcode/iOS DeviceSupport"), 1, .rebuildable, days: 120,
                    note: "Debug symbols for connected devices", .claimed(inspectorID: "xcode"), .inspector("xcode"), xcodeQuit),
            ]),
            app("android-studio", "Android Studio", inspectors: ["android"], [
                loc(h("Library/Android/sdk"), 20, .rebuildable, days: 15,
                    note: "SDK platforms and system images", .claimed(inspectorID: "android"), .inspector("android"), studioQuit),
                loc(h(".android/avd"), 10, .userData, days: 33,
                    note: "Emulator devices, including their installed apps", .claimed(inspectorID: "android"), .inspector("android"), studioQuit),
            ]),
            app("chrome", "Google Chrome", inspectors: ["chrome"], [
                loc(h("Library/Application Support/Google/Chrome"), 20, .userData, days: 0,
                    note: "4 profiles and the on-device model", .claimed(inspectorID: "chrome"), .inspector("chrome"), chromeQuit),
                loc(h("Library/Caches/Google/Chrome"), 5, .cache, days: 0,
                    .claimed(inspectorID: "chrome"), .inspector("chrome"), chromeQuit),
            ]),
            app("docker", "Docker", inspectors: ["docker"], [
                loc(h("Library/Containers/com.docker.docker"), 20, .rebuildable, days: 0,
                    note: "VM disk image; prune with Docker instead of deleting", .claimed(inspectorID: "docker"), .inspector("docker"), dockerRunning),
            ]),
            app("jetbrains", "JetBrains IDEs", inspectors: ["jetbrains"], [
                loc(h("Library/Caches/JetBrains"), 10, .cache, days: 3,
                    note: "Indexes for 4 IDE versions", .claimed(inspectorID: "jetbrains"), .inspector("jetbrains"), .none),
                loc(h("Library/Application Support/JetBrains"), 5, .config, days: 3,
                    note: "Settings and plugins", .claimed(inspectorID: "jetbrains"), .inspector("jetbrains"), .none),
                loc(h("Library/Logs/JetBrains"), 0.5, .logs, days: 3,
                    .claimed(inspectorID: "jetbrains"), .inspector("jetbrains"), .none),
            ]),
            app("claude", "Claude", [
                loc(h("Library/Application Support/Claude/vm_bundles"), 10.0, .rebuildable, days: 6,
                    note: "Downloaded VM images; Claude downloads them again when needed", .cleanable, .definition("claude"), claudeQuit),
                loc(h("Library/Caches/com.anthropic.claudefordesktop"), 1, .cache, days: 0,
                    .cleanable, .locationRule, claudeQuit),
                loc(h("Library/Logs/Claude"), 0.5, .logs, days: 0,
                    .cleanable, .locationRule, claudeQuit),
            ]),
            app("vscode", "Visual Studio Code", inspectors: ["updaters"], [
                loc(h(".vscode/extensions"), 2, .rebuildable, days: 9,
                    note: "Installed extensions", .cleanable, .definition("vscode"), codeQuit),
                loc(h("Library/Application Support/Code/CachedData"), 1, .cache, days: 1,
                    .cleanable, .definition("vscode"), codeQuit),
                loc(h("Library/Caches/com.microsoft.VSCode.ShipIt"), 1, .cache, days: 52,
                    note: "Leftover update download", .claimed(inspectorID: "updaters"), .inspector("updaters"), codeQuit),
            ]),
            app("spotify", "Spotify", [
                loc(h("Library/Caches/com.spotify.client"), 3, .cache, days: 0,
                    note: "Streaming cache", .cleanable, .locationRule, quit(["com.spotify.client"], ["Spotify"])),
                loc(h("Library/Application Support/Spotify"), 0.5, .userData, days: 0,
                    note: "Downloaded songs and login", .cleanable, .generic, quit(["com.spotify.client"], ["Spotify"])),
            ]),
            app("slack", "Slack", [
                loc(h("Library/Application Support/Slack/Cache"), 1, .cache, days: 0,
                    .cleanable, .definition("slack"), quit(["com.tinyspeck.slackmacgap"], ["Slack"])),
                loc(h("Library/Application Support/Slack/IndexedDB"), 0.5, .userData, days: 0,
                    note: "Offline messages; Slack downloads them again", .cleanable, .definition("slack"), quit(["com.tinyspeck.slackmacgap"], ["Slack"])),
            ]),
            app("com.apple.mail", "Mail", [
                loc(h("Library/Mail"), 2, .userData, days: 0,
                    note: "Your mailboxes", .protected, .generic, .none),
                loc(h("Library/Containers/com.apple.mail/Data/Library/Caches"), 0.5, .cache, days: 0,
                    .viewOnly(reason: "Managed by macOS"), .locationRule, quit(["com.apple.mail"], ["Mail"])),
            ]),
            app("us.zoom.xos", "zoom.us", installed: false, orphan: true, [
                loc(h("Library/Application Support/zoom.us"), 0.5, .userData, days: 210,
                    note: "App no longer installed", .cleanable, .generic, .none),
                loc(h("Library/Caches/us.zoom.xos"), 0.5, .cache, days: 210,
                    .cleanable, .locationRule, .none),
            ]),
        ]
        return list.sorted { $0.totalBytes > $1.totalBytes }
    }

    // MARK: Categories

    static func categories(apps: [AppFootprint], volume: VolumeStats, unaccountedBytes: Int64) -> [CategoryTotal] {
        let developerApps: Set<String> = ["xcode", "android-studio", "docker", "jetbrains"]
        var buckets: [StorageCategory: [AttributedLocation]] = [:]
        for app in apps {
            for location in app.locations {
                let category: StorageCategory
                if developerApps.contains(app.id) {
                    category = .developerTools
                } else {
                    switch location.kind {
                    case .cache: category = .caches
                    case .logs: category = .logs
                    case .rebuildable, .userData, .config: category = .appData
                    }
                }
                buckets[category, default: []].append(location)
            }
        }
        // Project build folders and package caches found by inspectors.
        buckets[.developerTools, default: []] += [
            loc(h("git/web-app/node_modules"), 4, .rebuildable, days: 18, .cleanable, .inspector("project-builds"), .none),
            loc(h(".gradle/caches"), 8, .cache, days: 4, .claimed(inspectorID: "native-caches"), .inspector("native-caches"), .none),
            loc(h("Library/Caches/Homebrew"), 2, .cache, days: 11, .claimed(inspectorID: "js-caches"), .inspector("js-caches"), .none),
        ]
        let fixed: [StorageCategory: Int64] = [
            .appBundles: gb(40),
            .userFiles: gb(100),
            .system: gb(15),
        ]
        var totals = StorageCategory.allCases.filter { $0 != .other }.map { category in
            let locations = (buckets[category] ?? []).sorted { $0.allocatedBytes > $1.allocatedBytes }
            let bytes = fixed[category] ?? locations.reduce(0) { $0 + $1.allocatedBytes }
            return CategoryTotal(category: category, bytes: bytes, locations: locations)
        }
        // "Other" is what remains after the categories and the unaccounted buckets.
        let accounted = totals.reduce(0) { $0 + $1.bytes }
        totals.append(CategoryTotal(category: .other, bytes: max(0, volume.usedBytes - accounted - unaccountedBytes), locations: []))
        return totals.sorted { $0.bytes > $1.bytes }
    }

    // MARK: Scan tree

    static func node(_ path: String, own: Double = 0, files: Int, days: Double?, unreadable: Bool = false,
                     _ children: [DirectorySummary] = []) -> DirectorySummary {
        DirectorySummary(
            path: path,
            allocatedBytes: gb(own) + children.reduce(0) { $0 + $1.allocatedBytes },
            fileCount: files + children.reduce(0) { $0 + $1.fileCount },
            newestModification: days.map(daysAgo),
            isUnreadable: unreadable,
            children: children.sorted { $0.allocatedBytes > $1.allocatedBytes }
        )
    }

    static func scan() -> ScanResult {
        let library = node(h("Library"), own: 1, files: 4_000, days: 0, [
            node(h("Library/Application Support"), own: 1, files: 20_000, days: 0, [
                node(h("Library/Application Support/Google"), files: 50_000, days: 0, [
                    node(h("Library/Application Support/Google/Chrome"), own: 20, files: 60_000, days: 0),
                ]),
                node(h("Library/Application Support/Claude"), own: 10, files: 1_000, days: 6),
                node(h("Library/Application Support/JetBrains"), own: 5, files: 30_000, days: 3),
                node(h("Library/Application Support/Code"), own: 2, files: 10_000, days: 1),
                node(h("Library/Application Support/Slack"), own: 2, files: 5_000, days: 0),
            ]),
            node(h("Library/Developer"), own: 26, files: 400_000, days: 1),
            node(h("Library/Android"), own: 20, files: 100_000, days: 15),
            node(h("Library/Containers"), own: 1, files: 20_000, days: 0, [
                node(h("Library/Containers/com.docker.docker"), own: 20, files: 200, days: 0),
                node(h("Library/Containers/com.apple.mail"), files: 0, days: nil, unreadable: true),
            ]),
            node(h("Library/Caches"), own: 3, files: 50_000, days: 0, [
                node(h("Library/Caches/JetBrains"), own: 10, files: 100_000, days: 3),
                node(h("Library/Caches/Google"), own: 5, files: 10_000, days: 0),
                node(h("Library/Caches/com.spotify.client"), own: 3, files: 2_000, days: 0),
                node(h("Library/Caches/Homebrew"), own: 2, files: 500, days: 11),
                node(h("Library/Caches/com.microsoft.VSCode.ShipIt"), own: 1, files: 10, days: 52),
            ]),
            node(h("Library/Mail"), own: 2, files: 200_000, days: 0),
            node(h("Library/Logs"), own: 1, files: 3_000, days: 0),
        ])
        let root = node(home, own: 0.5, files: 100, days: 0, [
            library,
            node(h("git"), own: 10, files: 1_000_000, days: 0, [
                node(h("git/web-app"), own: 1, files: 20_000, days: 18, [
                    node(h("git/web-app/node_modules"), own: 4, files: 300_000, days: 18),
                ]),
            ]),
            node(h(".android"), own: 10, files: 1_000, days: 33),
            node(h(".gradle"), own: 10, files: 100_000, days: 4),
            node(h("Documents"), own: 15, files: 20_000, days: 1),
            node(h("Downloads"), own: 10, files: 500, days: 0),
            node(h("Movies"), own: 5, files: 50, days: 60),
            node(h("Pictures"), own: 30, files: 5, days: 2),
        ])
        let largeFiles = [
            LargeFile(path: h("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"), allocatedBytes: gb(19), modified: daysAgo(0)),
            LargeFile(path: h("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel/2025.1.1.1/weights.bin"), allocatedBytes: gb(4.0), modified: daysAgo(30)),
            LargeFile(path: h("Downloads/installer.dmg"), allocatedBytes: gb(3), modified: daysAgo(14)),
            LargeFile(path: h("Movies/Screen Recording.mov"), allocatedBytes: gb(2), modified: daysAgo(60)),
            LargeFile(path: h(".android/avd/Pixel_8_API_35.avd/userdata-qemu.img"), allocatedBytes: gb(2), modified: daysAgo(33)),
            LargeFile(path: h("Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a/system.img"), allocatedBytes: gb(1), modified: daysAgo(90)),
        ]
        return ScanResult(
            root: root,
            largeFiles: largeFiles,
            unreadablePaths: [h("Library/Containers/com.apple.mail")]
        )
    }

    // MARK: Inspectors

    static func inspectors() -> [InspectorSection] {
        let chromeQuit = quit(["com.google.Chrome"], ["Google Chrome"])
        let chromeData = h("Library/Application Support/Google/Chrome")
        return [
            InspectorSection(inspectorID: "chrome", displayName: "Google Chrome", items: [
                InspectorItem(
                    id: "chrome.profile.Profile 3", inspectorID: "chrome",
                    title: "Profile “Old”", subtitle: "Profile 3 · last used 8 months ago",
                    whatYouLose: "Bookmarks, history, passwords and extensions stored only in this profile",
                    allocatedBytes: gb(5), risk: .userData, lastUsed: daysAgo(240),
                    paths: [chromeData + "/Profile 3"], requirement: chromeQuit, actionTitle: "Remove profile"
                ),
                InspectorItem(
                    id: "chrome.model.OptGuideOnDeviceModel", inspectorID: "chrome",
                    title: "On-device AI model", subtitle: "Chrome downloads it again if needed",
                    whatYouLose: "Nothing; Chrome downloads the model again when a feature needs it",
                    allocatedBytes: gb(4.0), risk: .cache, lastUsed: daysAgo(30),
                    paths: [chromeData + "/OptGuideOnDeviceModel"], requirement: chromeQuit, actionTitle: "Remove model"
                ),
                InspectorItem(
                    id: "chrome.cache.Default", inspectorID: "chrome",
                    title: "Browser cache (all profiles)", subtitle: nil,
                    whatYouLose: "Pages load slower until the cache refills",
                    allocatedBytes: gb(5), risk: .cache, lastUsed: daysAgo(0),
                    paths: [h("Library/Caches/Google/Chrome")], requirement: chromeQuit, actionTitle: "Clear cache"
                ),
            ], unavailableReason: nil),
            InspectorSection(
                inspectorID: "docker", displayName: "Docker", items: [],
                unavailableReason: "Docker is not running — start Docker Desktop to inspect it",
                category: .developerTools
            ),
            InspectorSection(inspectorID: "project-builds", displayName: "Project build folders", items: [
                InspectorItem(
                    id: "project-builds.node_modules.web-app", inspectorID: "project-builds",
                    title: "web-app/node_modules", subtitle: "~/git/web-app · untouched for 18 days",
                    whatYouLose: "Run the package manager's install again to restore it",
                    allocatedBytes: gb(4), risk: .rebuildable, lastUsed: daysAgo(18),
                    paths: [h("git/web-app/node_modules")], requirement: .none, actionTitle: "Delete folder"
                ),
                InspectorItem(
                    id: "project-builds.target.cli-tool", inspectorID: "project-builds",
                    title: "cli-tool/target", subtitle: "~/git/cli-tool · Rust build output",
                    whatYouLose: "The next cargo build starts from scratch",
                    allocatedBytes: gb(3), risk: .rebuildable, lastUsed: daysAgo(64),
                    paths: [h("git/cli-tool/target")], requirement: .none, actionTitle: "Delete folder"
                ),
            ], unavailableReason: nil, category: .developerTools),
        ]
    }

    // MARK: Assembly

    static func snapshot() -> StorageSnapshot {
        let volume = VolumeStats(
            totalBytes: gb(500),
            usedBytes: gb(400),
            availableBytes: gb(100),
            purgeableBytes: gb(5),
            systemVolumeBytes: gb(10),
            localSnapshotCount: 2
        )
        let apps = apps()
        let unaccounted = [
            UnaccountedBucket(kind: .unreadable, title: "Unreadable: 1 folder", bytes: 0,
                              explanation: "1 folder could not be read, so its size is unknown and counted under “Not explained”. Grant Full Disk Access to include it."),
            UnaccountedBucket(kind: .systemVolume, title: "macOS system volume", bytes: volume.systemVolumeBytes,
                              explanation: "The read-only macOS system volume. It is managed by macOS and cannot be cleaned."),
            UnaccountedBucket(kind: .purgeable, title: "Purgeable / local snapshots", bytes: volume.purgeableBytes,
                              explanation: "Space macOS can free on its own, including 2 local Time Machine snapshots. macOS removes them when space runs low."),
            UnaccountedBucket(kind: .notExplained, title: "Not explained", bytes: gb(10),
                              explanation: "Used space the scan did not find: unreadable folders, other volumes in the container (VM, Preboot, Recovery) and space in use by deleted-but-open files."),
        ]
        let unaccountedBytes = unaccounted.reduce(0) { $0 + $1.bytes }
        return StorageSnapshot(
            volume: volume,
            scan: scan(),
            apps: apps,
            categories: categories(apps: apps, volume: volume, unaccountedBytes: unaccountedBytes),
            inspectors: inspectors(),
            unaccounted: unaccounted
        )
    }
}
