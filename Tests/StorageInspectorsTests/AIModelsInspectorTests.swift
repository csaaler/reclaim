import Foundation
import Testing
import StorageCore
import StorageInspectors
import StorageTestKit

@Suite struct AIModelsInspectorTests {
    static let ollama = "/usr/local/bin/ollama"
    static let hf = "/opt/homebrew/bin/hf"
    static let manifests = ".ollama/models/manifests"
    static let lmstudio = ".lmstudio/models"
    static let hub = ".cache/huggingface/hub"

    let inspector = AIModelsInspector()

    func context(_ fixture: FixtureHome, tools: [String: String] = [:]) -> InspectorContext {
        InspectorContext(home: fixture.home, tools: FakeToolRunner(tools: tools), sizer: LogicalSizer())
    }

    static func digest(_ seed: Character) -> String { "sha256:" + String(repeating: seed, count: 64) }

    static func manifest(config: Int = 500, layers: [Int]) -> [String: Any] {
        [
            "schemaVersion": 2,
            "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
            "config": ["mediaType": "application/vnd.docker.container.image.v1+json", "digest": digest("c"), "size": config],
            "layers": layers.enumerated().map { index, size in
                ["mediaType": "application/vnd.ollama.image.model", "digest": digest(Array("0123456789")[index % 10]), "size": size]
            },
        ]
    }

    /// Real `PathValidator` and `ToolPolicy` on the fixture home; nothing is executed, only preflight.
    func engine(_ fixture: FixtureHome, tools: [String: String], running: Set<String> = []) -> CleanupEngine {
        CleanupEngine(
            validator: PathValidator(home: fixture.home),
            tools: FakeToolRunner(tools: tools),
            apps: FakeAppChecker(running: running),
            files: NoFileOperations(),
            sizer: LogicalSizer(),
            log: CleanupLog(fileURL: fixture.home.appendingPathComponent("log/cleanup-log.jsonl")),
            policy: ToolPolicy(home: fixture.home),
            freeSpace: { 0 })
    }

    // MARK: - Empty

    @Test func emptyHomeFindsNothing() async throws {
        let fixture = try FixtureHome()
        #expect(try await inspector.discover(in: context(fixture, tools: ["ollama": Self.ollama, "hf": Self.hf])).isEmpty)
        #expect(try await inspector.plan(for: [], in: context(fixture)).steps.isEmpty)
    }

    @Test func emptyToolFoldersFindNothing() async throws {
        let fixture = try FixtureHome()
        try fixture.dir(Self.manifests)
        try fixture.dir(".ollama/models/blobs")
        try fixture.dir(Self.lmstudio)
        try fixture.file("\(Self.hub)/CACHEDIR.TAG", bytes: 40)
        try fixture.file("\(Self.hub)/version.txt", bytes: 1)
        try fixture.dir("\(Self.hub)/.locks/models--example-org--example-model")
        try fixture.file("\(Self.hub)/blobs/ab/\(String(repeating: "a", count: 64))", bytes: 100)
        #expect(try await inspector.discover(in: context(fixture, tools: ["ollama": Self.ollama, "hf": Self.hf])).isEmpty)
    }

    @Test func registeredAsDeveloperTool() throws {
        let registered = try #require(allInspectors.first { $0.id == "ai-models" })
        #expect(registered.displayName == "AI Models")
        #expect(registered.category == .developerTools)
        #expect(allInspectors.last?.id == "ai-models")
    }

    // MARK: - Ollama

    func ollamaFixture() throws -> FixtureHome {
        let fixture = try FixtureHome()
        try fixture.json("\(Self.manifests)/registry.ollama.ai/library/llama3.2/3b", Self.manifest(layers: [2_000_000, 1_000]))
        try fixture.json("\(Self.manifests)/registry.ollama.ai/example-user/tiny-model/latest", Self.manifest(config: 10, layers: [90]))
        try fixture.json("\(Self.manifests)/hf.co/example-org/Example-Model-GGUF/Q4_K_M", Self.manifest(config: 0, layers: [7_000]))
        return fixture
    }

