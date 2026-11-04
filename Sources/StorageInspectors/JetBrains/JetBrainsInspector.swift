import Foundation
import StorageCore

/// Cleans per-version JetBrains IDE caches and logs, and offers to trash the settings of IDE
/// versions that are no longer installed. Settings of installed versions are never offered.
public struct JetBrainsInspector: Inspector {
    public let id = "jetbrains"
    public let displayName = "JetBrains IDEs"
    public let bundleIDs: [String] = []
    public let claimedPatterns: [String] = [
        "~/Library/Caches/JetBrains/*",
        "~/Library/Application Support/JetBrains/*",
        "~/Library/Logs/JetBrains/*",
    ]
    public let category: StorageCategory? = .developerTools

    /// Folders scanned for installed IDEs; a leading `~/` expands to the context home.
    private let applicationRoots: [String]

    public init(applicationRoots: [String] = ["/Applications", "~/Applications"]) {
        self.applicationRoots = applicationRoots
    }

    private struct Installed {
        let bundleID: String
        let productName: String
        let version: String
    }

    public func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        let installed = installedProducts(in: context)
        let library = context.home.appendingPathComponent("Library")
        let cachesRoot = library.appendingPathComponent("Caches/JetBrains").path
        let logsRoot = library.appendingPathComponent("Logs/JetBrains").path
        let supportRoot = library.appendingPathComponent("Application Support/JetBrains").path

        var items: [InspectorItem] = []

        let cacheNames = Set(versionedNames(in: cachesRoot) + versionedNames(in: logsRoot))
        for name in cacheNames.sorted() {
            guard let (product, version) = split(name) else { continue }
            let paths = [cachesRoot, logsRoot]
                .map { ($0 as NSString).appendingPathComponent(name) }
                .filter { exists($0) }
            guard !paths.isEmpty else { continue }
            let requirement: AppStateRequirement = installed[PathKeyFold.fold(name)]
                .map { .mustBeQuit(bundleIDs: [$0.bundleID], processNames: []) } ?? .none
            items.append(InspectorItem(
                id: "jetbrains.cache.\(name)",
                inspectorID: id,
                title: "\(installed[PathKeyFold.fold(name)]?.productName ?? product) \(version) caches",
                subtitle: installed[PathKeyFold.fold(name)] == nil ? "IDE version not installed" : nil,
                whatYouLose: "Indexes and logs; the IDE re-indexes projects on next start.",
                allocatedBytes: await total(paths, context),
                risk: .cache,
                lastUsed: newestModification(paths),
                paths: paths,
                requirement: requirement,
                actionTitle: "Delete caches"
            ))
        }

        for name in versionedNames(in: supportRoot).sorted() {
            guard let (product, version) = split(name), installed[PathKeyFold.fold(name)] == nil else { continue }
            let path = (supportRoot as NSString).appendingPathComponent(name)
            items.append(InspectorItem(
                id: "jetbrains.settings.\(name)",
                inspectorID: id,
                title: "\(installed[PathKeyFold.fold(name)]?.productName ?? product) \(version) settings",
                subtitle: "IDE version not installed",
                whatYouLose: "Settings, keymaps, plugins and licenses of this IDE version.",
                allocatedBytes: await context.sizer.allocatedSize(of: path),
                risk: .userData,
                lastUsed: newestModification([path]),
                paths: [path],
                requirement: .none,
                actionTitle: "Move settings to Trash"
            ))
        }
        return items
    }

    public func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        var steps: [CleanupStep] = []
        for item in items where item.inspectorID == id {
            let isSettings = item.id.hasPrefix("jetbrains.settings.")
            for path in item.paths {
                let bytes = await context.sizer.allocatedSize(of: path)
                steps.append(CleanupStep(
                    title: "\(item.title): \((path as NSString).deletingLastPathComponent.split(separator: "/").suffix(2).joined(separator: "/"))",
                    risk: item.risk,
                    estimatedBytes: bytes,
                    requirement: item.requirement,
                    action: isSettings
                        ? .trash(path: path, expectedFileID: nil)
                        : .delete(path: path, expectedFileID: nil)
                ))
            }
        }
        return CleanupPlan(steps: steps)
    }

    // MARK: - Helpers

    /// Installed IDEs keyed by case-folded data directory name.
    private func installedProducts(in context: InspectorContext) -> [String: Installed] {
        var result: [String: Installed] = [:]
        let manager = FileManager.default
        for root in applicationRoots {
            let rootPath = root.hasPrefix("~/")
                ? context.home.appendingPathComponent(String(root.dropFirst(2))).path
                : root
            var bundles: [String] = []
            for name in (try? manager.contentsOfDirectory(atPath: rootPath)) ?? [] {
                let path = (rootPath as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    bundles.append(path)
                } else {
                    // JetBrains Toolbox keeps IDEs one folder deeper.
                    for inner in (try? manager.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                        bundles.append((path as NSString).appendingPathComponent(inner))
                    }
                }
            }
            for bundle in bundles {
                guard let product = readProduct(bundle) else { continue }
                result[PathKeyFold.fold(product.key)] = product.value
            }
        }
        return result
    }

    private func readProduct(_ bundle: String) -> (key: String, value: Installed)? {
        let infoURL = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID.hasPrefix("com.jetbrains."),
              let shortVersion = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        let version = shortVersion.split(separator: ".").prefix(2).joined(separator: ".")

        let productInfoURL = URL(fileURLWithPath: bundle).appendingPathComponent("Contents/Resources/product-info.json")
        var dataDirectory: String?
        if let infoData = try? Data(contentsOf: productInfoURL),
           let json = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
           let name = json["dataDirectoryName"] as? String, !name.isEmpty {
            dataDirectory = name
        }
        let productName = (plist["CFBundleName"] as? String)
            ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
        let key = dataDirectory ?? "\(productName.filter { !$0.isWhitespace })\(version)"
        return (key, Installed(bundleID: bundleID, productName: productName, version: version))
    }

    /// Directory names under `root` that look like `<Product><YYYY.N>`.
    private func versionedNames(in root: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { split($0) != nil }
    }

    /// Splits `IntelliJIdea2025.2` into (`IntelliJIdea`, `2025.2`).
    private func split(_ name: String) -> (String, String)? {
        guard let match = name.firstMatch(of: /^(.+?)(\d{4}\.\d+)$/) else { return nil }
        return (String(match.1), String(match.2))
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func total(_ paths: [String], _ context: InspectorContext) async -> Int64 {
        var sum: Int64 = 0
        for path in paths { sum += await context.sizer.allocatedSize(of: path) }
        return sum
    }

    private func newestModification(_ paths: [String]) -> Date? {
        paths.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }.max()
    }
}

private enum PathKeyFold {
    static func fold(_ string: String) -> String { string.lowercased() }
}
