import Foundation
import StorageCore

/// Finds rebuildable build folders (`node_modules`, `target`, `.build`, ...) inside the user's code roots.
///
/// `claimedPaths(in:)` is not cached: it re-runs the same walk as `discover`, so both always agree.
public struct ProjectBuildsInspector: Inspector {
    public static let defaultRoots = ["~/git", "~/code", "~/Developer", "~/Projects"]

    /// Maximum directory depth below a root that is examined (the root itself is depth 0).
    static let maxDepth = 6
    static let sideEffectNote = "Run your package manager's install/build to restore"
    /// `build` and `dist` are common names that can hold hand-made content, so they are only moved.
    static let trashedNames: Set<String> = ["build", "dist"]
    static let trashedNote = "Moved to the Trash, as it may hold files a build can't recreate; "
        + "run your package manager's install/build to restore"

    public let codeRoots: [String]

    public let id = "project-builds"
    public let displayName = "Project build folders"
    public let bundleIDs: [String] = []
    public let claimedPatterns: [String] = []
    public let category: StorageCategory? = .developerTools

    public init(codeRoots: [String] = ProjectBuildsInspector.defaultRoots) {
        self.codeRoots = codeRoots
    }

    public func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        var items: [(item: InspectorItem, bytes: Int64)] = []
        for project in findProjects(in: context) {
            var total: Int64 = 0
            for path in project.matches {
                total += await context.sizer.allocatedSize(of: path)
            }
            let names = project.matches.map { ($0 as NSString).lastPathComponent }
            items.append((
                InspectorItem(
                    id: "\(id).project.\(project.path)",
                    inspectorID: id,
                    title: (project.path as NSString).lastPathComponent,
                    subtitle: names.joined(separator: ", "),
                    whatYouLose: "Build output and dependencies; they are recreated by your next install or build.",
                    allocatedBytes: total,
                    risk: .rebuildable,
                    lastUsed: project.lastUsed,
                    paths: project.matches,
                    requirement: .none,
                    actionTitle: "Remove build folders"
                ),
                total
            ))
        }
        return items.sorted { $0.bytes > $1.bytes }.map(\.item)
    }

    public func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        var steps: [CleanupStep] = []
        for item in items {
            for path in item.paths {
                let name = (path as NSString).lastPathComponent
                let toTrash = Self.trashedNames.contains(name)
                steps.append(CleanupStep(
                    title: "\(toTrash ? "Move" : "Delete") \(name) in \(item.title)\(toTrash ? " to the Trash" : "")",
                    risk: .rebuildable,
                    estimatedBytes: await context.sizer.allocatedSize(of: path),
                    requirement: .none,
                    action: toTrash ? .trash(path: path, expectedFileID: nil) : .delete(path: path, expectedFileID: nil),
                    sideEffectNote: toTrash ? Self.trashedNote : Self.sideEffectNote
                ))
            }
        }
        return CleanupPlan(steps: steps)
    }

    public func claimedPaths(in context: InspectorContext) async -> [String] {
        findProjects(in: context).flatMap(\.matches)
    }

    // MARK: - Walking

    private struct Project {
        let path: String
        let matches: [String]
        let lastUsed: Date?
    }

    private func findProjects(in context: InspectorContext) -> [Project] {
        var projects: [Project] = []
        var seen = Set<String>()
        for root in codeRoots {
            guard let rootPath = Self.absolute(root, home: context.home), seen.insert(rootPath).inserted else { continue }
            walk(rootPath, depth: 0, into: &projects)
        }
        return projects
    }

    private static func absolute(_ root: String, home: URL) -> String? {
        if root == "~" { return home.path }
        if root.hasPrefix("~/") { return home.path + "/" + root.dropFirst(2) }
        return root.hasPrefix("/") ? root : nil
    }

    private func walk(_ dir: String, depth: Int, into projects: inout [Project]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let nameSet = Set(names)

        let matchedNames = names.filter { Self.isMatch($0, siblings: nameSet) && Self.isRealDirectory(dir + "/" + $0) }
            .sorted()
        if !matchedNames.isEmpty {
            let matched = Set(matchedNames)
            var newest: Date?
            for name in names where !matched.contains(name) {
                if let date = (try? fm.attributesOfItem(atPath: dir + "/" + name))?[.modificationDate] as? Date,
                   newest.map({ date > $0 }) ?? true {
                    newest = date
                }
            }
            projects.append(Project(path: dir, matches: matchedNames.map { dir + "/" + $0 }, lastUsed: newest))
        }

        guard depth < Self.maxDepth else { return }
        let matched = Set(matchedNames)
        for name in names.sorted() where !matched.contains(name) && !name.hasPrefix(".") {
            let child = dir + "/" + name
            if Self.isRealDirectory(child) { walk(child, depth: depth + 1, into: &projects) }
        }
    }

    private static func isMatch(_ name: String, siblings: Set<String>) -> Bool {
        func has(_ candidates: String...) -> Bool { candidates.contains { siblings.contains($0) } }
        func hasPrefix(_ prefix: String) -> Bool { siblings.contains { $0.hasPrefix(prefix) } }
        switch name {
        case "node_modules", "dist": return has("package.json")
        case "target": return has("Cargo.toml", "pom.xml")
        case "build": return has("build.gradle", "build.gradle.kts", "package.json")
        case ".gradle": return hasPrefix("settings.gradle")
        case ".next": return hasPrefix("next.config.") || has("package.json")
        case "DerivedData": return true
        case ".build": return has("Package.swift")
        case ".venv", "venv": return has("pyproject.toml", "requirements.txt")
        default: return false
        }
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
