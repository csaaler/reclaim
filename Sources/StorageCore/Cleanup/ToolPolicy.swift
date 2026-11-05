import Foundation

/// Every command (`runTool`) and every JSON file edit (`removeJSONKeys`) a cleanup plan may
/// contain. `CleanupEngine` refuses a step that does not match, both in preflight and again
/// immediately before acting, and logs it as skipped.
///
/// `PathValidator` guards `delete` and `trash`. A tool or a JSON edit acts on things the path
/// checks cannot see, so this allow-list guards them instead:
///
/// - **Tools** are named, not given by path. A step's executable must be exactly the path that
///   the engine's tool runner finds for that name (`ToolRunning.locate`, i.e. `ToolLocator`), and
///   its arguments must match one of the listed argument lists, position by position.
/// - **JSON edits** are allowed only on the listed files, and only in the listed shapes.
///
/// Supporting a new tool, subcommand, flag or editable file means changing this file. Keep the
/// entries as narrow as the feature allows.
public struct ToolPolicy: Sendable {
    /// One position in an allowed argument list or JSON key path.
    public enum Argument: Sendable, Hashable, ExpressibleByStringLiteral {
        /// Exactly this string.
        case literal(String)
        /// A simulator device or runtime UDID (`8-4-4-4-12` hex digits). Never `all` or `booted`,
        /// which `simctl` would apply to every device.
        case uuid
        /// A name an inspector read from the disk or from the tool, such as a Python version or a
        /// Rust toolchain: 1 to 255 ASCII letters, digits, `.`, `_` and `-`, starting with a letter
        /// or digit. It can never be read as an option or a path.
        case name
        /// One path component, such as a Chrome profile folder name (`Profile 11`): not empty,
        /// not `.` or `..`, no `/` and no NUL.
        case pathComponent
        /// An Ollama model name such as `llama3.2:3b`, `library/qwen2.5:7b-instruct-q4_K_M` or
        /// `hf.co/org/model:Q4_K_M`: 1 to 255 ASCII letters, digits, `.`, `_`, `-`, `:` and `/`.
        /// `/` only separates segments (no leading or trailing `/`, no `//`), and every segment
        /// starts with a letter or digit, so it is never an option, `.`, `..` or an absolute path.
        case ollamaModel
        /// A Hugging Face cache repo id as `hf cache rm` takes it: `model/<org>/<name>`,
        /// `dataset/<org>/<name>`, `model/<name>` or `dataset/<name>`. `<org>` and `<name>` follow
        /// the rules of `name`. Never a revision hash or an `hf://` file URI.
        case huggingFaceRepo

        public init(stringLiteral value: String) { self = .literal(value) }

        func matches(_ value: String) -> Bool {
            switch self {
            case .literal(let expected): value == expected
            case .uuid: UUID(uuidString: value) != nil && value.count == 36
            case .name: Self.isName(value)
            case .pathComponent: !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
            case .ollamaModel: Self.isOllamaModel(value)
            case .huggingFaceRepo: Self.isHuggingFaceRepo(value)
            }
        }

        private static let letterOrDigit = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        private static let nameCharacters = letterOrDigit.union(CharacterSet(charactersIn: "._-"))

        private static func isName(_ value: String) -> Bool {
            let scalars = value.unicodeScalars
            guard let first = scalars.first, scalars.count <= 255, letterOrDigit.contains(first) else { return false }
            return scalars.allSatisfy { nameCharacters.contains($0) }
        }

        private static let ollamaCharacters = nameCharacters.union(CharacterSet(charactersIn: ":/"))

        private static func isOllamaModel(_ value: String) -> Bool {
            let scalars = value.unicodeScalars
            guard !scalars.isEmpty, scalars.count <= 255, scalars.allSatisfy({ ollamaCharacters.contains($0) }) else { return false }
            return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
                segment.unicodeScalars.first.map { letterOrDigit.contains($0) } ?? false
            }
        }

