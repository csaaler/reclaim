import Foundation
import StorageCore

/// Downloaded local AI models: Ollama, LM Studio and the Hugging Face hub cache. One item per
/// model, all 🟡: each can be downloaded again.
///
/// - Ollama models are removed with `ollama rm`, which needs the Ollama server running. Reclaim
///   never deletes Ollama's blobs itself, because models share them.
/// - LM Studio model folders are deleted while LM Studio is quit.
/// - Hugging Face repos are removed with `hf cache rm`. Without `hf`, a repo folder is deleted
///   directly only when none of its files live in the hub's shared store.
///
/// Only the default locations are read. `OLLAMA_MODELS`, `HF_HOME`, `HF_HUB_CACHE` and a changed
/// LM Studio models folder are not supported.
public struct AIModelsInspector: Inspector {
    public let id = "ai-models"
    public let displayName = "AI Models"
    public let bundleIDs: [String] = []
    public let claimedPatterns: [String] = [
        "~/.ollama/models",
        "~/.lmstudio/models",
        "~/.cache/huggingface/hub",
    ]
    public let category: StorageCategory? = .developerTools
    /// The Ollama app ships its CLI here and only offers to link it into `/usr/local/bin`.
    public let toolSearchDirectories = ["/Applications/Ollama.app/Contents/Resources"]

    public init() {}

    static let ollamaRequirement = AppStateRequirement.mustBeRunning(
        bundleIDs: [], processNames: ["ollama"],
        reason: "Ollama must be running to remove a model (open the Ollama app or run ollama serve)")
    static let lmStudioRequirement = AppStateRequirement.mustBeQuit(
        bundleIDs: ["ai.elementlabs.lmstudio"], processNames: ["LM Studio"])
    static let hfMissing = "Install the hf command (pip install -U huggingface_hub) to remove models that share files"

    private func ollamaRoot(_ context: InspectorContext) -> String { context.home.path + "/.ollama/models" }
    private func lmStudioRoot(_ context: InspectorContext) -> String { context.home.path + "/.lmstudio/models" }
    private func hubRoot(_ context: InspectorContext) -> String { context.home.path + "/.cache/huggingface/hub" }

    // MARK: Discover

