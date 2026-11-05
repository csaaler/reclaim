import Foundation
import StorageCore

/// One repo folder in the Hugging Face hub cache, such as `models--example-org--example-model`.
struct HuggingFaceRepo: Sendable {
    /// The id `hf cache rm` takes: `model/<org>/<name>`, `dataset/<name>`, ...
    let repoID: String
    let isDataset: Bool
    let path: String
}

/// What the symlinks inside one repo folder point to.
struct HuggingFaceRepoLinks: Sendable {
    /// At least one symlink resolves into the hub's shared store (`hub/blobs`). Deleting the
    /// folder directly would leave those files behind and the store's references stale, so only
    /// `hf cache rm` may remove such a repo.
    var usesSharedStore = false
    /// Symlink-resolved regular files in the shared store, each once.
    var sharedFiles: Set<String> = []
    /// False when the walk stopped at a limit; the links are then not fully known.
    var complete = true
}

/// Reads `~/.cache/huggingface/hub`. Repo folders hold `blobs/`, `refs/` and `snapshots/`, and
/// snapshot files are symlinks into `blobs/`. Newer clients keep Xet files once in a shared
/// store at `hub/blobs/`, and a repo's own `blobs/<etag>` is then a symlink into it.
enum HuggingFaceCache {
    static let maxWalkEntries = 200_000
    static let maxWalkDepth = 8

    /// Repo folders the cache layout explains, sorted. The shared store, lock folders, spaces
    /// and anything with an unexpected name are left out.
    static func repos(hub: String) -> [HuggingFaceRepo] {
        AIModelsFiles.entries(hub, kind: .directory).compactMap { folder in
            repoID(folderName: folder).map {
                HuggingFaceRepo(repoID: $0.id, isDataset: $0.isDataset, path: hub + "/" + folder)
            }
        }
    }

    /// `models--org--name` is `model/org/name`, `datasets--name` is `dataset/name`. Hugging Face
    /// forbids `--` inside names, so splitting on it is unambiguous. Nil for anything else.
    static func repoID(folderName: String) -> (id: String, isDataset: Bool)? {
        let parts = folderName.components(separatedBy: "--")
        guard (2...3).contains(parts.count), !parts.contains(where: \.isEmpty) else { return nil }
        let type: String
        switch parts[0] {
        case "models": type = "model"
        case "datasets": type = "dataset"
        default: return nil
        }
        return (([type] + parts.dropFirst()).joined(separator: "/"), type == "dataset")
    }

    /// Walks `repo` without following symlinks and resolves each symlink's target lexically,
    /// relative to the link's folder. A target inside `hub/blobs` counts as shared. Its size is
    /// counted only if its symlink-resolved path is a regular file that is still inside the
    /// resolved shared store, and that store is inside `home`.
    static func links(of repo: String, hub: String, home: String) -> HuggingFaceRepoLinks {
        var result = HuggingFaceRepoLinks()
        let store = PathKey(hub + "/blobs")
        let resolvedStore = AIModelsFiles.resolved(hub + "/blobs").flatMap { storePath -> PathKey? in
            guard let resolvedHome = AIModelsFiles.resolved(home),
                  PathKey(storePath).isInside(PathKey(resolvedHome)) else { return nil }
            return PathKey(storePath)
        }

        var visited = 0
        var pending: [(path: String, depth: Int)] = [(repo, 0)]
        while let (folder, depth) = pending.popLast() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names {
                visited += 1
                guard visited <= maxWalkEntries else {
                    result.complete = false
                    return result
                }
                let path = folder + "/" + name
                switch AIModelsFiles.kind(path) {
                case .directory:
                    if depth + 1 < maxWalkDepth { pending.append((path, depth + 1)) } else { result.complete = false }
                case .symlink:
                    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
                        continue
                    }
                    let target = PathKey(destination.hasPrefix("/") ? destination : folder + "/" + destination)
                    guard target.isInside(store) else { continue }
                    result.usesSharedStore = true
                    if let resolvedStore, let real = AIModelsFiles.resolved(target.raw),
                       PathKey(real).isInside(resolvedStore), AIModelsFiles.kind(real) == .regularFile {
                        result.sharedFiles.insert(real)
                    }
                default:
                    continue
                }
            }
        }
        return result
    }
}
