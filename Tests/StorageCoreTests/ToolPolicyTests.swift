import Foundation
import Testing
import StorageCore

@Suite struct ToolPolicyTests {
    static let home = URL(fileURLWithPath: "/Users/sample")
    static let localState = "/Users/sample/Library/Application Support/Google/Chrome/Local State"
    static let located = [
        "docker": "/usr/local/bin/docker", "xcrun": "/usr/bin/xcrun", "npm": "/opt/homebrew/bin/npm",
        "pnpm": "/opt/homebrew/bin/pnpm", "brew": "/opt/homebrew/bin/brew", "yarn": "/opt/homebrew/bin/yarn",
        "bun": "/Users/sample/.bun/bin/bun", "pip3": "/usr/bin/pip3", "go": "/opt/homebrew/bin/go",
        "pyenv": "/opt/homebrew/bin/pyenv", "rustup": "/Users/sample/.cargo/bin/rustup",
        "rm": "/bin/rm", "sh": "/bin/sh",
    ]

    let policy = ToolPolicy(home: Self.home)

    func check(_ action: CleanupAction) -> SafetyViolation? {
        policy.violation(for: action, locate: { Self.located[$0] })
    }

    func tool(_ name: String, _ arguments: [String]) -> CleanupAction {
        .runTool(executable: Self.located[name]!, arguments: arguments)
    }

    // MARK: - runTool

    /// Every command the built-in inspectors plan today.
    @Test(arguments: [
        ("docker", ["image", "prune", "-a", "-f"]),
        ("docker", ["container", "prune", "-f"]),
        ("docker", ["volume", "prune", "-a", "-f"]),
        ("docker", ["builder", "prune", "-a", "-f"]),
        ("xcrun", ["simctl", "delete", "unavailable"]),
        ("xcrun", ["simctl", "delete", "5A3F0C2E-1B7D-4E2A-9C61-0D8F4B2A7E13"]),
        ("xcrun", ["simctl", "runtime", "delete", "C0FFEE00-1111-2222-3333-444455556666"]),
        ("npm", ["cache", "clean", "--force"]),
        ("pnpm", ["store", "prune"]),
        ("brew", ["cleanup", "--prune=all", "-s"]),
        ("yarn", ["cache", "clean"]),
        ("bun", ["pm", "cache", "rm"]),
        ("pip3", ["cache", "purge"]),
        ("go", ["clean", "-modcache"]),
        ("go", ["clean", "-cache"]),
        ("pyenv", ["uninstall", "-f", "3.11.9"]),
        ("pyenv", ["uninstall", "-f", "pypy3.10-7.3.17"]),
        ("rustup", ["toolchain", "uninstall", "1.97.0-aarch64-apple-darwin"]),
        ("rustup", ["toolchain", "uninstall", "nightly-2026-01-01-aarch64-apple-darwin"]),
    ])
    func allowedCommandPasses(name: String, arguments: [String]) {
        #expect(check(tool(name, arguments)) == nil)
    }

    @Test func toolNotOnTheListIsRejected() {
        let rm = CleanupAction.runTool(executable: "/bin/rm", arguments: ["-rf", "/Users/sample/Documents"])
        #expect(check(rm) == .toolNotAllowed("/bin/rm -rf /Users/sample/Documents"))
        #expect(check(.runTool(executable: "/bin/sh", arguments: ["-c", "docker image prune -a -f"])) != nil)
    }

    @Test func subcommandOrFlagNotOnTheListIsRejected() {
        #expect(check(tool("docker", ["system", "prune", "-a", "-f", "--volumes"])) != nil)
        #expect(check(tool("docker", ["image", "prune", "-a", "-f", "--filter", "until=1h"])) != nil)
        #expect(check(tool("docker", ["image", "prune", "-a"])) != nil)
        #expect(check(tool("docker", ["image", "prune", "-f", "-a"])) != nil)
        #expect(check(tool("brew", ["uninstall", "--force", "git"])) != nil)
        #expect(check(tool("go", [])) != nil)
    }

    @Test func variableArgumentCannotBeAnOptionOrAPath() {
        // `simctl delete all` and `booted` are valid simctl commands that remove far more than
        // one device, so simctl only takes a UDID.
        for value in ["all", "booted", "unavailable-ish", "5A3F0C2E", "5A3F0C2E-1B7D-4E2A-9C61-0D8F4B2A7E13 "] {
            #expect(check(tool("xcrun", ["simctl", "delete", value])) != nil, "\(value)")
            #expect(check(tool("xcrun", ["simctl", "runtime", "delete", value])) != nil, "\(value)")
        }
        for value in ["--all", "-rf", "../x", "/Users/sample", "a b", "", "a/b", ".hidden", String(repeating: "a", count: 256)] {
            #expect(check(tool("pyenv", ["uninstall", "-f", value])) != nil, "\(value)")
            #expect(check(tool("rustup", ["toolchain", "uninstall", value])) != nil, "\(value)")
        }
    }

