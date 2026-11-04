import Foundation
import StorageCore

/// Finds leftover auto-update downloads (Squirrel ShipIt and `*-updater` folders).
public struct UpdaterLeftoversInspector: Inspector {
    public let applicationsRoots: [String]

    public let id = "updaters"
    public let displayName = "Updater leftovers"
    public let bundleIDs: [String] = []
    public let claimedPatterns: [String] = [
        "~/Library/Caches/*.ShipIt",
        "~/Library/Caches/*-updater",
        "~/Library/Application Support/Caches/*-updater",
    ]

    public init(applicationsRoots: [String] = ["/Applications", "~/Applications"]) {
        self.applicationsRoots = applicationsRoots
    }

    public func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        let manager = FileManager.default
        let paths = await claimedPaths(in: context).sorted()
        let apps = installedApps(home: context.home)
        var items: [InspectorItem] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { continue }
            let folder = url.lastPathComponent
            var title = folder
            var requirement = AppStateRequirement.none
            if folder.hasSuffix(".ShipIt") {
                let bundleID = String(folder.dropLast(".ShipIt".count))
                if let name = apps[bundleID] {
                    title = name
                    requirement = .mustBeQuit(bundleIDs: [bundleID], processNames: [])
                }
            }
            let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            items.append(InspectorItem(
                id: "updaters.leftover.\(path)",
                inspectorID: id,
                title: title,
                subtitle: path,
                whatYouLose: "Leftover auto-update download; the app re-downloads updates when needed",
                allocatedBytes: await context.sizer.allocatedSize(of: path),
                risk: .cache,
                lastUsed: modified,
                paths: [path],
                requirement: requirement,
                actionTitle: "Delete leftover"
            ))
        }
        return items
    }

    public func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        CleanupPlan(steps: items.flatMap { item in
            item.paths.map { path in
                CleanupStep(
                    title: "Delete \(item.title) updater leftovers",
                    risk: item.risk,
                    estimatedBytes: item.allocatedBytes,
                    requirement: item.requirement,
                    action: .delete(path: path, expectedFileID: nil),
                    sideEffectNote: "The app re-downloads updates when needed"
                )
            }
        })
    }

    /// Bundle id to display name for apps found directly in the applications roots.
    private func installedApps(home: URL) -> [String: String] {
        var result: [String: String] = [:]
        for root in applicationsRoots {
            let expanded = root.hasPrefix("~/") ? home.path + "/" + root.dropFirst(2) : root
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            for app in entries where app.pathExtension == "app" {
                let plistURL = app.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plistURL),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      let bundleID = plist["CFBundleIdentifier"] as? String,
                      result[bundleID] == nil
                else { continue }
                result[bundleID] = (plist["CFBundleDisplayName"] as? String)
                    ?? (plist["CFBundleName"] as? String)
                    ?? app.deletingPathExtension().lastPathComponent
            }
        }
        return result
    }
}
