import Foundation
import StorageCore

/// Static checks over app definitions. `DefinitionValidationTests` runs them over every shipped
/// definition, so a definition that breaks a rule fails CI with a readable message.
///
/// Rules:
/// - `id` is unique and lowercase kebab-case; `displayName` is not empty.
/// - At least one bundle ID or process name, so the running-app check can find the app. Bundle
///   IDs are reverse-DNS (`com.example.App`); no identifier is blank.
/// - At least one location; `sideEffectNote`, when given, is not empty.
/// - Every pattern starts with `~/`, has no empty, `.` or `..` segment, no trailing `/` and no
///   `**`, has no `*` in its first three segments, is not a structural folder such as
///   `~/Library/Caches`, and is listed only once across all definitions.
/// - Every pattern lies under `~/Library/` or a dot-folder such as `~/.demo`, never in a user
///   folder such as `~/Documents`.
/// - A 🟢 or 🟡 pattern has at least three segments under `~/Library` (`~/Library/Caches/<App>`)
///   and at least two under a dot-folder (`~/.demo/cache`); only 🔴 may name `~/Library/<Folder>`
///   or `~/.demo` itself.
/// - A pattern for a whole app folder (`~/Library/Application Support/<App>`,
///   `~/Library/Containers/<ID>` or `~/Library/Group Containers/<ID>`, or the same with a lone
///   `/*` after it) is 🔴 (`.userData` or `.config`); 🟢 and 🟡 locations must name a folder
///   inside it.
/// - Every location has a note.
/// - No pattern equals, lies inside, or contains a protected path.
public enum DefinitionValidator {
    public static func problems(in defs: [AppDefinition], home: URL) -> [String] {
        var problems: [String] = []
        var seenIDs = Set<String>()
        var patternOwners: [PathKey: String] = [:]
        let protected = ProtectedPaths(home: home)
        let structural = Set(PathValidator.structuralFolders(home: home).map(PathKey.init))

        for def in defs {
            if !seenIDs.insert(def.id).inserted {
                problems.append("\(def.id): duplicate id")
            }
            if !Identifier.isKebabCase(def.id) {
                problems.append("\(def.id): id is not lowercase kebab-case")
            }
            if Identifier.isBlank(def.displayName) {
                problems.append("\(def.id): empty displayName")
            }
            problems += identifierProblems(def)
            if let note = def.sideEffectNote, Identifier.isBlank(note) {
                problems.append("\(def.id): sideEffectNote is empty; omit it instead")
            }
            if def.locations.isEmpty {
                problems.append("\(def.id): no locations")
            }

            for location in def.locations {
                let pattern = location.pattern
                if Identifier.isBlank(location.note) {
                    problems.append("\(def.id): empty note for \(pattern)")
                }
                guard pattern.hasPrefix("~/") else {
                    problems.append("\(def.id): pattern must start with ~/: \(pattern)")
                    continue
                }
                let segments = pattern.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
                if segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("**") }) {
                    problems.append(
                        "\(def.id): malformed pattern \(pattern) (empty, . or .. segment, trailing / or **)")
                }
                problems += scopeProblems(def.id, location: location, segments: segments)
                if segments.prefix(3).contains(where: { $0.contains("*") }) {
                    problems.append("\(def.id): pattern \(pattern) has a wildcard in the first three segments")
                }
                let key = PathKey(home.path + "/" + pattern.dropFirst(2))
                if structural.contains(key) {
                    problems.append("\(def.id): pattern \(pattern) is a structural folder and can never be cleaned")
                }
                if let owner = patternOwners[key] {
                    problems.append(owner == def.id
                        ? "\(def.id): duplicate pattern \(pattern)"
                        : "\(def.id): pattern \(pattern) is already listed by \(owner)")
                } else {
                    patternOwners[key] = def.id
                }
                if let entry = protected.overlaps(pattern: pattern) {
                    problems.append("\(def.id): pattern \(pattern) touches protected path \(entry)")
                }
            }
        }
        return problems
    }

    /// Parents whose direct children are whole app folders.
    private static let appFolderParents: Set<String> = ["application support", "containers", "group containers"]

    private static func scopeProblems(
        _ id: String, location: DefinedLocation, segments: [Substring]
    ) -> [String] {
        // An empty, `.` or `..` first segment is already reported as malformed.
        guard let first = segments.first?.lowercased(), !first.isEmpty, first != ".", first != ".." else {
            return []
        }
        guard first == "library" || first.hasPrefix(".") else {
            return ["\(id): pattern \(location.pattern) must start with ~/Library/ or a dot-folder (~/.name)"]
        }
        guard location.kind.risk != .userData else { return [] }
        // 🟢 and 🟡 locations name a folder that belongs to one app, never a shared top-level one
        // such as `~/Library/Fonts` or `~/.config`.
        let minimumDepth = first == "library" ? 3 : 2
        if segments.count < minimumDepth {
            let shape = first == "library" ? "~/Library/<Folder>/<App>" : "~/.<tool>/<Folder>"
            return ["\(id): pattern \(location.pattern) is too broad; a 🟢 or 🟡 location names at least \(shape)"]
        }
        // `<parent>/<App>` and `<parent>/<App>/*` both cover the whole app folder.
        if first == "library", appFolderParents.contains(segments[1].lowercased()),
           segments.count == 3 || (segments.count == 4 && segments[3] == "*") {
            return ["\(id): pattern \(location.pattern) covers a whole app folder; only a 🔴 location (userData or config) may"]
        }
        return []
    }

    private static func identifierProblems(_ def: AppDefinition) -> [String] {
        var problems: [String] = []
        if def.bundleIDs.isEmpty && def.processNames.isEmpty {
            problems.append(
                "\(def.id): needs at least one bundle ID or process name; without one the running-app check never finds the app")
        }
        for bundleID in def.bundleIDs where !Identifier.isReverseDNS(bundleID) {
            problems.append("\(def.id): bundle ID \"\(bundleID)\" is not reverse-DNS (com.example.App)")
        }
        if def.processNames.contains(where: Identifier.isBlank) {
            problems.append("\(def.id): blank process name")
        }
        return problems
    }
}
