import Foundation
import StorageCore

/// Reports what Docker itself says is reclaimable (`docker system df`) and prunes through the
/// docker CLI. The raw disk image under `~/Library/Containers/com.docker.docker` is claimed so
/// it can never be deleted directly.
public struct DockerInspector: Inspector {
    public let id = "docker"
    public let displayName = "Docker"
    public let bundleIDs: [String] = ["com.docker.docker"]
    public let claimedPatterns: [String] = ["~/Library/Containers/com.docker.docker"]
    public let category: StorageCategory? = .developerTools

    public init() {}

    private struct Kind {
        let dfType: String
        let key: String
        let title: String
        let whatYouLose: String
        let risk: RiskLevel
        let actionTitle: String
        let pruneArguments: [String]
    }

    private static let kinds: [Kind] = [
        Kind(dfType: "Images", key: "images.unused", title: "Unused images",
             whatYouLose: "Images not used by any container; they are pulled or rebuilt when needed again",
             risk: .rebuildable, actionTitle: "Prune images",
             pruneArguments: ["image", "prune", "-a", "-f"]),
        Kind(dfType: "Containers", key: "containers.stopped", title: "Stopped containers",
             whatYouLose: "Files changed inside stopped containers",
             risk: .rebuildable, actionTitle: "Prune containers",
             pruneArguments: ["container", "prune", "-f"]),
        Kind(dfType: "Local Volumes", key: "volumes.unused", title: "Unused volumes",
             whatYouLose: "Data in volumes not attached to any container, e.g. local databases",
             risk: .userData, actionTitle: "Prune volumes",
             pruneArguments: ["volume", "prune", "-a", "-f"]),
        Kind(dfType: "Build Cache", key: "buildcache.all", title: "Build cache",
             whatYouLose: "Cached build layers; the next build is slower",
             risk: .cache, actionTitle: "Prune build cache",
             pruneArguments: ["builder", "prune", "-a", "-f"]),
    ]

    private static let requirement = AppStateRequirement.mustBeRunning(
        bundleIDs: ["com.docker.docker"],
        processNames: ["com.docker.backend"],
        reason: "Docker must be running to prune"
    )

    private static let downMessage = "Docker is not running — start Docker Desktop to inspect it"

    public func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        guard let docker = context.tools.locate("docker") else {
            throw InspectorUnavailable("Docker is not installed")
        }
        let output: ToolOutput
        do {
            output = try await context.tools.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: .seconds(30))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw InspectorUnavailable("Couldn't query Docker: \(error)")
        }
        if output.exitCode != 0 || output.stderr.contains("Cannot connect") {
            throw InspectorUnavailable(Self.downMessage)
        }

        // nil bytes = Docker reported a negative or unparseable size.
        var reclaimable: [String: (bytes: Int64?, hasObjects: Bool)] = [:]
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["Type"] as? String,
                  let text = object["Reclaimable"] as? String else { continue }
            let total = Int(object["TotalCount"] as? String ?? "") ?? 0
            let active = Int(object["Active"] as? String ?? "") ?? 0
            reclaimable[type] = (Self.parseBytes(text), total > active)
        }

        return Self.kinds.compactMap { kind in
            guard let entry = reclaimable[kind.dfType] else { return nil }
            let unknown = entry.bytes == nil
            if unknown { guard entry.hasObjects else { return nil } } else if entry.bytes! <= 0 { return nil }
            let bytes = entry.bytes ?? 0
            return InspectorItem(
                id: "\(id).\(kind.key)",
                inspectorID: id,
                title: kind.title,
                subtitle: unknown ? "Reclaimable size unknown (Docker reported an invalid value)" : nil,
                whatYouLose: kind.whatYouLose,
                allocatedBytes: bytes,
                risk: kind.risk,
                lastUsed: nil,
                paths: [],
                requirement: Self.requirement,
                actionTitle: kind.actionTitle
            )
        }
    }

    /// One `docker ... prune -f` step per item, run through the docker CLI. Estimates are Docker's
    /// own `Reclaimable` figures. Pruning frees space inside Docker Desktop's disk image; when the
    /// image file under `~/Library/Containers/com.docker.docker` shrinks on disk is up to Docker
    /// Desktop, so free space in macOS may grow later than the prune finishes.
    public func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        guard let docker = context.tools.locate("docker") else {
            throw InspectorUnavailable("Docker is not installed")
        }
        let steps = items.compactMap { item -> CleanupStep? in
            guard let kind = Self.kinds.first(where: { "\(id).\($0.key)" == item.id }) else { return nil }
            return CleanupStep(
                title: item.actionTitle,
                risk: item.risk,
                estimatedBytes: item.allocatedBytes,
                requirement: item.requirement,
                action: .runTool(executable: docker, arguments: kind.pruneArguments)
            )
        }
        return CleanupPlan(steps: steps)
    }

    /// Parses the `Reclaimable` column, e.g. "12.3GB (45%)" or "39.97MB". Docker uses decimal
    /// (1000-based) units. Negative, scientific-negative or otherwise unparseable values
    /// (Docker can report e.g. "-6.732e+10B (-362%)") return nil.
    static func parseBytes(_ text: String) -> Int64? {
        let head = text.split(separator: " ").first.map(String.init) ?? text
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where head.hasSuffix(suffix) {
            guard let value = Double(head.dropLast(suffix.count)), value.isFinite, value >= 0 else { return nil }
            return Int64(min(value * factor, Double(Int64.max / 2)))
        }
        return nil
    }
}