    public func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        var items = ollamaItems(context)
        items += await lmStudioItems(context)
        items += await huggingFaceItems(context)
        return items
    }

    private func ollamaItems(_ context: InspectorContext) -> [InspectorItem] {
        let ollama = context.tools.locate("ollama")
        return OllamaManifests.models(modelsRoot: ollamaRoot(context)).map { model in
            let allowed = ollama.map { Self.allowed("ollama", $0, ["rm", model.name], context) } ?? false
            let reason = ollama == nil
                ? "ollama not found; install Ollama to remove models"
                : "This model name cannot be passed to ollama safely"
            return InspectorItem(
                id: "\(id).ollama.\(model.name)", inspectorID: id, title: model.name,
                subtitle: allowed ? "Ollama · size includes layers shared with other models" : reason,
                whatYouLose: "This Ollama model (\(Self.format(model.bytes)) including layers it may share with other models). " +
                    "ollama pull downloads it again; a model you built with ollama create can only be rebuilt from its Modelfile. " +
                    "Layers other models still use are kept, so less space may be freed.",
                allocatedBytes: model.bytes, risk: .rebuildable, lastUsed: model.modified, paths: [],
                requirement: Self.ollamaRequirement, actionTitle: "Remove model", isActionable: allowed)
        }
    }

    private func lmStudioItems(_ context: InspectorContext) async -> [InspectorItem] {
        let root = lmStudioRoot(context)
        var items: [InspectorItem] = []
        for publisher in AIModelsFiles.entries(root, kind: .directory) {
            for model in AIModelsFiles.entries(root + "/" + publisher, kind: .directory) {
                let path = "\(root)/\(publisher)/\(model)"
                let bytes = await context.sizer.allocatedSize(of: path)
                items.append(InspectorItem(
                    id: "\(id).lmstudio.\(publisher)/\(model)", inspectorID: id, title: "\(publisher)/\(model)",
                    subtitle: "LM Studio",
                    whatYouLose: "The model files in this folder (\(Self.format(bytes))). LM Studio downloads them again; " +
                        "a model you imported yourself (lms import) is gone for good. Chats and settings are kept.",
                    allocatedBytes: bytes, risk: .rebuildable, lastUsed: AIModelsFiles.modified(path), paths: [path],
                    requirement: Self.lmStudioRequirement, actionTitle: "Delete model"))
            }
        }
        return items
    }

    private func huggingFaceItems(_ context: InspectorContext) async -> [InspectorItem] {
        let hub = hubRoot(context)
        let hf = context.tools.locate("hf")
        var items: [InspectorItem] = []
        for repo in HuggingFaceCache.repos(hub: hub) {
            let links = HuggingFaceCache.links(of: repo.path, hub: hub, home: context.home.path)
            var bytes = await context.sizer.allocatedSize(of: repo.path)
            for file in links.sharedFiles.sorted() { bytes += await context.sizer.allocatedSize(of: file) }
            let byTool = hf.map { Self.allowed("hf", $0, Self.hfArguments(repo.repoID), context) } ?? false
            let byDelete = links.complete && !links.usesSharedStore
            let kind = repo.isDataset ? "dataset" : "model"
            var subtitle = "Hugging Face \(kind)"
            if !links.sharedFiles.isEmpty {
                subtitle += " · includes \(links.sharedFiles.count) shared file(s) that other repos may also use"
            }
            items.append(InspectorItem(
                id: "\(id).huggingface.\(repo.repoID)", inspectorID: id,
                title: String(repo.repoID.dropFirst(kind.count + 1)),
                subtitle: byTool || byDelete ? subtitle : Self.hfMissing,
                whatYouLose: "Every cached revision of this \(kind) (\(Self.format(bytes))). Programs that use it download it again " +
                    "from Hugging Face. Shared files other repos still use are kept, so less space may be freed.",
                allocatedBytes: bytes, risk: .rebuildable, lastUsed: AIModelsFiles.modified(repo.path), paths: [repo.path],
                requirement: AppStateRequirement.none,
                actionTitle: "Remove from cache", isActionable: byTool || byDelete))
        }
        return items
    }

    // MARK: Plan

    public func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        var steps: [CleanupStep] = []
        func step(_ item: InspectorItem, _ action: CleanupAction) -> CleanupStep {
            CleanupStep(title: "\(item.actionTitle): \(item.title)", risk: item.risk, estimatedBytes: item.allocatedBytes,
                        requirement: item.requirement, action: action)
        }

        for item in items where item.inspectorID == id && item.isActionable {
            let key = item.id.dropFirst(id.count + 1)
            if key.hasPrefix("ollama.") {
                let name = String(key.dropFirst("ollama.".count))
                guard let ollama = context.tools.locate("ollama") else { throw InspectorUnavailable("ollama is not installed") }
                guard Self.allowed("ollama", ollama, ["rm", name], context) else { continue }
                steps.append(step(item, .runTool(executable: ollama, arguments: ["rm", name])))
            } else if key.hasPrefix("lmstudio.") {
                guard let path = item.paths.first, item.paths.count == 1,
                      Self.isChild(path, of: lmStudioRoot(context), depth: 2) else { continue }
                steps.append(step(item, .delete(path: path, expectedFileID: nil)))
            } else if key.hasPrefix("huggingface.") {
                let repoID = String(key.dropFirst("huggingface.".count))
                let hub = hubRoot(context)
                guard let path = item.paths.first, item.paths.count == 1, Self.isChild(path, of: hub, depth: 1),
                      HuggingFaceCache.repoID(folderName: URL(fileURLWithPath: path).lastPathComponent)?.id == repoID
                else { continue }
                if let hf = context.tools.locate("hf"), Self.allowed("hf", hf, Self.hfArguments(repoID), context) {
                    steps.append(step(item, .runTool(executable: hf, arguments: Self.hfArguments(repoID))))
                } else {
                    let links = HuggingFaceCache.links(of: path, hub: hub, home: context.home.path)
                    guard links.complete && !links.usesSharedStore else { throw InspectorUnavailable(Self.hfMissing) }
                    steps.append(step(item, .delete(path: path, expectedFileID: nil)))
                }
            }
        }
        return CleanupPlan(steps: steps)
    }

    // MARK: Helpers

    static func hfArguments(_ repoID: String) -> [String] { ["cache", "rm", repoID, "--yes"] }

    /// Whether the engine's `ToolPolicy` would run this exact command, so an item is offered only
    /// when its step will not be refused.
    private static func allowed(_ tool: String, _ executable: String, _ arguments: [String], _ context: InspectorContext) -> Bool {
        ToolPolicy(home: context.home).violation(
            for: .runTool(executable: executable, arguments: arguments),
            locate: { $0 == tool ? executable : nil }) == nil
    }

    /// `path` is exactly `depth` plain segments below `root`.
    private static func isChild(_ path: String, of root: String, depth: Int) -> Bool {
        let key = PathKey(path)
        guard key.raw == path, key.isInside(PathKey(root)) else { return false }
        return path.split(separator: "/").count == root.split(separator: "/").count + depth
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
