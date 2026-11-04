import Foundation
import StorageCore
import StorageInspectors

/// The inspectors the app runs, configured from the user's settings, and the one tool lookup
/// they share.
///
/// Scanning, cleanup planning and the cleanup engine all take their inspectors and tools from an
/// `InspectorSetup`. That keeps two things in line:
/// - an item is planned by an inspector configured the same way as the one that found it;
/// - a tool path an inspector put into a `runTool` step is the path the engine's `ToolPolicy`
///   accepts, because the policy, the runner and the inspectors all search the same directories
///   (the built-in ones plus every inspector's `toolSearchDirectories`).
struct InspectorSetup: Sendable {
    /// UserDefaults key for the project folders searched by the project-builds inspector.
    static let codeRootsKey = "codeRoots"

    let home: URL
    let codeRoots: [String]
    let inspectors: [any Inspector]
    let toolLocator: ToolLocator

    init(home: URL, codeRoots: [String]) {
        self.home = home
        self.codeRoots = codeRoots
        let inspectors = configuredInspectors(codeRoots: codeRoots)
        self.inspectors = inspectors
        self.toolLocator = ToolLocator(home: home, inspectors: inspectors)
    }

    /// Reads the code roots from `defaults` now; unset means the inspector's defaults.
    static func current(home: URL, defaults: UserDefaults = .standard) -> InspectorSetup {
        InspectorSetup(
            home: home,
            codeRoots: defaults.stringArray(forKey: codeRootsKey) ?? ProjectBuildsInspector.defaultRoots)
    }

    /// A runner that finds tools with this setup's locator.
    func toolRunner() -> ProcessToolRunner {
        ProcessToolRunner(locator: toolLocator)
    }

    var directory: InspectorDirectory {
        InspectorDirectory(inspectors)
    }
}