    @Test func executableMustBeWhereTheToolRunnerFindsIt() {
        // Right name, wrong place: a copy planted elsewhere does not run.
        #expect(check(.runTool(executable: "/tmp/docker", arguments: ["image", "prune", "-a", "-f"])) != nil)
        #expect(check(.runTool(executable: "/Users/sample/bin/go", arguments: ["clean", "-cache"])) != nil)
        // A relative executable never matches a located path.
        #expect(check(.runTool(executable: "docker", arguments: ["image", "prune", "-a", "-f"])) != nil)
        // An allowed tool that is not installed.
        let missing = policy.violation(for: tool("go", ["clean", "-cache"]), locate: { _ in nil })
        #expect(missing == .toolNotAllowed("/opt/homebrew/bin/go clean -cache"))
    }

    @Test func pathActionsAreLeftToThePathValidator() {
        #expect(check(.delete(path: "/Users/sample/Library/Caches/x", expectedFileID: nil)) == nil)
        #expect(check(.trash(path: "/Users/sample/Documents/x", expectedFileID: nil)) == nil)
    }

    // MARK: - removeJSONKeys

    @Test func chromeProfileListEditPasses() {
        let edit = CleanupAction.removeJSONKeys(path: Self.localState, edits: [
            .removeKey(["profile", "info_cache", "Profile 11"]),
            .removeArrayValue(keyPath: ["profile", "profiles_order"], value: "Profile 11"),
            .removeArrayValue(keyPath: ["profile", "last_active_profiles"], value: "Profile 11"),
        ])
        #expect(check(edit) == nil)
        #expect(check(.removeJSONKeys(path: Self.localState, edits: [.removeKey(["profile", "info_cache", "Default"])])) == nil)
    }

    @Test func editToAnotherFileIsRejected() {
        let edits: [JSONEdit] = [.removeKey(["profile", "info_cache", "Profile 11"])]
        for path in [
            "/Users/sample/Library/Application Support/Google/Chrome/Profile 11/Preferences",
            "/Users/sample/Library/Application Support/Google/Chrome Beta/Local State",
            "/Users/sample/Other Home/Library/Application Support/Google/Chrome/Local State",
            "/Users/sample/Library/Caches/x/Library/Application Support/Google/Chrome/Local State",
            "Library/Application Support/Google/Chrome/Local State",
        ] {
            #expect(check(.removeJSONKeys(path: path, edits: edits)) == .editNotAllowed(path))
        }
    }

    @Test func editOfOtherKeysIsRejected() {
        for edit: JSONEdit in [
            .removeKey(["profile"]),
            .removeKey(["profile", "info_cache"]),
            .removeKey(["profile", "last_used"]),
            .removeKey(["browser", "enabled_labs_experiments"]),
            .removeKey(["profile", "info_cache", "Profile 11", "name"]),
            .removeKey(["profile", "info_cache", ".."]),
            .removeKey(["profile", "info_cache", "a/b"]),
            .removeArrayValue(keyPath: ["profile", "info_cache"], value: "Profile 11"),
            .removeArrayValue(keyPath: ["profile", "profiles_order"], value: ""),
        ] {
            let action = CleanupAction.removeJSONKeys(path: Self.localState, edits: [
                .removeKey(["profile", "info_cache", "Profile 11"]), edit,
            ])
            #expect(check(action) == .editNotAllowed(Self.localState), "\(edit)")
        }
    }

    @Test func localStateMatchesTheResolvedHomeToo() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("home-link")
        let real = base.appendingPathComponent("home-real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let policy = ToolPolicy(home: link)
        let edits: [JSONEdit] = [.removeKey(["profile", "info_cache", "Profile 2"])]
        let suffix = "/Library/Application Support/Google/Chrome/Local State"
        let resolvedReal = try #require(realpath(real.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        #expect(policy.violation(for: .removeJSONKeys(path: link.path + suffix, edits: edits), locate: { _ in nil }) == nil)
        #expect(policy.violation(for: .removeJSONKeys(path: resolvedReal + suffix, edits: edits), locate: { _ in nil }) == nil)
    }

    @Test func policyTablesAreReadable() {
        #expect(Set(ToolPolicy.tools.keys) == [
            "docker", "xcrun", "npm", "pnpm", "brew", "yarn", "bun", "pip3", "go", "pyenv", "rustup",
        ])
        #expect(ToolPolicy.jsonFiles.map(\.path) == ["~/Library/Application Support/Google/Chrome/Local State"])
    }
}
