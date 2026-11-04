import Foundation

/// The parts of Chrome's `Local State` JSON this inspector reads.
struct ChromeLocalState: Sendable {
    struct Profile: Sendable {
        let dir: String
        let name: String?
        let email: String?
        let gaiaName: String?
        let activeTime: Date?
    }

    /// Profiles from `profile.info_cache`, ordered by `profile.profiles_order` first.
    let profiles: [Profile]
    /// `profile.last_used`: the profile Chrome opens next, treated as currently active.
    let lastUsed: String?

    /// False when the file was missing, unreadable or malformed; removal must then be disabled.
    let isReadable: Bool

    static let empty = ChromeLocalState(profiles: [], lastUsed: nil, isReadable: false)

    /// Profile dir keys are used as path components; reject anything that could escape the Chrome folder.
    static func isSafeDirName(_ dir: String) -> Bool {
        !dir.isEmpty && dir != "." && dir != ".." && !dir.contains("/") && !dir.contains("\0")
    }

    /// Returns `.empty` when the file is missing or malformed.
    static func load(from url: URL) -> ChromeLocalState {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any]
        else { return .empty }

        let cache = profile["info_cache"] as? [String: Any] ?? [:]
        let order = (profile["profiles_order"] as? [String] ?? []).filter { cache[$0] != nil }
        let rest = cache.keys.filter { !order.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        let profiles = (order + rest).filter(isSafeDirName).map { dir -> Profile in
            let info = cache[dir] as? [String: Any] ?? [:]
            func text(_ key: String) -> String? {
                guard let value = info[key] as? String, !value.isEmpty else { return nil }
                return value
            }
            let seconds = (info["active_time"] as? NSNumber)?.doubleValue
            return Profile(
                dir: dir,
                name: text("name"),
                email: text("user_name"),
                gaiaName: text("gaia_name"),
                activeTime: seconds.map { Date(timeIntervalSince1970: $0) }
            )
        }
        return ChromeLocalState(profiles: profiles, lastUsed: profile["last_used"] as? String, isReadable: true)
    }

    /// Array keys of `profile` that list profile dirs and should drop a removed profile.
    static func arrayKeysContaining(_ dir: String, in url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any]
        else { return [] }
        return ["profiles_order", "last_active_profiles"].filter {
            (profile[$0] as? [Any])?.contains { ($0 as? String) == dir } == true
        }
    }
}