        private static func isHuggingFaceRepo(_ value: String) -> Bool {
            let segments = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard (2...3).contains(segments.count), ["model", "dataset"].contains(segments[0]) else { return false }
            return segments.dropFirst().allSatisfy(isName)
        }
    }

    /// An allowed shape of `JSONEdit`.
    public enum EditShape: Sendable, Hashable {
        case removeKey([Argument])
        case removeArrayValue(keyPath: [Argument], value: Argument)

        func matches(_ edit: JSONEdit) -> Bool {
            switch (self, edit) {
            case (.removeKey(let shape), .removeKey(let keyPath)):
                ToolPolicy.matches(shape, keyPath)
            case (.removeArrayValue(let shape, let valueShape), .removeArrayValue(let keyPath, let value)):
                ToolPolicy.matches(shape, keyPath) && valueShape.matches(value)
            default:
                false
            }
        }
    }

    /// A JSON file that `removeJSONKeys` may edit, and the edits it may make.
    public struct JSONFile: Sendable, Hashable {
        /// `~/`-relative.
        public let path: String
        public let edits: [EditShape]
    }

    // MARK: - The policy

    /// Tool name → the argument lists it may run with.
    public static let tools: [String: [[Argument]]] = [
        // DockerInspector
        "docker": [
            ["image", "prune", "-a", "-f"],
            ["container", "prune", "-f"],
            ["volume", "prune", "-a", "-f"],
            ["builder", "prune", "-a", "-f"],
        ],
        // XcodeInspector
        "xcrun": [
            ["simctl", "delete", "unavailable"],
            ["simctl", "delete", .uuid],
            ["simctl", "runtime", "delete", .uuid],
        ],
        // JSCachesInspector
        "npm": [["cache", "clean", "--force"]],
        "pnpm": [["store", "prune"]],
        "brew": [["cleanup", "--prune=all", "-s"]],
        "yarn": [["cache", "clean"]],
        "bun": [["pm", "cache", "rm"]],
        // NativeCachesInspector
        "pip3": [["cache", "purge"]],
        "go": [["clean", "-modcache"], ["clean", "-cache"]],
        "pyenv": [["uninstall", "-f", .name]],
        "rustup": [["toolchain", "uninstall", .name]],
        // AIModelsInspector: one downloaded model each.
        "ollama": [["rm", .ollamaModel]],
        "hf": [["cache", "rm", .huggingFaceRepo, "--yes"]],
    ]

    /// The JSON files that may be edited.
    public static let jsonFiles: [JSONFile] = [
        // ChromeInspector: removing one profile from Chrome's profile list.
        JSONFile(path: "~/Library/Application Support/Google/Chrome/Local State", edits: [
            .removeKey(["profile", "info_cache", .pathComponent]),
            .removeArrayValue(keyPath: ["profile", "profiles_order"], value: .pathComponent),
            .removeArrayValue(keyPath: ["profile", "last_active_profiles"], value: .pathComponent),
        ]),
    ]

    // MARK: - Checking

    private let homes: [String]

    /// `home` expands the `~/` in `jsonFiles`; its symlink-resolved form matches too.
    public init(home: URL) {
        var homes = [home.path]
        if let resolved = FileSystem.realpath(home.path), resolved != home.path { homes.append(resolved) }
        self.homes = homes
    }

    /// Nil when the action is allowed. `delete` and `trash` always are here; `PathValidator`
    /// checks them. `locate` finds a tool by name, as the engine's tool runner does.
    public func violation(for action: CleanupAction, locate: (String) -> String?) -> SafetyViolation? {
        switch action {
        case .delete, .trash:
            return nil
        case .runTool(let executable, let arguments):
            let name = executable.split(separator: "/").last.map(String.init) ?? executable
            guard let allowed = Self.tools[name],
                  locate(name) == executable,
                  allowed.contains(where: { Self.matches($0, arguments) })
            else { return .toolNotAllowed(([executable] + arguments).joined(separator: " ")) }
            return nil
        case .removeJSONKeys(let path, let edits):
            let key = PathKey(path)
            guard let file = Self.jsonFiles.first(where: { file in
                homes.contains { PathKey($0 + "/" + file.path.dropFirst(2)) == key }
            }), edits.allSatisfy({ edit in file.edits.contains { $0.matches(edit) } })
            else { return .editNotAllowed(path) }
            return nil
        }
    }

    private static func matches(_ shape: [Argument], _ values: [String]) -> Bool {
        shape.count == values.count && zip(shape, values).allSatisfy { $0.matches($1) }
    }
}
