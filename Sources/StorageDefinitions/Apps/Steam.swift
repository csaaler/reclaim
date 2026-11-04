import StorageCore

extension AppDefinition {
    static let steam = AppDefinition(
        id: "steam",
        displayName: "Steam",
        bundleIDs: ["com.valvesoftware.steam"],
        processNames: ["steam_osx"],
        locations: [
            DefinedLocation(
                pattern: "~/Library/Application Support/Steam/steamapps",
                kind: .rebuildable,
                note: "Installed games; re-download from Steam. Some games keep save files in their install folder — check before removing"
            ),
            DefinedLocation(
                pattern: "~/Library/Application Support/Steam/appcache",
                kind: .cache,
                note: "Steam client cache; rebuilt automatically"
            ),
            DefinedLocation(
                pattern: "~/Library/Application Support/Steam/depotcache",
                kind: .cache,
                note: "Download manifest cache; rebuilt automatically"
            ),
        ]
    )
}
