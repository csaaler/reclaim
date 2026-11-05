import Foundation

/// One model Ollama has pulled, read from its manifest.
struct OllamaModel: Sendable {
    /// The name `ollama list` shows and `ollama rm` takes, e.g. `llama3.2:3b`.
    let name: String
    /// The sum of the manifest's layer and config sizes. Layers shared with other models are
    /// counted for each of them.
    let bytes: Int64
    let modified: Date?
}

/// Reads `~/.ollama/models/manifests/<host>/<namespace>/<model>/<tag>`. Blobs are never touched;
/// Ollama itself removes them (`ollama rm`).
enum OllamaManifests {
    static let defaultHost = "registry.ollama.ai"
    static let defaultNamespace = "library"
    /// Real manifests are about 1 KB.
    static let maxManifestBytes: Int64 = 1 << 20
    static let maxManifests = 10_000

    private struct Manifest: Decodable {
        struct Layer: Decodable {
            let digest: String
            let size: Int64
        }

        let config: Layer
        let layers: [Layer]
    }

    /// Every readable manifest under `modelsRoot`, sorted by name. Malformed, oversized or
    /// symlinked manifests are skipped.
    static func models(modelsRoot: String) -> [OllamaModel] {
        let root = modelsRoot + "/manifests"
        var models: [OllamaModel] = []
        for host in AIModelsFiles.entries(root, kind: .directory) {
            for namespace in AIModelsFiles.entries("\(root)/\(host)", kind: .directory) {
                for model in AIModelsFiles.entries("\(root)/\(host)/\(namespace)", kind: .directory) {
                    let folder = "\(root)/\(host)/\(namespace)/\(model)"
                    for tag in AIModelsFiles.entries(folder, kind: .regularFile) {
                        guard models.count < maxManifests else { return models.sorted { $0.name < $1.name } }
                        let path = folder + "/" + tag
                        guard let bytes = totalBytes(manifestAt: path) else { continue }
                        models.append(OllamaModel(
                            name: displayName(host: host, namespace: namespace, model: model, tag: tag),
                            bytes: bytes, modified: AIModelsFiles.modified(path)))
                    }
                }
            }
        }
        return models.sorted { $0.name < $1.name }
    }

    /// `model:tag` for the default registry and namespace, `namespace/model:tag` for another
    /// namespace on the default registry, `host/namespace/model:tag` for another registry.
    static func displayName(host: String, namespace: String, model: String, tag: String) -> String {
        if host == defaultHost {
            return namespace == defaultNamespace ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
        }
        return "\(host)/\(namespace)/\(model):\(tag)"
    }

    /// Nil when the file is too large, unreadable or not a manifest with a valid config and at
    /// least one valid layer.
    static func totalBytes(manifestAt path: String) -> Int64? {
        guard let size = AIModelsFiles.size(path), size <= maxManifestBytes,
              let data = FileManager.default.contents(atPath: path), data.count <= maxManifestBytes,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              !manifest.layers.isEmpty
        else { return nil }
        var total: Int64 = 0
        for layer in [manifest.config] + manifest.layers {
            guard isDigest(layer.digest), layer.size >= 0 else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(layer.size)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    private static let hexDigits = Set("0123456789abcdef")

    /// `sha256:` and 64 lowercase hex digits.
    static func isDigest(_ value: String) -> Bool {
        let prefix = "sha256:"
        guard value.hasPrefix(prefix) else { return false }
        let hex = value.dropFirst(prefix.count)
        return hex.count == 64 && hex.allSatisfy(hexDigits.contains)
    }
}
