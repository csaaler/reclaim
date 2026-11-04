import Foundation
import Testing
import StorageCore
import StorageInspectors
import StorageTestKit

@Suite struct InspectorRegistryTests {
    @Test func inspectorsAreRegisteredWithUniqueIDs() {
        let ids = allInspectors.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count)
    }

    /// An inspector that is declared but not registered compiles, but is never run, shown or
    /// checked by the conformance tests, so every `Inspector` type in the module must be listed.
    @Test func everyDeclaredInspectorIsRegistered() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorageInspectors")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "no sources found at \(sources.path)")
        var declared = Set<String>()
        for file in files {
            declared.formUnion(InspectorDeclarations.names(in: try String(contentsOf: file, encoding: .utf8)))
        }
        let registered = Set(allInspectors.map { String(describing: type(of: $0)) })
        #expect(!declared.isEmpty)
        #expect(declared.subtracting(registered).sorted() == [], "declared but not in allInspectors")
    }

    @Test func inspectorDeclarationScanFindsEveryForm() {
        let source = """
            public struct Spaced : Inspector {}
            public final class FinalClass: Inspector {}
            struct Later {}
            extension Later: Inspector {}
            public struct Listed: Sendable, StorageCore.Inspector, Hashable {}
            public struct Generic<T>: Inspector where T: Sendable {}
            public struct
                MultiLine: Inspector {}
            // public struct Commented: Inspector {}
            struct NotOne: InspectorContextProviding {}
            struct Other: Sendable {}
            """
        #expect(InspectorDeclarations.names(in: source)
            == ["Spaced", "FinalClass", "Later", "Listed", "Generic", "MultiLine"])
    }

    @Test func defaultClaimedPathsExpandAgainstHome() async throws {
        let fixture = try FixtureHome()
        try fixture.dir("Library/Caches/com.x.ShipIt")
        let context = InspectorContext(home: fixture.home, tools: FakeToolRunner(), sizer: LogicalSizer())
        let paths = await UpdaterLeftoversInspector().claimedPaths(in: context)
        #expect(paths == [fixture.home.path + "/Library/Caches/com.x.ShipIt"])
    }

    @Test func configuredInspectorsMatchTheRegistry() {
        let configured = configuredInspectors(codeRoots: ["~/work"])
        #expect(configured.map(\.id) == allInspectors.map(\.id))
    }

    @Test func configuredInspectorsApplyCodeRoots() throws {
        let configured = configuredInspectors(codeRoots: ["~/work", "~/src"])
        let builds = try #require(configured.compactMap { $0 as? ProjectBuildsInspector }.first)
        #expect(builds.codeRoots == ["~/work", "~/src"])
    }

    @Test func categoryDefaultsToNil() {
        #expect(UpdaterLeftoversInspector().category == nil)
    }

    @Test(arguments: ["docker", "xcode", "android", "jetbrains", "js-caches", "native-caches", "project-builds"])
    func developerToolInspectorsSayTheyAre(_ id: String) throws {
        let inspector = try #require(allInspectors.first { $0.id == id })
        #expect(inspector.category == .developerTools)
    }

    @Test func toolSearchDirectoriesDefaultToEmpty() {
        #expect(UpdaterLeftoversInspector().toolSearchDirectories.isEmpty)
    }

    @Test func toolLocatorSearchesInspectorDirectories() throws {
        let fixture = try FixtureHome()
        try fixture.file(".example/bin/example-tool", bytes: 8)
        let tool = fixture.home.path + "/.example/bin/example-tool"
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)

        let locator = ToolLocator(home: fixture.home, inspectors: [ToolDirectoryInspector()], systemDirectories: [])
        #expect(locator.directories.contains(fixture.home.path + "/.example/bin"))
        #expect(locator.locate("example-tool") == tool)
        #expect(ToolLocator(home: fixture.home, systemDirectories: []).locate("example-tool") == nil)
    }

    @Test(arguments: [
        ("bun", ".bun/bin"), ("pnpm", "Library/pnpm"), ("npm", ".volta/bin"),
    ])
    func toolLocatorFindsCommonUserInstalls(_ tool: String, _ directory: String) throws {
        let fixture = try FixtureHome()
        try fixture.file("\(directory)/\(tool)", bytes: 8)
        let path = fixture.home.path + "/\(directory)/\(tool)"
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let locator = ToolLocator(home: fixture.home, inspectors: allInspectors, systemDirectories: [])
        #expect(locator.locate(tool) == path)
    }

    @Test func toolLocatorSearchesTheOfficialGoInstall() throws {
        let fixture = try FixtureHome()
        let locator = ToolLocator(home: fixture.home, inspectors: allInspectors, systemDirectories: [])
        #expect(locator.directories.contains("/usr/local/go/bin"))
    }

    @Test func toolLocatorListsEachDirectoryOnce() throws {
        let fixture = try FixtureHome()
        let locator = ToolLocator(
            home: fixture.home, inspectors: [ToolDirectoryInspector(), ToolDirectoryInspector()],
            systemDirectories: ["/usr/bin", "/usr/bin"])
        #expect(locator.directories.count == Set(locator.directories).count)
    }
}

private struct ToolDirectoryInspector: Inspector {
    let id = "tool-directory-example"
    let displayName = "Example"
    let bundleIDs: [String] = []
    let claimedPatterns: [String] = []
    let toolSearchDirectories = ["~/.example/bin"]

    func discover(in context: InspectorContext) async throws -> [InspectorItem] { [] }

    func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        CleanupPlan(steps: [])
    }
}

/// Finds the types a Swift source file declares, or extends, as conforming to `Inspector`: any
/// `struct`, `class`, `actor`, `enum` or `extension` whose inheritance list names it, whatever the
/// modifiers, spacing or line breaks. Comments are dropped first. A text scan, not a parser: a
/// conformance added through a typealias or a protocol that refines `Inspector` is not seen.
enum InspectorDeclarations {
    static func names(in source: String) -> [String] {
        let code = source
            .replacing(#/\/\*[\s\S]*?\*\//#, with: "")
            .replacing(#/\/\/[^\n]*/#, with: "")
        let declaration = #/\b(?:struct|class|actor|enum|extension)\s+([A-Za-z_][A-Za-z0-9_]*)(?:<[^>{]*>)?\s*:([^{]*)\{/#
        var names: [String] = []
        for match in code.matches(of: declaration) {
            let inherited = match.output.2.replacing(#/\bwhere\b[\s\S]*/#, with: "")
            let conforms = inherited.split(separator: ",").contains {
                let name = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return name == "Inspector" || name == "StorageCore.Inspector"
            }
            let name = String(match.output.1)
            if conforms && !names.contains(name) { names.append(name) }
        }
        return names
    }
}
