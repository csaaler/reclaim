import Foundation

public struct ToolLocator: Sendable {
    private let directoryPatterns: [String]
    private let home: URL

    /// - Parameters:
    ///   - home: base for the `~`-relative search directories.
    ///   - extraDirectories: searched after the built-in directories; `~/` expands to `home`.
    ///   - systemDirectories: absolute directories searched first; override in tests.
    public init(
        home: URL,
        extraDirectories: [String] = [],
        systemDirectories: [String] = ToolLocator.defaultSystemDirectories
    ) {
        self.home = home
        let h = home.path
        let patterns =
            systemDirectories + [
                "\(h)/.cargo/bin",
                "\(h)/go/bin",
                "\(h)/.pyenv/bin",
                "\(h)/.local/bin",
                "\(h)/.nvm/versions/node/*/bin",
                "\(h)/Library/Android/sdk/cmdline-tools/latest/bin",
                "\(h)/Library/Android/sdk/platform-tools",
                "/Applications/Docker.app/Contents/Resources/bin",
            ] + extraDirectories.map { $0.hasPrefix("~/") ? h + "/" + $0.dropFirst(2) : $0 }
        var seen = Set<String>()
        self.directoryPatterns = patterns.filter { seen.insert($0).inserted }
    }

    /// Searches the built-in directories plus every inspector's `toolSearchDirectories`.
    public init(
        home: URL,
        inspectors: [any Inspector],
        systemDirectories: [String] = ToolLocator.defaultSystemDirectories
    ) {
        self.init(
            home: home,
            extraDirectories: inspectors.flatMap(\.toolSearchDirectories),
            systemDirectories: systemDirectories)
    }

    public static let defaultSystemDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
    ]

    /// Concrete search directories in priority order (nvm wildcard expanded, newest first).
    public var directories: [String] {
        directoryPatterns.flatMap { pattern -> [String] in
            guard pattern.contains("*") else { return [pattern] }
            return Self.expandNodeVersions(pattern)
        }
    }

    public func locate(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let fm = FileManager.default
        for dir in directories {
            let candidate = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue,
                fm.isExecutableFile(atPath: candidate)
            else { continue }
            return candidate
        }
        return nil
    }

    private static func expandNodeVersions(_ pattern: String) -> [String] {
        let parts = pattern.components(separatedBy: "/*")
        guard parts.count == 2 else { return [] }
        let base = parts[0], suffix = parts[1]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        return names
            .sorted { versionLess($1, $0) }
            .map { "\(base)/\($0)\(suffix)" }
    }

    private static func versionLess(_ a: String, _ b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop(while: { $0 == "v" }).split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}
