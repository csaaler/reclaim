import SwiftUI
import StorageCore
import StorageInspectors

/// What views need to know about an inspector that is not in a snapshot section, looked up by
/// its id: the name to show for it. Built from the inspectors that produced the current snapshot.
/// An inspector's category travels with its `InspectorSection`.
struct InspectorDirectory: Sendable {
    let displayNames: [String: String]

    init(_ inspectors: [any Inspector]) {
        displayNames = Dictionary(inspectors.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    /// The inspector's display name, or its id when it is not known.
    func displayName(of inspectorID: String) -> String {
        displayNames[inspectorID] ?? inspectorID
    }
}

extension EnvironmentValues {
    /// Defaults to the registered inspectors, so previews work without setting it.
    @Entry var inspectorDirectory = InspectorDirectory(allInspectors)
}
