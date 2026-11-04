import StorageCore

extension AppDefinition {
    /// Chromium cache folders under `~/Library/Application Support/<supportFolder>/`.
    static let electronCacheFolders = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache", "Crashpad",
    ]

    /// Definition for an Electron app: the standard Chromium cache folders plus `extraLocations`.
    public static func electron(
        id: String,
        displayName: String,
        bundleIDs: [String],
        processNames: [String],
        supportFolder: String,
        extraLocations: [DefinedLocation] = [],
        sideEffectNote: String? = nil
    ) -> AppDefinition {
        let caches = electronCacheFolders.map {
            DefinedLocation(
                pattern: "~/Library/Application Support/\(supportFolder)/\($0)",
                kind: .cache,
                note: "Chromium cache; rebuilt automatically"
            )
        }
        return AppDefinition(
            id: id,
            displayName: displayName,
            bundleIDs: bundleIDs,
            processNames: processNames,
            locations: caches + extraLocations,
            sideEffectNote: sideEffectNote
        )
    }
}
