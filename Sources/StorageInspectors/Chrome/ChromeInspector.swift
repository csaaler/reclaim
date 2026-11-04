import Foundation
import StorageCore

public struct ChromeInspector: Inspector {
    public let id = "chrome"
    public let displayName = "Google Chrome"
    public let bundleIDs: [String] = ["com.google.Chrome"]
    public let claimedPatterns: [String] = [
        "~/Library/Application Support/Google/Chrome/*",
        "~/Library/Caches/Google/Chrome/*",
    ]

    public init() {}

    private static let requirement = AppStateRequirement.mustBeQuit(
        bundleIDs: ["com.google.Chrome"], processNames: ["Google Chrome"]
    )
    private static let activeSubtitle = "Currently active profile — switch away in Chrome first"
    private static let unreadableSubtitle = "Chrome's profile list couldn't be read — removal disabled"
    private static let activeActionTitle = "Active profile — can't remove"
    private static let disabledActionTitle = "Removal unavailable"
    private static let profileListAcknowledgement = "Chrome's profile list will be edited (a backup goes to the Trash)"
    private static let cacheSubfolders = ["Code Cache", "GPUCache", "Service Worker/CacheStorage"]

    private func supportRoot(_ context: InspectorContext) -> String {
        context.home.appendingPathComponent("Library/Application Support/Google/Chrome").path
    }

