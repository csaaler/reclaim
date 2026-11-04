import Foundation
import Testing
import StorageCore
import StorageDefinitions
import StorageInspectors
import StorageTestKit

/// Contract checks run against every registered inspector, including new ones, with no
/// inspector-specific setup. See the `Inspector` documentation for the contract.
///
/// Each inspector runs against fake homes (empty, and with a folder at every claimed pattern) and
/// fake tools (none installed, failing, or printing garbage). Whatever it finds must be well
/// formed, and every plan it returns must stay inside the rules.
@Suite struct InspectorConformanceTests {
    static let ids = allInspectors.map(\.id)

    static func inspector(_ id: String) throws -> any Inspector {
        try #require(allInspectors.first { $0.id == id })
    }

    // MARK: - Identity

    @Test func idsAreUnique() {
        #expect(Set(Self.ids).count == Self.ids.count)
    }

    @Test(arguments: ids)
    func idIsKebabCase(_ id: String) {
        #expect(Identifier.isKebabCase(id), "\(id) is not lowercase kebab-case")
    }

    /// Inspector and definition ids share one namespace (they name the owner of an item).
    @Test func idsDoNotCollideWithDefinitionIDs() {
        let collisions = Set(Self.ids).intersection(allDefinitions.map(\.id))
        #expect(collisions.isEmpty, "ids used by both an inspector and a definition: \(collisions.sorted())")
    }

    @Test(arguments: ids)
    func displayNameIsNotEmpty(_ id: String) throws {
        #expect(!Identifier.isBlank(try Self.inspector(id).displayName))
    }

    @Test(arguments: ids)
    func bundleIDsAreNotBlank(_ id: String) throws {
        #expect(!(try Self.inspector(id).bundleIDs.contains(where: Identifier.isBlank)))
    }

    // MARK: - Claims

    @Test(arguments: ids)
    func claimedPatternsFollowTheRules(_ id: String) throws {
        let home = URL(fileURLWithPath: "/Users/sample")
        for pattern in try Self.inspector(id).claimedPatterns {
            #expect(Self.claimProblems(pattern, home: home) == [])
        }
    }

    /// The claim checks must catch broad or protected claims, or a passing run proves nothing.
    @Test(arguments: [
        ("~/*", "wildcard in the first two segments"),
        ("~/Library/*", "wildcard in the first two segments"),
        ("/*/Developer", "wildcard in the first two segments"),
        ("~/Library/Keychains/*", "touches protected path"),
        ("~/Library/Mobile Documents/*", "touches protected path"),
        ("~/Library", "touches protected path"),
        ("~/Library/Caches", "structural folder"),
        ("~/Library/Ca*/Demo", "wildcard in the first two segments"),
        ("~/Library/Developer/../Keychains", "empty, . or .. segment"),
        ("Library/Caches/Demo", "must start with ~/ or /"),
    ])
    func claimChecksCatchBadPatterns(_ pattern: String, _ fragment: String) {
        let problems = Self.claimProblems(pattern, home: URL(fileURLWithPath: "/Users/sample"))
        #expect(problems.contains { $0.contains(fragment) }, "\(pattern): \(problems)")
    }

