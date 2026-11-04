import Foundation
import StorageCore

/// Finds Gradle, Maven, pip, pyenv, rustup, cargo and Go caches and toolchains.
public struct NativeCachesInspector: Inspector {
    public let id = "native-caches"
    public let displayName = "Gradle, Maven, Python, Rust & Go"
    public let bundleIDs: [String] = []
    public let claimedPatterns: [String] = [
        "~/.gradle/caches",
        "~/.gradle/wrapper/dists/*",
        "~/.m2/repository",
        "~/Library/Caches/pip",
        "~/.pyenv/versions/*",
        "~/.rustup/toolchains/*",
        "~/.cargo/registry",
        "~/go/pkg/mod",
        "~/Library/Caches/go-build",
    ]
    public let category: StorageCategory? = .developerTools
    /// Where the official Go installer puts `go`.
    public let toolSearchDirectories = ["/usr/local/go/bin"]

    static let gradleStopNote = "Stop Gradle daemons first (./gradlew --stop)"

    public init() {}

    // MARK: Discover

    public func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        let home = context.home.path
        var items: [InspectorItem] = []

        func add(
            _ key: String, title: String, lose: String, risk: RiskLevel, paths: [String],
            subtitle: String? = nil, action: String, requiresTool tool: String? = nil
        ) async {
            let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard !existing.isEmpty else { return }
            var bytes: Int64 = 0
            var newest: Date?
            for path in existing {
                bytes += await context.sizer.allocatedSize(of: path)
                if let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                   newest.map({ date > $0 }) ?? true {
                    newest = date
                }
            }
            // Listed but not cleanable when the tool its plan runs is missing.
            let missingTool = tool.flatMap { context.tools.locate($0) == nil ? $0 : nil }
            let toolMissing = missingTool != nil
            items.append(InspectorItem(
                id: "\(id).\(key)", inspectorID: id, title: title,
                subtitle: missingTool.map { "\($0) not found" } ?? subtitle, whatYouLose: lose,
                allocatedBytes: bytes, risk: risk, lastUsed: newest, paths: existing,
                requirement: AppStateRequirement.none, actionTitle: action, isActionable: !toolMissing
            ))
        }

        // Gradle
        let daemonRunning = await gradleDaemonRunning(in: context)
        await add("gradle.caches", title: "Gradle caches", lose: "Downloaded dependencies and build caches; Gradle downloads them again on the next build.",
                  risk: .rebuildable, paths: [home + "/.gradle/caches"],
                  subtitle: daemonRunning ? "A Gradle daemon is running — stop it first" : nil, action: "Delete Gradle caches")
        for name in subdirectories(home + "/.gradle/wrapper/dists") {
            await add("gradle.wrapper.\(name)", title: "Gradle wrapper \(name)", lose: "This Gradle distribution; the wrapper downloads it again when a project needs it.",
                      risk: .rebuildable, paths: [home + "/.gradle/wrapper/dists/" + name], action: "Delete Gradle distribution")
        }
        await add("maven.repository", title: "Maven repository", lose: "Downloaded artifacts and locally installed ones; Maven downloads remote artifacts again, but locally installed artifacts are gone for good.",
                  risk: .rebuildable, paths: [home + "/.m2/repository"], action: "Delete Maven repository")

        // Python
        await add("pip.cache", title: "pip cache", lose: "Cached downloads and wheels; pip downloads them again.",
                  risk: .cache, paths: [home + "/Library/Caches/pip"], action: "Purge pip cache")
        let pythonVersions = subdirectories(home + "/.pyenv/versions")
        // Fail safe: without a readable, non-empty active-version file, offer no pyenv uninstalls.
        if let currentPython = pyenvActiveVersions(home: home) {
            for version in pythonVersions where !currentPython.contains(version) {
                await add("pyenv.\(version)", title: "Python \(version) (pyenv)", lose: "This Python installation and every package installed into it.",
                          risk: .rebuildable, paths: [home + "/.pyenv/versions/" + version], action: "Uninstall Python \(version)",
                          requiresTool: "pyenv")
            }
        }

        // Rust
        if let rustup = context.tools.locate("rustup") {
            let toolchains = subdirectories(home + "/.rustup/toolchains")
            // Fail safe: if the default can't be determined, list no toolchains.
            if !toolchains.isEmpty, let defaultToolchain = await rustupDefault(rustup, tools: context.tools) {
                for name in toolchains where name != defaultToolchain {
                    await add("rustup.\(name)", title: "Rust toolchain \(name)", lose: "This toolchain; rustup downloads it again when a project asks for it.",
                              risk: .rebuildable, paths: [home + "/.rustup/toolchains/" + name], action: "Uninstall toolchain", requiresTool: "rustup")
                }
            }
        }
        await add("cargo.registry", title: "Cargo registry cache", lose: "Downloaded crates and extracted sources; cargo downloads them again.",
                  risk: .cache, paths: [home + "/.cargo/registry/cache", home + "/.cargo/registry/src"], action: "Delete cargo registry cache")