    @Test func ollamaModelsAreNamedAndSizedFromTheirManifests() async throws {
        let fixture = try ollamaFixture()
        let items = try await inspector.discover(in: context(fixture, tools: ["ollama": Self.ollama]))
        #expect(items.map(\.title) == ["example-user/tiny-model:latest", "hf.co/example-org/Example-Model-GGUF:Q4_K_M", "llama3.2:3b"])
        #expect(items.map(\.id) == items.map { "ai-models.ollama." + $0.title })
        #expect(items.map(\.allocatedBytes) == [100, 7_000, 2_001_500])
        #expect(items.allSatisfy { $0.risk == .rebuildable && $0.paths.isEmpty && $0.isActionable })
        #expect(items.allSatisfy { $0.requirement == .mustBeRunning(
            bundleIDs: [], processNames: ["ollama"],
            reason: "Ollama must be running to remove a model (open the Ollama app or run ollama serve)") })
        #expect(items.allSatisfy { $0.subtitle?.contains("shared") == true })
        #expect(items.allSatisfy { $0.whatYouLose.contains("ollama pull") && $0.lastUsed != nil })
    }

    @Test func ollamaPlanRunsOllamaRmWithTheModelName() async throws {
        let fixture = try ollamaFixture()
        let ctx = context(fixture, tools: ["ollama": Self.ollama])
        let items = try await inspector.discover(in: ctx)
        let plan = try await inspector.plan(for: items, in: ctx)
        #expect(plan.steps.map(\.action) == [
            .runTool(executable: Self.ollama, arguments: ["rm", "example-user/tiny-model:latest"]),
            .runTool(executable: Self.ollama, arguments: ["rm", "hf.co/example-org/Example-Model-GGUF:Q4_K_M"]),
            .runTool(executable: Self.ollama, arguments: ["rm", "llama3.2:3b"]),
        ])
        #expect(plan.steps.map(\.estimatedBytes) == items.map(\.allocatedBytes))
        #expect(plan.steps.allSatisfy { $0.risk == .rebuildable && $0.requirement == AIModelsInspectorTests.ollamaRunning })
    }

    static let ollamaRunning = AppStateRequirement.mustBeRunning(
        bundleIDs: [], processNames: ["ollama"],
        reason: "Ollama must be running to remove a model (open the Ollama app or run ollama serve)")

    /// The engine refuses nothing the inspector plans, and blocks it until the server runs.
    @Test func ollamaStepsPassThePolicyAndNeedTheServerRunning() async throws {
        let fixture = try ollamaFixture()
        let tools = ["ollama": Self.ollama]
        let ctx = context(fixture, tools: tools)
        let plan = try await inspector.plan(for: try await inspector.discover(in: ctx), in: ctx)
        #expect(plan.steps.count == 3)

        let stopped = await engine(fixture, tools: tools).preflight(plan, acknowledged: [])
        #expect(stopped.count == 3)
        #expect(stopped.values.allSatisfy { $0 == [.appNotRunning(
            reason: "Ollama must be running to remove a model (open the Ollama app or run ollama serve)")] })

        let running = await engine(fixture, tools: tools, running: ["ollama"]).preflight(plan, acknowledged: [])
        #expect(running.isEmpty)
    }

    @Test func ollamaModelsAreViewOnlyWithoutTheTool() async throws {
        let fixture = try ollamaFixture()
        let ctx = context(fixture)
        let items = try await inspector.discover(in: ctx)
        #expect(items.count == 3)
        #expect(items.allSatisfy { !$0.isActionable && $0.subtitle == "ollama not found; install Ollama to remove models" })
        #expect(try await inspector.plan(for: items, in: ctx).steps.isEmpty)
    }

    @Test func ollamaPlanWithoutTheToolIsUnavailable() async throws {
        let fixture = try ollamaFixture()
        let items = try await inspector.discover(in: context(fixture, tools: ["ollama": Self.ollama]))
        await #expect(throws: InspectorUnavailable.self) {
            try await inspector.plan(for: items, in: context(fixture))
        }
    }

    @Test func ollamaSearchesTheAppBundle() {
        #expect(inspector.toolSearchDirectories == ["/Applications/Ollama.app/Contents/Resources"])
    }

    @Test func malformedOllamaManifestsAreSkipped() async throws {
        let fixture = try FixtureHome()
        let base = "\(Self.manifests)/registry.ollama.ai/library"
        try fixture.json("\(base)/good/1b", Self.manifest(layers: [100]))
        try fixture.file("\(base)/garbage/1b", bytes: 10)
        try fixture.json("\(base)/array/1b", [1, 2, 3])
        try fixture.json("\(base)/no-config/1b", ["layers": [["digest": Self.digest("a"), "size": 1]]])
        try fixture.json("\(base)/no-layers/1b", ["config": ["digest": Self.digest("a"), "size": 1], "layers": []])
        try fixture.json("\(base)/bad-digest/1b", ["config": ["digest": "sha256:xyz", "size": 1], "layers": [["digest": Self.digest("a"), "size": 1]]])
        try fixture.json("\(base)/upper-digest/1b", ["config": ["digest": Self.digest("A"), "size": 1], "layers": [["digest": Self.digest("a"), "size": 1]]])
        try fixture.json("\(base)/negative/1b", ["config": ["digest": Self.digest("a"), "size": -1], "layers": [["digest": Self.digest("a"), "size": 1]]])
        try fixture.json("\(base)/string-size/1b", ["config": ["digest": Self.digest("a"), "size": "1"], "layers": [["digest": Self.digest("a"), "size": 1]]])
        try fixture.json("\(base)/fraction/1b", ["config": ["digest": Self.digest("a"), "size": 1.5], "layers": [["digest": Self.digest("a"), "size": 1]]])
        try fixture.json("\(base)/overflow/1b", ["config": ["digest": Self.digest("a"), "size": Int64.max], "layers": [["digest": Self.digest("a"), "size": 1]]])
        try fixture.file("\(base)/huge/1b", bytes: 2 << 20)
        try fixture.symlink("\(base)/linked/1b", to: fixture.home.path + "/\(base)/good/1b")
        try fixture.symlink("\(base)/linked-model", to: fixture.home.path + "/\(base)/good")
        try fixture.symlink("\(Self.manifests)/linked-host", to: fixture.home.path + "/\(Self.manifests)/registry.ollama.ai")
        try fixture.json("\(base)/.hidden/1b", Self.manifest(layers: [1]))
        try fixture.dir("\(base)/folder-tag/1b")

        let items = try await inspector.discover(in: context(fixture, tools: ["ollama": Self.ollama]))
        #expect(items.map(\.title) == ["good:1b"])
    }

    @Test func ollamaNameThePolicyRefusesIsViewOnly() async throws {
        let fixture = try FixtureHome()
        try fixture.json("\(Self.manifests)/registry.ollama.ai/library/odd model/latest", Self.manifest(layers: [1]))
        try fixture.json("\(Self.manifests)/registry.ollama.ai/-flag/x/latest", Self.manifest(layers: [1]))
        try fixture.json("\(Self.manifests)/registry.ollama.ai/library/semi;colon/latest", Self.manifest(layers: [1]))
        let ctx = context(fixture, tools: ["ollama": Self.ollama])
        let items = try await inspector.discover(in: ctx)
        #expect(items.count == 3)
        #expect(items.allSatisfy { !$0.isActionable && $0.subtitle == "This model name cannot be passed to ollama safely" })
        #expect(try await inspector.plan(for: items, in: ctx).steps.isEmpty)
    }

    // MARK: - LM Studio

    func lmStudioFixture() throws -> FixtureHome {
        let fixture = try FixtureHome()
        try fixture.file("\(Self.lmstudio)/example-community/Example-8B-GGUF/example-8b-Q4_K_M.gguf", bytes: 4096)
        try fixture.file("\(Self.lmstudio)/example-community/Example-8B-GGUF/example-8b-Q8_0.gguf", bytes: 1024)
        try fixture.file("\(Self.lmstudio)/mlx-example/Tiny-4bit/model.safetensors", bytes: 2048)
        try fixture.file("\(Self.lmstudio)/mlx-example/Tiny-4bit/config.json", bytes: 100)
        return fixture
    }

    @Test func lmStudioModelFoldersAreItems() async throws {
        let fixture = try lmStudioFixture()
        let ctx = context(fixture)
        let items = try await inspector.discover(in: ctx)
        let root = fixture.home.path + "/" + Self.lmstudio
        #expect(items.map(\.id) == ["ai-models.lmstudio.example-community/Example-8B-GGUF", "ai-models.lmstudio.mlx-example/Tiny-4bit"])
        #expect(items.map(\.paths) == [[root + "/example-community/Example-8B-GGUF"], [root + "/mlx-example/Tiny-4bit"]])
        #expect(items.map(\.allocatedBytes) == [5120, 2148])
        #expect(items.allSatisfy { $0.risk == .rebuildable && $0.isActionable })
        #expect(items.allSatisfy { $0.requirement == .mustBeQuit(bundleIDs: ["ai.elementlabs.lmstudio"], processNames: ["LM Studio"]) })
        #expect(items.allSatisfy { $0.whatYouLose.contains("lms import") })

        let plan = try await inspector.plan(for: items, in: ctx)
        #expect(plan.steps.map(\.action) == items.map { .delete(path: $0.paths[0], expectedFileID: nil) })
        #expect(plan.steps.map(\.estimatedBytes) == [5120, 2148])
    }

    @Test(arguments: [["LM Studio"], ["ai.elementlabs.lmstudio"]])
    func lmStudioMustBeQuitFirst(_ running: Set<String>) async throws {
        let fixture = try lmStudioFixture()
        let ctx = context(fixture)
        let plan = try await inspector.plan(for: try await inspector.discover(in: ctx), in: ctx)
        let blocked = await engine(fixture, tools: [:], running: running).preflight(plan, acknowledged: [])
        #expect(blocked.count == 2)
        #expect(blocked.values.allSatisfy { $0 == [.appRunning(name: "LM Studio", bundleIDs: ["ai.elementlabs.lmstudio"])] })
        #expect(await engine(fixture, tools: [:]).preflight(plan, acknowledged: []).isEmpty)
    }

    @Test func lmStudioIgnoresSymlinksFilesAndHiddenFolders() async throws {
        let fixture = try FixtureHome()
        try fixture.file("Elsewhere/model/weights.gguf", bytes: 100)
        try fixture.symlink("\(Self.lmstudio)/linked-publisher", to: fixture.home.path + "/Elsewhere")
        try fixture.symlink("\(Self.lmstudio)/example-community/linked-model", to: fixture.home.path + "/Elsewhere/model")
        try fixture.file("\(Self.lmstudio)/example-community/stray.gguf", bytes: 100)
        try fixture.file("\(Self.lmstudio)/stray.json", bytes: 100)
        try fixture.dir("\(Self.lmstudio)/.internal/model")
        try fixture.dir("\(Self.lmstudio)/example-community/.partial")
        #expect(try await inspector.discover(in: context(fixture)).isEmpty)
    }

    @Test func lmStudioPlanOnlyDeletesModelFolders() async throws {
        let fixture = try lmStudioFixture()
        let ctx = context(fixture)
        let item = try #require(try await inspector.discover(in: ctx).first)
        let root = fixture.home.path + "/" + Self.lmstudio
        for path in [root, root + "/example-community", root + "/example-community/Example-8B-GGUF/x.gguf",
                     root + "/example-community/../mlx-example", fixture.home.path + "/Documents/x/y"] {
            let forged = InspectorItem(
                id: item.id, inspectorID: item.inspectorID, title: item.title, whatYouLose: item.whatYouLose,
                allocatedBytes: 1, risk: item.risk, lastUsed: nil, paths: [path], requirement: item.requirement,
                actionTitle: item.actionTitle)
            #expect(try await inspector.plan(for: [forged], in: ctx).steps.isEmpty, "\(path)")
        }
    }

    @Test func manyLMStudioModelsAreListed() async throws {
        let fixture = try FixtureHome()
        for index in 0..<300 { try fixture.file("\(Self.lmstudio)/bulk/model-\(index)/w.gguf", bytes: 1) }
        try fixture.file("\(Self.lmstudio)/bulk/with\nnewline/w.gguf", bytes: 1)
        let items = try await inspector.discover(in: context(fixture))
        #expect(items.count == 301)
    }

    // MARK: - Hugging Face

    /// The classic layout: blobs live in the repo, snapshot files link to them.
    func classicRepo(_ fixture: FixtureHome, _ folder: String, blobBytes: [Int] = [3000, 200]) throws {
        let repo = "\(Self.hub)/\(folder)"
        try fixture.file("\(repo)/refs/main", bytes: 40)
        for (index, bytes) in blobBytes.enumerated() {
            try fixture.file("\(repo)/blobs/etag\(index)", bytes: bytes)
            try fixture.symlink("\(repo)/snapshots/rev1/file\(index)", to: "../../blobs/etag\(index)")
        }
    }

    /// The shared-store layout: the repo's blobs are links into `hub/blobs`.
    func sharedRepo(_ fixture: FixtureHome, _ folder: String, shared: [(name: String, bytes: Int)]) throws {
        let repo = "\(Self.hub)/\(folder)"
        try fixture.file("\(repo)/refs/main", bytes: 40)
        for (index, file) in shared.enumerated() {
            let store = "\(Self.hub)/blobs/\(file.name.prefix(2))/\(file.name)"
            if !FileManager.default.fileExists(atPath: fixture.home.path + "/" + store) {
                try fixture.file(store, bytes: file.bytes)
            }
            try fixture.symlink("\(repo)/blobs/etag\(index)", to: "../../blobs/\(file.name.prefix(2))/\(file.name)")
            try fixture.symlink("\(repo)/snapshots/rev1/file\(index)", to: "../../blobs/etag\(index)")
        }
    }

    @Test func huggingFaceRepoFoldersBecomeRepoIDs() async throws {
        let fixture = try FixtureHome()
        try classicRepo(fixture, "models--example-org--example-model")
        try classicRepo(fixture, "models--bert-example")
        try classicRepo(fixture, "datasets--example-org--Example_Data.v2")
        try classicRepo(fixture, "datasets--glue-example")
        try classicRepo(fixture, "spaces--example-org--demo")
        try classicRepo(fixture, "models--a--b--c")
        try classicRepo(fixture, "models----x")
        try classicRepo(fixture, "unknown")
        try fixture.file("\(Self.hub)/models--file-not-folder", bytes: 10)
        try fixture.symlink("\(Self.hub)/models--linked--repo", to: fixture.home.path + "/\(Self.hub)/models--bert-example")

        let items = try await inspector.discover(in: context(fixture, tools: ["hf": Self.hf]))
        #expect(items.map(\.id) == [
            "ai-models.huggingface.dataset/example-org/Example_Data.v2",
            "ai-models.huggingface.dataset/glue-example",
            "ai-models.huggingface.model/bert-example",
            "ai-models.huggingface.model/example-org/example-model",
        ])
        #expect(items.map(\.title) == ["example-org/Example_Data.v2", "glue-example", "bert-example", "example-org/example-model"])
        #expect(items.map(\.subtitle) == ["Hugging Face dataset", "Hugging Face dataset", "Hugging Face model", "Hugging Face model"])
        // Own blobs and refs; the snapshot links themselves count as nothing.
        #expect(items.allSatisfy { $0.allocatedBytes == 3240 && $0.risk == .rebuildable && $0.requirement == .none })
    }

    @Test func classicRepoWithHFRunsHfCacheRm() async throws {
        let fixture = try FixtureHome()
        try classicRepo(fixture, "models--example-org--example-model")
        try classicRepo(fixture, "datasets--glue-example")
        let ctx = context(fixture, tools: ["hf": Self.hf])
        let items = try await inspector.discover(in: ctx)
        #expect(items.allSatisfy { $0.isActionable })
        let plan = try await inspector.plan(for: items, in: ctx)
        #expect(plan.steps.map(\.action) == [
            .runTool(executable: Self.hf, arguments: ["cache", "rm", "dataset/glue-example", "--yes"]),
            .runTool(executable: Self.hf, arguments: ["cache", "rm", "model/example-org/example-model", "--yes"]),
        ])
        #expect(await engine(fixture, tools: ["hf": Self.hf]).preflight(plan, acknowledged: []).isEmpty)
    }

    @Test func classicRepoWithoutHFIsDeleted() async throws {
        let fixture = try FixtureHome()
        try classicRepo(fixture, "models--example-org--example-model")
        let ctx = context(fixture)
        let items = try await inspector.discover(in: ctx)
        let item = try #require(items.first)
        #expect(item.isActionable && item.subtitle == "Hugging Face model")
        let plan = try await inspector.plan(for: items, in: ctx)
        let path = fixture.home.path + "/\(Self.hub)/models--example-org--example-model"
        #expect(plan.steps.map(\.action) == [.delete(path: path, expectedFileID: nil)])
        #expect(await engine(fixture, tools: [:]).preflight(plan, acknowledged: []).isEmpty)
    }

    @Test func sharedStoreFilesAreCountedOncePerRepo() async throws {
        let fixture = try FixtureHome()
        let big = String(repeating: "b", count: 64), small = String(repeating: "5", count: 64)
        try sharedRepo(fixture, "models--example-org--first", shared: [(big, 8000), (small, 100), (big, 8000)])
        try sharedRepo(fixture, "models--example-org--second", shared: [(big, 8000)])
        let items = try await inspector.discover(in: context(fixture, tools: ["hf": Self.hf]))
        #expect(items.map(\.title) == ["example-org/first", "example-org/second"])
        // refs/main plus each shared file once; the links themselves count as nothing.
        #expect(items.map(\.allocatedBytes) == [Int64(8140), Int64(8040)])
        #expect(items[0].subtitle == "Hugging Face model · includes 2 shared file(s) that other repos may also use")
    }

    @Test func sharedStoreRepoWithHFRunsHfCacheRm() async throws {
        let fixture = try FixtureHome()
        try sharedRepo(fixture, "models--example-org--first", shared: [(String(repeating: "b", count: 64), 8000)])
        let ctx = context(fixture, tools: ["hf": Self.hf])
        let items = try await inspector.discover(in: ctx)
        #expect(items.map(\.isActionable) == [true])
        let plan = try await inspector.plan(for: items, in: ctx)
        #expect(plan.steps.map(\.action) == [
            .runTool(executable: Self.hf, arguments: ["cache", "rm", "model/example-org/first", "--yes"]),
        ])
    }

    @Test func sharedStoreRepoWithoutHFIsViewOnly() async throws {
        let fixture = try FixtureHome()
        try sharedRepo(fixture, "models--example-org--first", shared: [(String(repeating: "b", count: 64), 8000)])
        try classicRepo(fixture, "models--example-org--classic")
        let ctx = context(fixture)
        let items = try await inspector.discover(in: ctx)
        let shared = try #require(items.first { $0.title == "example-org/first" })
        #expect(!shared.isActionable)
        #expect(shared.subtitle == "Install the hf command (pip install -U huggingface_hub) to remove models that share files")
        #expect(try await inspector.plan(for: [shared], in: ctx).steps.isEmpty)
        #expect(items.first { $0.title == "example-org/classic" }?.isActionable == true)
    }

    /// A repo discovered while `hf` was installed is never deleted directly once `hf` is gone.
    @Test func sharedStoreRepoPlannedAfterHFDisappearsIsUnavailable() async throws {
        let fixture = try FixtureHome()
        try sharedRepo(fixture, "models--example-org--first", shared: [(String(repeating: "b", count: 64), 8000)])
        let items = try await inspector.discover(in: context(fixture, tools: ["hf": Self.hf]))
        await #expect(throws: InspectorUnavailable.self) {
            try await inspector.plan(for: items, in: context(fixture))
        }
    }

    /// A dangling link into the store still means the repo uses it.
    @Test func danglingSharedLinkStillNeedsHF() async throws {
        let fixture = try FixtureHome()
        let repo = "\(Self.hub)/models--example-org--first"
        try fixture.file("\(repo)/refs/main", bytes: 40)
        try fixture.symlink("\(repo)/blobs/etag0", to: "../../blobs/zz/missing")
        let items = try await inspector.discover(in: context(fixture))
        #expect(items.map(\.isActionable) == [false])
        #expect(items.map(\.allocatedBytes) == [40])
    }

    @Test func linksOutsideTheStoreAreNeitherSizedNorShared() async throws {
        let fixture = try FixtureHome()
        let repo = "\(Self.hub)/models--example-org--first"
        try fixture.file("\(repo)/refs/main", bytes: 40)
        try fixture.file("Documents/secret.bin", bytes: 5000)
        try fixture.file("\(Self.hub)/models--example-org--other/blobs/x", bytes: 6000)
        try fixture.symlink("\(repo)/blobs/up", to: "../../../../../Documents/secret.bin")
        try fixture.symlink("\(repo)/blobs/absolute", to: fixture.home.path + "/Documents/secret.bin")
        try fixture.symlink("\(repo)/blobs/sibling", to: "../../models--example-org--other/blobs/x")
        try fixture.symlink("\(repo)/blobs/escape", to: "../../blobs/../../../../Documents/secret.bin")
        try fixture.symlink("\(repo)/blobs/root", to: "/")
        let items = try await inspector.discover(in: context(fixture))
        let item = try #require(items.first { $0.title == "example-org/first" })
        #expect(item.allocatedBytes == 40)
        #expect(item.isActionable)
    }

    /// A store entry that is itself a link out of the store counts as shared but is not sized.
    @Test func storeEntriesLinkingOutOfTheStoreAreNotSized() async throws {
        let fixture = try FixtureHome()
        let repo = "\(Self.hub)/models--example-org--first"
        try fixture.file("\(repo)/refs/main", bytes: 40)
        try fixture.file("Documents/secret.bin", bytes: 5000)
        try fixture.symlink("\(Self.hub)/blobs/ev/evil", to: fixture.home.path + "/Documents/secret.bin")
        try fixture.symlink("\(repo)/blobs/etag0", to: "../../blobs/ev/evil")
        try fixture.dir("\(Self.hub)/blobs/dd/folder")
        try fixture.symlink("\(repo)/blobs/etag1", to: "../../blobs/dd/folder")
        let items = try await inspector.discover(in: context(fixture))
        #expect(items.map(\.allocatedBytes) == [40])
        #expect(items.map(\.isActionable) == [false])
    }

    /// The whole shared store pointing outside home is never sized.
    @Test func sharedStoreOutsideHomeIsNotSized() async throws {
        let fixture = try FixtureHome()
        let outside = try FixtureHome()
        try outside.file("store/bb/" + String(repeating: "b", count: 64), bytes: 9000)
        try fixture.symlink("\(Self.hub)/blobs", to: outside.home.path + "/store")
        let repo = "\(Self.hub)/models--example-org--first"
        try fixture.file("\(repo)/refs/main", bytes: 40)
        try fixture.symlink("\(repo)/blobs/etag0", to: "../../blobs/bb/" + String(repeating: "b", count: 64))
        let items = try await inspector.discover(in: context(fixture, tools: ["hf": Self.hf]))
        #expect(items.map(\.allocatedBytes) == [40])
        #expect(items.map(\.isActionable) == [true])
    }

    @Test func huggingFacePlanOnlyActsOnTheRepoFolderItNames() async throws {
        let fixture = try FixtureHome()
        try classicRepo(fixture, "models--example-org--first")
        try classicRepo(fixture, "models--example-org--second")
        let ctx = context(fixture)
        let item = try #require(try await inspector.discover(in: ctx).first)
        let hub = fixture.home.path + "/" + Self.hub
        for path in [hub, hub + "/models--example-org--second", hub + "/models--example-org--first/blobs",
                     hub + "/x/../models--example-org--first", fixture.home.path + "/Documents"] {
            let forged = InspectorItem(
                id: item.id, inspectorID: item.inspectorID, title: item.title, whatYouLose: item.whatYouLose,
                allocatedBytes: 1, risk: item.risk, lastUsed: nil, paths: [path], requirement: item.requirement,
                actionTitle: item.actionTitle)
            #expect(try await inspector.plan(for: [forged], in: ctx).steps.isEmpty, "\(path)")
        }
    }

    // MARK: - Everything together

    @Test func allThreeSourcesTogether() async throws {
        let fixture = try ollamaFixture()
        try fixture.file("\(Self.lmstudio)/example-community/Example-8B-GGUF/w.gguf", bytes: 10)
        try classicRepo(fixture, "models--example-org--example-model")
        let ctx = context(fixture, tools: ["ollama": Self.ollama, "hf": Self.hf])
        let items = try await inspector.discover(in: ctx)
        #expect(items.count == 5)
        #expect(Set(items.map(\.id)).count == 5)
        let plan = try await inspector.plan(for: items, in: ctx)
        #expect(plan.steps.count == 5)
        let tools = ["ollama": Self.ollama, "hf": Self.hf]
        let blockers = await engine(fixture, tools: tools, running: ["ollama"]).preflight(plan, acknowledged: [])
        #expect(blockers.isEmpty)
    }
}

/// Preflight never touches files; anything else is a test bug.
private struct NoFileOperations: FileOperating {
    struct Unexpected: Error {}
    func remove(_ path: String) throws { throw Unexpected() }
    func trash(_ path: String) throws -> String { throw Unexpected() }
    func read(_ path: String) throws -> Data { throw Unexpected() }
    func write(_ data: Data, to path: String) throws { throw Unexpected() }
}