    /// Every rule a claimed pattern breaks.
    static func claimProblems(_ pattern: String, home: URL) -> [String] {
        guard pattern.hasPrefix("~/") || pattern.hasPrefix("/") else { return ["\(pattern) must start with ~/ or /"] }
        var problems: [String] = []
        let body = pattern.hasPrefix("~/") ? pattern.dropFirst(2) : pattern.dropFirst()
        let segments = body.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("**") }) {
            problems.append("\(pattern) has an empty, . or .. segment, a trailing / or **")
        }
        if segments.prefix(2).contains(where: { $0.contains("*") }) {
            problems.append("\(pattern) has a wildcard in the first two segments")
        }
        if let entry = ProtectedPaths(home: home).overlaps(pattern: pattern) {
            problems.append("\(pattern) touches protected path \(entry)")
        }
        let structural = PathValidator.structuralFolders(home: home)
        if structural.contains(where: { PathPattern.matches(pattern, path: $0, home: home) }) {
            problems.append("\(pattern) can match a structural folder")
        }
        return problems
    }

    // MARK: - Tool search directories

    /// Every inspector's directories go into one shared `ToolLocator` and the tools' `PATH`.
    @Test(arguments: ids)
    func toolSearchDirectoriesAreSafe(_ id: String) throws {
        let home = URL(fileURLWithPath: "/Users/sample")
        for directory in try Self.inspector(id).toolSearchDirectories {
            #expect(Self.toolDirectoryProblems(directory, home: home) == [])
        }
    }

    @Test(arguments: [
        ("bin", "must start with ~/ or /"),
        ("./bin", "must start with ~/ or /"),
        ("~/.example/../bin", "not standardized"),
        ("~/.example/bin/", "not standardized"),
        ("~/.example//bin", "not standardized"),
        ("~/.example/*/bin", "not standardized"),
        ("/tmp", "shared or download folder"),
        ("/private/tmp/bin", "shared or download folder"),
        ("/var/tmp", "shared or download folder"),
        ("/Users/Shared/bin", "shared or download folder"),
        ("~/Downloads", "shared or download folder"),
        ("~/Desktop/tools", "shared or download folder"),
        ("~/documents/bin", "shared or download folder"),
    ])
    func toolDirectoryChecksCatchBadDirectories(_ directory: String, _ fragment: String) {
        let problems = Self.toolDirectoryProblems(directory, home: URL(fileURLWithPath: "/Users/sample"))
        #expect(problems.contains { $0.contains(fragment) }, "\(directory): \(problems)")
    }

    /// Folders anyone, or any download, can write to; a tool found there must not be trusted.
    static let unsafeToolDirectories = [
        "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/Users/Shared",
        "~/Downloads", "~/Desktop", "~/Documents",
    ]

    static func toolDirectoryProblems(_ directory: String, home: URL) -> [String] {
        guard directory.hasPrefix("~/") || directory.hasPrefix("/") else {
            return ["\(directory) must start with ~/ or /"]
        }
        var problems: [String] = []
        let body = directory.hasPrefix("~/") ? directory.dropFirst(2) : directory.dropFirst()
        let segments = body.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("*") }) {
            problems.append("\(directory) is not standardized (empty, . or .. segment, trailing / or *)")
        }
        func expanded(_ path: String) -> PathKey {
            PathKey(path.hasPrefix("~/") ? home.path + "/" + path.dropFirst(2) : path)
        }
        let key = expanded(directory)
        if let unsafe = unsafeToolDirectories.first(where: { key == expanded($0) || key.isInside(expanded($0)) }) {
            problems.append("\(directory) is inside \(unsafe), a shared or download folder")
        }
        return problems
    }

    /// Ties between inspectors claiming the same path are resolved silently, so claims must not overlap.
    @Test(arguments: ids)
    func claimsDoNotOverlapOtherInspectors(_ id: String) throws {
        let home = URL(fileURLWithPath: "/Users/sample")
        let inspector = try Self.inspector(id)
        for other in allInspectors where other.id != id {
            for mine in inspector.claimedPatterns {
                for theirs in other.claimedPatterns {
                    #expect(
                        !PathPattern.overlaps(mine, theirs, home: home),
                        "\(id) claims \(mine), which overlaps \(other.id)'s \(theirs)")
                }
            }
        }
    }

    @Test(arguments: ids)
    func claimsDoNotOverlapDefinitions(_ id: String) throws {
        let home = URL(fileURLWithPath: "/Users/sample")
        let inspector = try Self.inspector(id)
        for def in allDefinitions {
            for mine in inspector.claimedPatterns {
                for location in def.locations {
                    #expect(
                        !PathPattern.overlaps(mine, location.pattern, home: home),
                        "\(id) claims \(mine), which overlaps the \(def.id) definition's \(location.pattern)")
                }
            }
        }
    }

    // MARK: - Discover and plan

    @Test(arguments: ids)
    func behavesInEveryEnvironment(_ id: String) async throws {
        let inspector = try Self.inspector(id)
        for populated in [false, true] {
            for tools in FakeTools.allCases {
                let fixture = try FixtureHome()
                if populated { try Self.populateClaims(of: inspector, in: fixture) }
                let context = InspectorContext(home: fixture.home, tools: tools.runner, sizer: LogicalSizer())
                let problems = await Self.problems(of: inspector, in: context)
                #expect(problems == [], "\(populated ? "populated" : "empty") home, \(tools)")
            }
        }
    }

    /// The checks must catch a broken inspector, or a passing run proves nothing.
    @Test func checksCatchABrokenInspector() async throws {
        let fixture = try FixtureHome()
        let context = InspectorContext(home: fixture.home, tools: FakeToolRunner(), sizer: LogicalSizer())
        let problems = await Self.problems(of: BrokenInspector(home: fixture.home.path), in: context)
        let expected = [
            "inspectorID is someone-else", "empty whatYouLose", "outside home",
            "must go to the Trash", "not one of its paths", "not an absolute path", "refused by ToolPolicy",
        ]
        for fragment in expected {
            #expect(problems.contains { $0.contains(fragment) }, "no problem mentions \"\(fragment)\"")
        }
    }

    /// Runs `discover`, then `plan` for each item on its own, and lists every contract violation.
    static func problems(of inspector: any Inspector, in context: InspectorContext) async -> [String] {
        let id = inspector.id
        let policy = ToolPolicy(home: context.home)
        var problems: [String] = []
        let items: [InspectorItem]
        do {
            items = try await inspector.discover(in: context)
        } catch is InspectorUnavailable {
            return []
        } catch {
            return ["\(id): discover threw \(error); only InspectorUnavailable is allowed"]
        }
        if Set(items.map(\.id)).count != items.count { problems.append("\(id): duplicate item ids") }

        func plan(_ items: [InspectorItem]) async -> CleanupPlan? {
            do {
                return try await inspector.plan(for: items, in: context)
            } catch is InspectorUnavailable {
                return nil
            } catch {
                problems.append("\(id): plan threw \(error); only InspectorUnavailable is allowed")
                return nil
            }
        }

        if let plan = await plan([]), !plan.steps.isEmpty { problems.append("\(id): plan([]) returned steps") }

        for item in items {
            if item.inspectorID != id { problems.append("\(item.id): inspectorID is \(item.inspectorID), not \(id)") }
            if Identifier.isBlank(item.id) { problems.append("\(id): item with an empty id") }
            if Identifier.isBlank(item.title) { problems.append("\(item.id): empty title") }
            if Identifier.isBlank(item.whatYouLose) { problems.append("\(item.id): empty whatYouLose") }
            if Identifier.isBlank(item.actionTitle) { problems.append("\(item.id): empty actionTitle") }
            if item.allocatedBytes < 0 { problems.append("\(item.id): negative size") }
            for path in item.paths where !isStandardAbsolute(path) {
                problems.append("\(item.id): path \(path) is not a standardized absolute path")
            }

            guard let plan = await plan([item]) else { continue }
            guard item.isActionable else {
                if !plan.steps.isEmpty { problems.append("\(item.id): not actionable, but plan returned steps") }
                continue
            }
            for path in item.paths
            where !isInside(path, context.home.path) && !isUnderAbsoluteClaim(path, inspector, home: context.home) {
                problems.append("\(item.id): actionable path \(path) is outside home and outside the inspector's claims")
            }
            problems += stepProblems(plan, of: item, policy: policy, locate: context.tools.locate)
        }
        return problems
    }

    /// Every step must also pass `ToolPolicy`, which the engine applies before it runs a tool or
    /// edits a JSON file. `locate` is the tool lookup the plan was built with.
    static func stepProblems(
        _ plan: CleanupPlan, of item: InspectorItem, policy: ToolPolicy, locate: (String) -> String?
    ) -> [String] {
        var problems: [String] = []
        var earlier = Set<UUID>()
        for step in plan.steps {
            let name = "\(item.id), step \"\(step.title)\""
            if Identifier.isBlank(step.title) { problems.append("\(item.id): step with an empty title") }
            if step.estimatedBytes < 0 { problems.append("\(name): negative estimate") }
            if step.risk < item.risk { problems.append("\(name): lower risk than its item") }
            if let dependency = step.dependsOn, !earlier.contains(dependency) {
                problems.append("\(name): depends on a later or unknown step")
            }
            earlier.insert(step.id)
            if let violation = policy.violation(for: step.action, locate: locate) {
                problems.append("\(name): refused by ToolPolicy (\(violation))")
            }

            switch step.action {
            case .delete(let path, _):
                if step.risk == .userData || item.risk == .userData {
                    problems.append("\(name): 🔴 data must go to the Trash, not .delete")
                }
                if !isInsideAny(path, item.paths) { problems.append("\(name): deletes \(path), which is not one of its paths") }
            case .trash(let path, _):
                if !isInsideAny(path, item.paths) { problems.append("\(name): trashes \(path), which is not one of its paths") }
            case .removeJSONKeys(let path, let edits):
                if !isStandardAbsolute(path) { problems.append("\(name): edits \(path), which is not an absolute path") }
                let keyPaths = edits.map { edit -> [String] in
                    switch edit {
                    case .removeKey(let keyPath), .removeArrayValue(let keyPath, _): keyPath
                    }
                }
                if keyPaths.isEmpty || keyPaths.contains(where: \.isEmpty) { problems.append("\(name): empty JSON key path") }
            case .runTool(let executable, _):
                if !isStandardAbsolute(executable) { problems.append("\(name): runs \(executable), which is not an absolute path") }
            }
        }
        return problems
    }

    // MARK: - Fixtures

    /// Tool environments: nothing installed; every tool found but failing to launch; every tool
    /// found but printing garbage.
    enum FakeTools: CaseIterable, CustomStringConvertible {
        case none, failing, garbage

        var runner: any ToolRunning {
            switch self {
            case .none: FakeToolRunner()
            case .failing: AnyToolRunner(output: nil)
            case .garbage: AnyToolRunner(output: ToolOutput(exitCode: 0, stdout: "garbage\n{\"Type\":\n\u{0}", stderr: ""))
            }
        }

        var description: String {
            switch self {
            case .none: "no tools installed"
            case .failing: "failing tools"
            case .garbage: "tools printing garbage"
            }
        }
    }

    /// Creates a small file inside a folder at each `~/` claimed pattern (`*` becomes `example`).
    static func populateClaims(of inspector: any Inspector, in fixture: FixtureHome) throws {
        for pattern in inspector.claimedPatterns where pattern.hasPrefix("~/") {
            let relative = pattern.dropFirst(2).replacingOccurrences(of: "*", with: "example")
            try fixture.file(relative + "/example.bin", bytes: 2048)
        }
    }

    static func isUnderAbsoluteClaim(_ path: String, _ inspector: any Inspector, home: URL) -> Bool {
        var current = ""
        for segment in path.split(separator: "/") {
            current += "/" + segment
            if inspector.claimedPatterns.contains(where: { $0.hasPrefix("/") && PathPattern.matches($0, path: current, home: home) }) {
                return true
            }
        }
        return false
    }

    static func isStandardAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && PathKey(path).raw == path
    }

    static func isInside(_ path: String, _ ancestor: String) -> Bool {
        let key = PathKey(path)
        return key.isInside(PathKey(ancestor))
    }

    static func isInsideAny(_ path: String, _ roots: [String]) -> Bool {
        roots.contains { PathKey(path) == PathKey($0) || isInside(path, $0) }
    }
}