        // Go
        await add("go.modcache", title: "Go module cache", lose: "Downloaded modules; Go downloads them again.",
                  risk: .rebuildable, paths: [home + "/go/pkg/mod"], action: "Clean Go module cache", requiresTool: "go")
        await add("go.buildcache", title: "Go build cache", lose: "Compiled packages; Go rebuilds them.",
                  risk: .cache, paths: [home + "/Library/Caches/go-build"], action: "Clean Go build cache", requiresTool: "go")

        return items
    }

    static let javaHome = "/usr/libexec/java_home"

    /// A jps failure counts the same as jps missing: no daemon is reported. Without a JDK,
    /// `/usr/bin/jps` is a stub that asks to install Java, so it runs only when `~/.gradle`
    /// exists and `java_home` finds a JDK.
    private func gradleDaemonRunning(in context: InspectorContext) async -> Bool {
        guard FileManager.default.fileExists(atPath: context.home.path + "/.gradle"),
              let javaHome = try? await context.tools.run(Self.javaHome, [], timeout: .seconds(10)),
              javaHome.exitCode == 0,
              let jps = context.tools.locate("jps"),
              let output = try? await context.tools.run(jps, ["-l"], timeout: .seconds(10)),
              output.exitCode == 0 else { return false }
        return output.stdout.contains("org.gradle.launcher.daemon")
    }

    private func subdirectories(_ path: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { name in
            var isDir: ObjCBool = false
            return !name.hasPrefix(".") && FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    /// `~/.pyenv/version` holds one or more versions separated by newlines or colons. Nil when the
    /// file is unreadable or names no version: the active version is then unknown.
    private func pyenvActiveVersions(home: String) -> Set<String>? {
        guard let text = try? String(contentsOfFile: home + "/.pyenv/version", encoding: .utf8) else { return nil }
        let versions = Set(text.split(whereSeparator: { $0.isWhitespace || $0 == ":" }).map(String.init))
        return versions.isEmpty ? nil : versions
    }

    /// `rustup default` prints e.g. `stable-aarch64-apple-darwin (default)`.
    private func rustupDefault(_ rustup: String, tools: any ToolRunning) async -> String? {
        guard let output = try? await tools.run(rustup, ["default"], timeout: .seconds(10)), output.exitCode == 0 else { return nil }
        let line = output.stdout.split(separator: "\n").first.map(String.init) ?? ""
        return line.split(separator: " ").first.map(String.init)
    }

    // MARK: Plan

    public func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        var steps: [CleanupStep] = []

        func step(_ item: InspectorItem, _ action: CleanupAction, bytes: Int64? = nil, note: String? = nil) -> CleanupStep {
            CleanupStep(title: item.title, risk: item.risk, estimatedBytes: bytes ?? item.allocatedBytes,
                        requirement: item.requirement, action: action, sideEffectNote: note)
        }
        func tool(_ name: String) throws -> String {
            guard let path = context.tools.locate(name) else { throw InspectorUnavailable("\(name) is not installed") }
            return path
        }
        func deletes(_ item: InspectorItem, note: String? = nil) -> [CleanupStep] {
            item.paths.map { step(item, .delete(path: $0, expectedFileID: nil), note: note) }
        }

        for item in items {
            let key = String(item.id.dropFirst(id.count + 1))
            switch key {
            case "gradle.caches":
                steps += deletes(item, note: Self.gradleStopNote)
            case "pip.cache":
                if let pip = context.tools.locate("pip3") {
                    steps.append(step(item, .runTool(executable: pip, arguments: ["cache", "purge"])))
                } else {
                    steps += deletes(item)
                }
            case "go.modcache":
                steps.append(step(item, .runTool(executable: try tool("go"), arguments: ["clean", "-modcache"])))
            case "go.buildcache":
                steps.append(step(item, .runTool(executable: try tool("go"), arguments: ["clean", "-cache"])))
            case _ where key.hasPrefix("pyenv."):
                let version = String(key.dropFirst("pyenv.".count))
                steps.append(step(item, .runTool(executable: try tool("pyenv"), arguments: ["uninstall", "-f", version])))
            case _ where key.hasPrefix("rustup."):
                let name = String(key.dropFirst("rustup.".count))
                steps.append(step(item, .runTool(executable: try tool("rustup"), arguments: ["toolchain", "uninstall", name])))
            case "cargo.registry":
                // Only cache and src are removed; the index stays.
                let sizes = await sizes(of: item.paths, context)
                for (path, bytes) in zip(item.paths, sizes) {
                    steps.append(step(item, .delete(path: path, expectedFileID: nil), bytes: bytes))
                }
            default:
                steps += deletes(item)
            }
        }
        return CleanupPlan(steps: steps)
    }

    private func sizes(of paths: [String], _ context: InspectorContext) async -> [Int64] {
        var result: [Int64] = []
        for path in paths { result.append(await context.sizer.allocatedSize(of: path)) }
        return result
    }
}
