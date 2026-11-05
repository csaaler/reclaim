import StorageCore

/// Every built-in inspector, with default configuration. One entry per line.
public let allInspectors: [any Inspector] = [
    ChromeInspector(),
    DockerInspector(),
    XcodeInspector(),
    AndroidInspector(),
    JetBrainsInspector(),
    JSCachesInspector(),
    NativeCachesInspector(),
    ProjectBuildsInspector(),
    UpdaterLeftoversInspector(),
    AIModelsInspector(),
]

/// `allInspectors` with user settings applied: `ProjectBuildsInspector` searches `codeRoots`
/// (`PathPattern` syntax, e.g. `~/git`). Scanning and planning should both use this list, so
/// items are always planned by an inspector configured the same way as the one that found them.
public func configuredInspectors(codeRoots: [String]) -> [any Inspector] {
    allInspectors.map { inspector in
        inspector is ProjectBuildsInspector ? ProjectBuildsInspector(codeRoots: codeRoots) : inspector
    }
}