/// Finds every tool at `/usr/local/bin/<name>`. `run` throws when `output` is nil.
private struct AnyToolRunner: ToolRunning {
    struct LaunchFailed: Error {}

    let output: ToolOutput?

    func locate(_ name: String) -> String? {
        name.isEmpty || name.contains("/") ? nil : "/usr/local/bin/" + name
    }

    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> ToolOutput {
        guard let output else { throw LaunchFailed() }
        return output
    }
}

/// Breaks the contract on purpose; see `checksCatchABrokenInspector`.
private struct BrokenInspector: Inspector {
    let home: String
    let id = "broken"
    let displayName = "Broken"
    let bundleIDs: [String] = []
    let claimedPatterns: [String] = []

    func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        [InspectorItem(
            id: "broken.item", inspectorID: "someone-else", title: "Item", whatYouLose: " ",
            allocatedBytes: 1, risk: .userData, lastUsed: nil, paths: ["/Users/sample/Elsewhere"],
            requirement: .none, actionTitle: "Remove")]
    }

    func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        CleanupPlan(steps: items.isEmpty ? [] : [
            CleanupStep(title: "Delete", risk: .userData, estimatedBytes: 1, requirement: .none,
                        action: .delete(path: home + "/Documents", expectedFileID: nil)),
            CleanupStep(title: "Run", risk: .userData, estimatedBytes: 1, requirement: .none,
                        action: .runTool(executable: "rm", arguments: ["-rf", "/"])),
        ])
    }
}
