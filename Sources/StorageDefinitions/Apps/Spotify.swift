import StorageCore

extension AppDefinition {
    static let spotify = AppDefinition(
        id: "spotify",
        displayName: "Spotify",
        bundleIDs: ["com.spotify.client"],
        processNames: ["Spotify"],
        locations: [
            DefinedLocation(
                pattern: "~/Library/Application Support/Spotify/PersistentCache",
                kind: .cache,
                note: "Streaming and offline cache; rebuilt automatically"
            ),
        ]
    )
}
