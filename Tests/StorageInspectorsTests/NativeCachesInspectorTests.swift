import Foundation
import Testing
import StorageCore
import StorageTestKit
@testable import StorageInspectors

@Suite struct NativeCachesInspectorTests {
    static let tools = [
        "jps": "/usr/bin/jps", "pip3": "/usr/bin/pip3", "pyenv": "/opt/pyenv",
        "rustup": "/opt/rustup", "go": "/opt/go",
    ]
    static let note = "Stop Gradle daemons first (./gradlew --stop)"
    static let javaHome = "/usr/libexec/java_home"
    static let javaHomeOK = ToolOutput(exitCode: 0, stdout: "/Library/Java/JavaVirtualMachines/jdk/Contents/Home\n", stderr: "")

    func fixture() throws -> FixtureHome {
        let f = try FixtureHome()
        try f.file(".gradle/caches/a.bin", bytes: 100)
        try f.file(".gradle/wrapper/dists/gradle-8.5-bin/x/f", bytes: 200)
        try f.file(".gradle/wrapper/dists/gradle-7.6-bin/x/f", bytes: 300)
        try f.file(".m2/repository/a/b.jar", bytes: 400)
        try f.file("Library/Caches/pip/p", bytes: 500)
        try f.file(".pyenv/versions/3.11.9/bin/python", bytes: 600)
        try f.file(".pyenv/versions/3.12.2/bin/python", bytes: 700)
        try f.file(".pyenv/version", bytes: 0)
        try Data("3.12.2\n".utf8).write(to: f.home.appendingPathComponent(".pyenv/version"))
        try f.file(".rustup/toolchains/stable-aarch64-apple-darwin/x", bytes: 800)
        try f.file(".rustup/toolchains/1.97.0-aarch64-apple-darwin/x", bytes: 900)
        try f.file(".cargo/registry/cache/c", bytes: 1000)
        try f.file(".cargo/registry/src/s", bytes: 1100)
        try f.file(".cargo/registry/index/i", bytes: 5000)
        try f.file("go/pkg/mod/m", bytes: 1200)
        try f.file("Library/Caches/go-build/g", bytes: 1300)
        return f
    }

    func runner(jps: String = "123 org.gradle.launcher.daemon.bootstrap.GradleDaemon\n456 Foo\n", tools: [String: String] = NativeCachesInspectorTests.tools) -> FakeToolRunner {
        let r = FakeToolRunner(tools: tools)
        r.stub(Self.javaHome, [], output: Self.javaHomeOK)
        r.stub("/usr/bin/jps", ["-l"], output: ToolOutput(exitCode: 0, stdout: jps, stderr: ""))
        r.stub("/opt/rustup", ["default"], output: ToolOutput(exitCode: 0, stdout: "stable-aarch64-apple-darwin (default)\n", stderr: ""))
        return r
    }

    func context(_ f: FixtureHome, _ r: FakeToolRunner) -> InspectorContext {
        InspectorContext(home: f.home, tools: r, sizer: LogicalSizer())
    }

