import StorageCore

extension AppDefinition {
    // The group container holds the account database and chat media (chat history), so it is user data.
    // Its Library/Caches is already covered by the generic location rules.
    static let telegram = AppDefinition(
        id: "telegram",
        displayName: "Telegram",
        bundleIDs: ["ru.keepcoder.Telegram"],
        processNames: ["Telegram"],
        locations: [
            DefinedLocation(
                pattern: "~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable",
                kind: .userData,
                note: "Chat history and media"
            ),
            DefinedLocation(
                pattern: "~/Library/Application Support/ru.keepcoder.Telegram",
                kind: .userData,
                note: "Chat history and account data"
            ),
        ]
    )
}
