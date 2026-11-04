import Foundation
import StorageCore

/// npm, pnpm, Homebrew, Yarn and Bun caches, plus nvm-installed Node versions.
public struct JSCachesInspector: Inspector {
    public let id = "js-caches"
    public let displayName = "JavaScript & Homebrew"
    public let bundleIDs: [String] = []
    public let claimedPatterns: [String] = [
        "~/.npm/_cacache",
        "~/Library/pnpm/store",
        "~/Library/Caches/Homebrew",
        "~/.nvm/versions/node/*",
        "~/Library/Caches/Yarn",
        "~/.bun/install/cache",
    ]
    public let category: StorageCategory? = .developerTools
    /// Where the Bun, pnpm and Volta installers put their binaries.
    public let toolSearchDirectories = ["~/.bun/bin", "~/Library/pnpm", "~/.volta/bin"]

    public init() {}

    private struct ToolCache {
        let kind: String
        let title: String
        let relativePath: String
        let risk: RiskLevel
        let tool: String
        let arguments: [String]
        let whatYouLose: String
        let note: String?
        let actionTitle: String
    }

    private static let toolCaches: [ToolCache] = [
        ToolCache(
            kind: "npm.cache", title: "npm cache", relativePath: ".npm/_cacache", risk: .rebuildable,
            tool: "npm", arguments: ["cache", "clean", "--force"],
            whatYouLose: "Downloaded packages; they are fetched again on the next install.",
            note: nil, actionTitle: "Clean npm cache"),
        ToolCache(
            kind: "pnpm.store", title: "pnpm store", relativePath: "Library/pnpm/store", risk: .rebuildable,
            tool: "pnpm", arguments: ["store", "prune"],
            whatYouLose: "Packages no project references; they are fetched again when needed.",
            note: "Removes only packages no project references", actionTitle: "Prune pnpm store"),
        ToolCache(
            kind: "homebrew.cache", title: "Homebrew cache", relativePath: "Library/Caches/Homebrew", risk: .cache,
            tool: "brew", arguments: ["cleanup", "--prune=all", "-s"],
            whatYouLose: "Downloaded bottles and old formula versions; they are downloaded again when needed.",
            note: nil, actionTitle: "Clean Homebrew cache"),
        ToolCache(
            kind: "yarn.cache", title: "Yarn cache", relativePath: "Library/Caches/Yarn", risk: .cache,
            tool: "yarn", arguments: ["cache", "clean"],
            whatYouLose: "Downloaded packages; they are fetched again on the next install.",
            note: nil, actionTitle: "Clean Yarn cache"),
        ToolCache(
            kind: "bun.cache", title: "Bun cache", relativePath: ".bun/install/cache", risk: .cache,
            tool: "bun", arguments: ["pm", "cache", "rm"],
            whatYouLose: "Downloaded packages; they are fetched again on the next install.",
            note: nil, actionTitle: "Clean Bun cache"),
    ]

    public func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        let fm = FileManager.default
        var items: [InspectorItem] = []

        for cache in Self.toolCaches {
            let path = context.home.appendingPathComponent(cache.relativePath).path
            guard fm.fileExists(atPath: path) else { continue }
            let bytes = await context.sizer.allocatedSize(of: path)
            let missing = context.tools.locate(cache.tool) == nil
            items.append(InspectorItem(
                id: "\(id).\(cache.kind)",
                inspectorID: id,
                title: cache.title,
                subtitle: missing ? "\(cache.tool) not found" : cache.note,
                whatYouLose: cache.whatYouLose,
                allocatedBytes: bytes,
                risk: cache.risk,
                lastUsed: nil,
                paths: [path],
                requirement: .none,
                actionTitle: cache.actionTitle,
                isActionable: !missing))
        }

        let versionsDir = context.home.appendingPathComponent(".nvm/versions/node").path
        let versions = ((try? fm.contentsOfDirectory(atPath: versionsDir)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted(by: Self.versionLess)
        let defaultVersion = Self.defaultVersion(home: context.home, versions: versions)
        for version in versions.reversed() where version != defaultVersion {
            let path = versionsDir + "/" + version
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let bytes = await context.sizer.allocatedSize(of: path)
            items.append(InspectorItem(
                id: "\(id).nvm.\(version)",
                inspectorID: id,
                title: "Node \(version) (nvm)",
                subtitle: defaultVersion == nil
                    ? "Check this isn't your default"
                    : "Global packages installed in this version will be removed",
                whatYouLose: "This Node version and its globally installed packages; reinstall with nvm if needed.",
                allocatedBytes: bytes,
                risk: .rebuildable,
                lastUsed: nil,
                paths: [path],
                requirement: .none,
                actionTitle: "Remove Node \(version)"))
        }
        return items
    }

    public func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        var steps: [CleanupStep] = []
        for item in items {
            if let cache = Self.toolCaches.first(where: { item.id == "\(id).\($0.kind)" }) {
                guard let executable = context.tools.locate(cache.tool) else { continue }
                steps.append(CleanupStep(
                    title: item.actionTitle,
                    risk: item.risk,
                    estimatedBytes: item.allocatedBytes,
                    requirement: item.requirement,
                    action: .runTool(executable: executable, arguments: cache.arguments),
                    sideEffectNote: cache.note))
            } else if item.id.hasPrefix("\(id).nvm."), let path = item.paths.first {
                steps.append(CleanupStep(
                    title: item.actionTitle,
                    risk: item.risk,
                    estimatedBytes: item.allocatedBytes,
                    requirement: item.requirement,
                    action: .delete(path: path, expectedFileID: nil),
                    sideEffectNote: "Global packages installed in this version will be removed"))
            }
        }
        return CleanupPlan(steps: steps)
    }

    // MARK: nvm default resolution

    /// Numeric-aware ordering of "v20.10.0"-style names; ascending.
    private static func versionLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }

    /// The installed version `~/.nvm/alias/default` points to, or nil when it cannot be resolved.
    private static func defaultVersion(home: URL, versions: [String]) -> String? {
        let aliasDir = home.appendingPathComponent(".nvm/alias").path
        func read(_ name: String) -> String? {
            guard let text = try? String(contentsOfFile: aliasDir + "/" + name, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let newest = versions.last

        var target = read("default")
        var hops = 0
        while let current = target, hops < 8 {
            hops += 1
            if let match = match(current, in: versions) { return match }
            if let next = read(current), next != current {
                target = next
            } else if current == "node" || current == "stable" || current == "lts/*" {
                return newest
            } else {
                return nil
            }
        }
        return nil
    }

    private static func match(_ name: String, in versions: [String]) -> String? {
        guard let first = name.first, first == "v" || first.isNumber else { return nil }
        let normalized = first == "v" ? name : "v" + name
        if versions.contains(normalized) { return normalized }
        return versions.last { $0.hasPrefix(normalized + ".") }
    }
}