    private func cacheRoot(_ context: InspectorContext) -> String {
        context.home.appendingPathComponent("Library/Caches/Google/Chrome").path
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Existing cache paths of one profile, in plan order.
    private func cachePaths(dir: String, context: InspectorContext) -> [String] {
        let support = supportRoot(context)
        let candidates = ["\(cacheRoot(context))/\(dir)"] + Self.cacheSubfolders.map { "\(support)/\(dir)/\($0)" }
        return candidates.filter(exists)
    }

    private func isProfileDirName(_ name: String) -> Bool {
        ChromeLocalState.isSafeDirName(name)
            && (name == "Default" || (name.hasPrefix("Profile ") && Int(name.dropFirst(8)) != nil))
    }

    public func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        let support = supportRoot(context)
        guard exists(support) else { return [] }
        let state = ChromeLocalState.load(from: URL(fileURLWithPath: support + "/Local State"))

        var profiles = state.profiles.filter { exists("\(support)/\($0.dir)") }
        let known = Set(profiles.map(\.dir))
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: support)) ?? [])
            .filter { isProfileDirName($0) && !known.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        profiles += onDisk.map { ChromeLocalState.Profile(dir: $0, name: nil, email: nil, gaiaName: nil, activeTime: nil) }

        var items: [InspectorItem] = []
        for profile in profiles {
            let path = "\(support)/\(profile.dir)"
            // Trashing the profile moves only this dir; it includes its own cache subfolders.
            // The separate Caches-folder copy is reported by the cache item.
            let bytes = await context.sizer.allocatedSize(of: path)
            // Fail safe: removal needs a readable Local State that names the active profile.
            let canRemove = state.isReadable && state.lastUsed != nil
            let isActive = profile.dir == state.lastUsed
            let subtitle = !canRemove ? Self.unreadableSubtitle : (isActive ? Self.activeSubtitle : profile.email)
            items.append(InspectorItem(
                id: "chrome.profile.\(profile.dir)",
                inspectorID: id,
                title: profile.name ?? profile.dir,
                subtitle: subtitle,
                whatYouLose: "Bookmarks, history, saved passwords, cookies and extensions of this profile (synced data stays in your Google account)",
                allocatedBytes: bytes,
                risk: .userData,
                lastUsed: profile.activeTime,
                paths: [path],
                requirement: Self.requirement,
                actionTitle: !canRemove ? Self.disabledActionTitle : (isActive ? Self.activeActionTitle : "Remove profile"),
                isActionable: canRemove && !isActive
            ))
        }

        for profile in profiles {
            let paths = cachePaths(dir: profile.dir, context: context)
            guard !paths.isEmpty else { continue }
            var bytes: Int64 = 0
            for path in paths { bytes += await context.sizer.allocatedSize(of: path) }
            items.append(InspectorItem(
                id: "chrome.cache.\(profile.dir)",
                inspectorID: id,
                title: "\(profile.name ?? profile.dir) cache",
                subtitle: profile.email,
                whatYouLose: "Cached web content; pages load a little slower once while Chrome refills it",
                allocatedBytes: bytes,
                risk: .cache,
                lastUsed: profile.activeTime,
                paths: paths,
                requirement: Self.requirement,
                actionTitle: "Clear cache"
            ))
        }

        let model = "\(support)/OptGuideOnDeviceModel"
        if exists(model) {
            items.append(InspectorItem(
                id: "chrome.model",
                inspectorID: id,
                title: "On-device AI model",
                subtitle: "Chrome may download it again",
                whatYouLose: "The downloaded on-device AI model. Chrome may download it again",
                allocatedBytes: await context.sizer.allocatedSize(of: model),
                risk: .cache,
                lastUsed: nil,
                paths: [model],
                requirement: Self.requirement,
                actionTitle: "Delete model"
            ))
        }
        return items
    }

    public func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        let support = supportRoot(context)
        let statePath = support + "/Local State"
        let stateURL = URL(fileURLWithPath: statePath)
        let state = ChromeLocalState.load(from: stateURL)
        // Fail safe: no removal unless Local State exists, parses, and names the active profile.
        let canRemove = state.isReadable && state.lastUsed != nil
            && FileManager.default.fileExists(atPath: statePath)
        var steps: [CleanupStep] = []

        // Profiles that will actually be trashed; their contents must not get separate steps.
        var trashed: [String] = []
        for item in items where item.inspectorID == id && item.id.hasPrefix("chrome.profile.") {
            let dir = String(item.id.dropFirst("chrome.profile.".count))
            guard canRemove, ChromeLocalState.isSafeDirName(dir), dir != state.lastUsed,
                  let path = item.paths.first, path == "\(support)/\(dir)" else { continue }
            trashed.append(path)
            var edits: [JSONEdit] = [.removeKey(["profile", "info_cache", dir])]
            for key in ChromeLocalState.arrayKeysContaining(dir, in: stateURL) {
                edits.append(.removeArrayValue(keyPath: ["profile", key], value: dir))
            }
            // Two steps, both 🔴 and both requiring Chrome to be quit: the profile folder goes to
            // the Trash, then, only if that succeeded, the engine removes this profile's entries
            // from Local State (its `info_cache` key and its name in `profiles_order` and
            // `last_active_profiles`) after moving a backup of Local State to the Trash. Every
            // other key is left as it was. Tests run this plan through the engine on fixture
            // files; whether Chrome then starts cleanly without listing the profile has to be
            // checked by hand against a real Chrome.
            let trashProfile = CleanupStep(
                title: "Move profile \(item.title) to Trash",
                risk: .userData,
                estimatedBytes: item.allocatedBytes,
                requirement: item.requirement,
                action: .trash(path: path, expectedFileID: nil)
            )
            steps.append(trashProfile)
            // Never edit the list for a profile that is still on disk.
            steps.append(CleanupStep(
                title: "Remove \(item.title) from Chrome's profile list",
                risk: .userData,
                estimatedBytes: 0,
                requirement: item.requirement,
                action: .removeJSONKeys(path: statePath, edits: edits),
                dependsOn: trashProfile.id,
                acknowledgement: Self.profileListAcknowledgement
            ))
        }

        for item in items where item.inspectorID == id && !item.id.hasPrefix("chrome.profile.") {
            for path in item.paths {
                let key = PathKey(path)
                if trashed.contains(where: { key.isInside(PathKey($0)) }) { continue }
                steps.append(CleanupStep(
                    title: "Delete \(item.title)",
                    risk: item.risk,
                    estimatedBytes: await context.sizer.allocatedSize(of: path),
                    requirement: item.requirement,
                    action: .delete(path: path, expectedFileID: nil)
                ))
            }
        }
        return CleanupPlan(steps: steps)
    }
}
