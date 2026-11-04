import Foundation
import Observation
import StorageCore

/// What the user picked for cleanup. Nothing here is deleted until the review is confirmed.
@MainActor @Observable
final class CleanupList {
    var candidates: [CleanupCandidate] = []

    /// Adds `candidate` once. Locations that are not cleanable and informational inspector items
    /// are refused here as well as in the views.
    func add(_ candidate: CleanupCandidate) {
        guard candidate.isAddable, !candidates.contains(candidate) else { return }
        candidates.append(candidate)
    }

    func remove(_ candidate: CleanupCandidate) {
        candidates.removeAll { $0 == candidate }
    }

    func removeAll() {
        candidates.removeAll()
    }

    var totalBytes: Int64 {
        candidates.reduce(0) { $0 + $1.bytes }
    }
}

extension CleanupCandidate {
    var isAddable: Bool {
        switch self {
        case .location(let location, _): location.isCleanable
        case .inspectorItem(let item): item.isActionable
        }
    }

    /// Shown next to the 🔴 acknowledgement: "I understand <whatYouLose>".
    var whatYouLose: String {
        switch self {
        case .location(let location, _):
            "\(abbreviatedPath(location.path)) will be moved to the Trash"
        case .inspectorItem(let item):
            Self.lowercasingFirstWord(item.whatYouLose.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Shown under every step row of the review, whatever the risk: what this cleanup costs
    /// (an inspector item's `whatYouLose`) or, for a location, its note.
    var lossDescription: String? {
        let text: String? = switch self {
        case .location(let location, _): location.note
        case .inspectorItem(let item): item.whatYouLose
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var displayTitle: String {
        switch self {
        case .location(let location, let appName):
            appName.isEmpty ? abbreviatedPath(location.path) : "\(appName): \(abbreviatedPath(location.path))"
        case .inspectorItem(let item):
            item.title
        }
    }

    /// "Bookmarks, history…" reads as "I understand bookmarks, history…". Acronyms ("AI") stay.
    private static func lowercasingFirstWord(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let second = text.dropFirst().first
        if let second, second.isUppercase { return text }
        return first.lowercased() + text.dropFirst()
    }
}
