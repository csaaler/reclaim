import Foundation

/// Read-only, bounded directory helpers for `AIModelsInspector`. Nothing here follows a symlink.
enum AIModelsFiles {
    /// The most entries read from one directory.
    static let maxEntries = 10_000

    enum Kind { case directory, regularFile, symlink, other }

    /// The type of the item itself (`lstat`), never of a symlink's target.
    static func kind(_ path: String) -> Kind? {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else {
            return nil
        }
        switch type {
        case .typeDirectory: return .directory
        case .typeRegular: return .regularFile
        case .typeSymbolicLink: return .symlink
        default: return .other
        }
    }

    /// Visible entries of `path` of the given kind, sorted. Hidden names, symlinks and anything
    /// past `maxEntries` are left out.
    static func entries(_ path: String, kind wanted: Kind) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.sorted().prefix(maxEntries).filter { name in
            !name.hasPrefix(".") && kind(path + "/" + name) == wanted
        }
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func size(_ path: String) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
    }

    /// The symlink-resolved form of `path`, or nil when it does not exist.
    static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
