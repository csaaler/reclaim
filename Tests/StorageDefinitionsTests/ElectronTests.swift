import Testing
import StorageCore
@testable import StorageDefinitions

@Suite struct ElectronTests {
    @Test func electronGeneratesCaches() {
        let d = AppDefinition.electron(id: "slack", displayName: "Slack", bundleIDs: ["x"],
                                       processNames: ["Slack"], supportFolder: "Slack")
        let code = d.locations.first { $0.pattern == "~/Library/Application Support/Slack/Code Cache" }
        #expect(code?.kind == .cache)
        #expect(code?.note == "Chromium cache; rebuilt automatically")
        #expect(d.locations.count == AppDefinition.electronCacheFolders.count)
        #expect(d.locations.contains { $0.pattern.hasSuffix("Service Worker/CacheStorage") })
    }

    @Test func extraLocationsAreAppended() {
        let extra = DefinedLocation(pattern: "~/Library/Application Support/X/big", kind: .rebuildable, note: "n")
        let d = AppDefinition.electron(id: "x", displayName: "X", bundleIDs: [], processNames: [],
                                       supportFolder: "X", extraLocations: [extra], sideEffectNote: "s")
        #expect(d.locations.last?.pattern == extra.pattern)
        #expect(d.sideEffectNote == "s")
    }
}