    @Test func discoversItemsAndExcludesDefaults() async throws {
        let f = try fixture()
        let items = try await NativeCachesInspector().discover(in: context(f, runner(jps: "9 Jps\n")))
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        #expect(Set(byID.keys) == [
            "native-caches.gradle.caches", "native-caches.gradle.wrapper.gradle-8.5-bin",
            "native-caches.gradle.wrapper.gradle-7.6-bin", "native-caches.maven.repository",
            "native-caches.pip.cache", "native-caches.pyenv.3.11.9", "native-caches.rustup.1.97.0-aarch64-apple-darwin",
            "native-caches.cargo.registry", "native-caches.go.modcache", "native-caches.go.buildcache",
        ])
        #expect(byID["native-caches.gradle.caches"]?.allocatedBytes == 100)
        #expect(byID["native-caches.gradle.caches"]?.risk == .rebuildable)
        #expect(byID["native-caches.gradle.caches"]?.requirement == AppStateRequirement.none)
        #expect(byID["native-caches.pip.cache"]?.risk == .cache)
        #expect(byID["native-caches.pyenv.3.11.9"]?.allocatedBytes == 600)
        #expect(byID["native-caches.cargo.registry"]?.allocatedBytes == 2100)
        #expect(byID["native-caches.cargo.registry"]?.risk == .cache)
        #expect(byID["native-caches.go.buildcache"]?.risk == .cache)
        #expect(byID["native-caches.go.modcache"]?.risk == .rebuildable)
        #expect(byID["native-caches.maven.repository"]?.lastUsed != nil)
    }

    @Test func runningGradleDaemonSetsSubtitleAndNote() async throws {
        let f = try fixture()
        let ctx = context(f, runner())
        let inspector = NativeCachesInspector()
        let items = try await inspector.discover(in: ctx)
        let gradle = try #require(items.first { $0.id == "native-caches.gradle.caches" })
        #expect(gradle.requirement == AppStateRequirement.none)
        #expect(gradle.subtitle == "A Gradle daemon is running — stop it first")
        let plan = try await inspector.plan(for: [gradle], in: ctx)
        #expect(plan.steps.map(\.sideEffectNote) == [Self.note])
    }

    @Test func missingOrFailingJpsStillNotesAndHasNoSubtitle() async throws {
        let f = try fixture()
        var t = Self.tools
        t["jps"] = nil
        let failing = FakeToolRunner(tools: Self.tools)
        failing.stub(Self.javaHome, [], output: Self.javaHomeOK)
        failing.stub("/usr/bin/jps", ["-l"], output: ToolOutput(exitCode: 1, stdout: "1 org.gradle.launcher.daemon.X", stderr: ""))
        failing.stub("/opt/rustup", ["default"], output: ToolOutput(exitCode: 0, stdout: "stable-aarch64-apple-darwin (default)\n", stderr: ""))
        for r in [runner(tools: t), failing] {
            let ctx = context(f, r)
            let inspector = NativeCachesInspector()
            let items = try await inspector.discover(in: ctx)
            let gradle = try #require(items.first { $0.id == "native-caches.gradle.caches" })
            #expect(gradle.requirement == AppStateRequirement.none)
            #expect(gradle.subtitle == nil)
            let plan = try await inspector.plan(for: [gradle], in: ctx)
            #expect(plan.steps.count == 1)
            #expect(plan.steps[0].sideEffectNote == Self.note)
            #expect(plan.steps[0].action == .delete(path: f.home.appendingPathComponent(".gradle/caches").path, expectedFileID: nil))
        }
    }

    @Test func jpsRunsOnlyWithGradleAndAJDK() async throws {
        // No JDK: java_home fails (or is unstubbed), so jps, whose stub would prompt to install
        // Java, is never run.
        let f = try fixture()
        let noJDK = runner()
        noJDK.stub(Self.javaHome, [], output: ToolOutput(exitCode: 1, stdout: "", stderr: "Unable to locate a Java Runtime."))
        let unstubbed = FakeToolRunner(tools: Self.tools)
        for r in [noJDK, unstubbed] {
            let items = try await NativeCachesInspector().discover(in: context(f, r))
            #expect(!r.invocations.contains { $0.0 == "/usr/bin/jps" })
            #expect(items.first { $0.id == "native-caches.gradle.caches" }?.subtitle == nil)
        }

        // No ~/.gradle: neither java_home nor jps is run.
        let bare = try FixtureHome()
        try bare.file("Library/Caches/pip/p", bytes: 5)
        let r = runner()
        _ = try await NativeCachesInspector().discover(in: context(bare, r))
        #expect(!r.invocations.contains { $0.0 == "/usr/bin/jps" || $0.0 == Self.javaHome })

        // Gradle and a JDK: java_home is checked, then jps runs.
        let withJDK = runner()
        _ = try await NativeCachesInspector().discover(in: context(f, withJDK))
        #expect(withJDK.invocations.map(\.0).filter { $0 == Self.javaHome || $0 == "/usr/bin/jps" } == [Self.javaHome, "/usr/bin/jps"])
    }

    @Test func failingRustupDefaultListsNoToolchains() async throws {
        let f = try fixture()
        let r = FakeToolRunner(tools: Self.tools)
        r.stub("/usr/bin/jps", ["-l"], output: ToolOutput(exitCode: 0, stdout: "", stderr: ""))
        r.stub("/opt/rustup", ["default"], output: ToolOutput(exitCode: 1, stdout: "", stderr: "error"))
        let items = try await NativeCachesInspector().discover(in: context(f, r))
        #expect(!items.contains { $0.id.hasPrefix("native-caches.rustup.") })
        // Unstubbed (throwing) rustup behaves the same.
        let r2 = FakeToolRunner(tools: Self.tools)
        let items2 = try await NativeCachesInspector().discover(in: context(f, r2))
        #expect(!items2.contains { $0.id.hasPrefix("native-caches.rustup.") })
    }

    @Test func unreadablePyenvVersionFileListsNoPyenvItems() async throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.home.appendingPathComponent(".pyenv/version"))
        let items = try await NativeCachesInspector().discover(in: context(f, runner()))
        #expect(!items.contains { $0.id.hasPrefix("native-caches.pyenv.") })
    }

    @Test func emptyPyenvVersionFileListsNoPyenvItems() async throws {
        let f = try fixture()
        for content in ["", "\n", "  \n:\n"] {
            try Data(content.utf8).write(to: f.home.appendingPathComponent(".pyenv/version"))
            let items = try await NativeCachesInspector().discover(in: context(f, runner()))
            #expect(!items.contains { $0.id.hasPrefix("native-caches.pyenv.") }, "version file: \(content.debugDescription)")
        }
    }

    @Test func plansExactActions() async throws {
        let f = try fixture()
        let ctx = context(f, runner(jps: ""))
        let inspector = NativeCachesInspector()
        let items = try await inspector.discover(in: ctx)
        let plan = try await inspector.plan(for: items, in: ctx)
        var actions: [String: [CleanupAction]] = [:]
        for item in items {
            actions[item.id] = try await inspector.plan(for: [item], in: ctx).steps.map(\.action)
        }
        let h = f.home.path
        #expect(actions["native-caches.pip.cache"] == [.runTool(executable: "/usr/bin/pip3", arguments: ["cache", "purge"])])
        #expect(actions["native-caches.pyenv.3.11.9"] == [.runTool(executable: "/opt/pyenv", arguments: ["uninstall", "-f", "3.11.9"])])
        #expect(actions["native-caches.rustup.1.97.0-aarch64-apple-darwin"] == [.runTool(executable: "/opt/rustup", arguments: ["toolchain", "uninstall", "1.97.0-aarch64-apple-darwin"])])
        #expect(actions["native-caches.go.modcache"] == [.runTool(executable: "/opt/go", arguments: ["clean", "-modcache"])])
        #expect(actions["native-caches.go.buildcache"] == [.runTool(executable: "/opt/go", arguments: ["clean", "-cache"])])
        #expect(actions["native-caches.maven.repository"] == [.delete(path: h + "/.m2/repository", expectedFileID: nil)])
        #expect(actions["native-caches.gradle.wrapper.gradle-8.5-bin"] == [.delete(path: h + "/.gradle/wrapper/dists/gradle-8.5-bin", expectedFileID: nil)])
        let cargo: [CleanupAction] = [
            .delete(path: h + "/.cargo/registry/cache", expectedFileID: nil),
            .delete(path: h + "/.cargo/registry/src", expectedFileID: nil),
        ]
        #expect(actions["native-caches.cargo.registry"] == cargo)
        #expect(plan.steps.allSatisfy { $0.estimatedBytes > 0 })
    }

    @Test func pipFallsBackToDeleteWithoutPip3() async throws {
        let f = try fixture()
        var t = Self.tools
        t["pip3"] = nil
        let ctx = context(f, runner(tools: t))
        let inspector = NativeCachesInspector()
        let items = try await inspector.discover(in: ctx)
        let pip = try #require(items.first { $0.id == "native-caches.pip.cache" })
        let plan = try await inspector.plan(for: [pip], in: ctx)
        #expect(plan.steps.map(\.action) == [.delete(path: f.home.path + "/Library/Caches/pip", expectedFileID: nil)])
    }

    @Test func missingGoThrowsAtPlan() async throws {
        let f = try fixture()
        var t = Self.tools
        t["go"] = nil
        let ctx = context(f, runner(tools: t))
        let inspector = NativeCachesInspector()
        let items = try await inspector.discover(in: ctx)
        let go = try #require(items.first { $0.id == "native-caches.go.modcache" })
        #expect(go.subtitle == "go not found")
        #expect(!go.isActionable)
        #expect(items.first { $0.id == "native-caches.go.buildcache" }?.isActionable == false)
        #expect(items.first { $0.id == "native-caches.pip.cache" }?.isActionable == true)
        await #expect(throws: InspectorUnavailable.self) { try await inspector.plan(for: [go], in: ctx) }
    }

    @Test func missingPyenvListsVersionsAsNotActionable() async throws {
        let f = try fixture()
        var t = Self.tools
        t["pyenv"] = nil
        let items = try await NativeCachesInspector().discover(in: context(f, runner(tools: t)))
        let python = try #require(items.first { $0.id == "native-caches.pyenv.3.11.9" })
        #expect(python.subtitle == "pyenv not found")
        #expect(!python.isActionable)
    }
}
