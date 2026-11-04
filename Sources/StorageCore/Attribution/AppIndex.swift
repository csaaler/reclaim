import Foundation

public struct InstalledApp: Sendable, Hashable {
    public let bundleID: String
    public let name: String
    public let path: String
    public let version: String?

    public init(bundleID: String, name: String, path: String, version: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.version = version
    }
}

/// Lookup of installed apps by bundle ID or name. All lookups are case-insensitive.
public struct AppIndex: Sendable {
    public let apps: [InstalledApp]
    private let byBundleID: [String: InstalledApp]
    private let byName: [String: InstalledApp]

    public init(apps: [InstalledApp]) {
        self.apps = apps
        var ids: [String: InstalledApp] = [:]
        var names: [String: InstalledApp] = [:]
        for app in apps {
            ids[PathKey.fold(app.bundleID)] = ids[PathKey.fold(app.bundleID)] ?? app
            names[PathKey.fold(app.name)] = names[PathKey.fold(app.name)] ?? app
            let fileName = (app.path as NSString).lastPathComponent
            let base = fileName.hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
            if !base.isEmpty { names[PathKey.fold(base)] = names[PathKey.fold(base)] ?? app }
        }
        byBundleID = ids
        byName = names
    }

    public func app(bundleID: String) -> InstalledApp? {
        byBundleID[PathKey.fold(bundleID)]
    }

    public func app(named name: String) -> InstalledApp? {
        byName[PathKey.fold(name)]
    }

    /// Looks up a group container id such as `6N38VWS5BX.ru.keepcoder.Telegram` (team prefix stripped),
    /// also trying a leading `group.`.
    public func app(teamPrefixedGroup id: String) -> InstalledApp? {
        let stripped = OwnerToken.stripTeamPrefix(id)
        if let app = app(bundleID: stripped) { return app }
        if stripped.lowercased().hasPrefix("group.") { return app(bundleID: String(stripped.dropFirst(6))) }
        return nil
    }

    /// Scans `.app` bundles. `nestedRoots` are scanned directly and one folder level down; `flatRoots`
    /// directly only. Defaults: `/Applications` and `~/Applications` nested, `/System/Applications` flat.
    public static func scanInstalled(
        home: URL,
        nestedRoots: [URL]? = nil,
        flatRoots: [URL] = [URL(fileURLWithPath: "/System/Applications")]
    ) -> AppIndex {
        let nested = nestedRoots ?? [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
        ]
        var found: [InstalledApp] = []
        var seen = Set<PathKey>()
        func add(_ url: URL) {
            guard let app = readApp(at: url), seen.insert(PathKey(app.path)).inserted else { return }
            found.append(app)
        }
        func entries(_ dir: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
                .map { dir.appendingPathComponent($0) }
        }
        for root in nested {
            for entry in entries(root) {
                if entry.pathExtension.lowercased() == "app" {
                    add(entry)
                } else if isRealDirectory(entry) {
                    entries(entry).filter { $0.pathExtension.lowercased() == "app" }.forEach(add)
                }
            }
        }
        for root in flatRoots {
            entries(root).filter { $0.pathExtension.lowercased() == "app" }.forEach(add)
        }
        return AppIndex(apps: found)
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func readApp(at url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { return nil }
        let fileBase = url.deletingPathExtension().lastPathComponent
        let name = (plist["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (plist["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fileBase
        return InstalledApp(
            bundleID: bundleID, name: name, path: url.path,
            version: plist["CFBundleShortVersionString"] as? String)
    }
}
