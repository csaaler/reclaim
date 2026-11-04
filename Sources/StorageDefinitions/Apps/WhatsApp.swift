import StorageCore

extension AppDefinition {
    // The group containers hold the chat databases and media (chat history), so they are user data.
    // Their Library/Caches is already covered by the generic location rules.
    static let whatsapp = AppDefinition(
        id: "whatsapp",
        displayName: "WhatsApp",
        bundleIDs: ["net.whatsapp.WhatsApp"],
        processNames: ["WhatsApp"],
        locations: [
            DefinedLocation(
                pattern: "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared",
                kind: .userData,
                note: "Chat history and media"
            ),
            DefinedLocation(
                pattern: "~/Library/Group Containers/group.net.whatsapp.WhatsApp.private",
                kind: .userData,
                note: "Chat history and account data"
            ),
            DefinedLocation(
                pattern: "~/Library/Group Containers/group.net.whatsapp.family",
                kind: .userData,
                note: "Shared account data"
            ),
        ]
    )
}
