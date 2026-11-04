import Foundation
import StorageCore

/// Home-relative display form of a path ("~/Library/..."). Paths outside `home` stay absolute.
func abbreviatedPath(_ path: String, home: String = NSHomeDirectory()) -> String {
    CleanupPlanner.displayPath(path, home: URL(fileURLWithPath: home))
}

extension AttributedLocation {
    var isCleanable: Bool { cleanability == .cleanable }

    /// Why this location has no add button, or nil when it is cleanable.
    func cleanabilityReason(in inspectors: InspectorDirectory) -> String? {
        switch cleanability {
        case .cleanable: nil
        case .viewOnly(let reason): "View only: \(reason)"
        case .protected: "Protected"
        case .claimed(let id): "Managed by \(inspectors.displayName(of: id)) inspector"
        }
    }
}
