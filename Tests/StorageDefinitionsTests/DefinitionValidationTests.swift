import Foundation
import Testing
import StorageCore
@testable import StorageDefinitions

@Suite struct DefinitionValidationTests {
    let home = URL(fileURLWithPath: "/Users/tester")

    func def(
        id: String = "demo",
        displayName: String = "Demo",
        bundleIDs: [String] = ["com.example.Demo"],
        processNames: [String] = ["Demo"],
        pattern: String = "~/Library/Caches/Demo",
        kind: LocationKind = .cache,
        note: String = "Demo cache; rebuilt automatically",
        locations: [DefinedLocation]? = nil,
        mustQuit: Bool = true,
        sideEffectNote: String? = nil
    ) -> AppDefinition {
        AppDefinition(
            id: id, displayName: displayName, bundleIDs: bundleIDs, processNames: processNames,
            locations: locations ?? [DefinedLocation(pattern: pattern, kind: kind, note: note)],
            mustQuitBeforeCleaning: mustQuit, sideEffectNote: sideEffectNote)
    }

    func problems(_ defs: AppDefinition...) -> [String] {
        DefinitionValidator.problems(in: defs, home: home)
    }

    // MARK: - Shipped definitions

    @Test func shippedDefinitionsAreRegistered() {
        #expect(!allDefinitions.isEmpty)
    }

    /// One entry per line, sorted by id, so parallel pull requests rarely touch the same line.
    @Test func shippedDefinitionsAreSortedByID() {
        let ids = allDefinitions.map(\.id)
        #expect(ids == ids.sorted())
    }

    @Test func shippedDefinitionsPassTheValidator() {
        #expect(DefinitionValidator.problems(in: allDefinitions, home: home) == [])
    }

    @Test func aValidDefinitionHasNoProblems() {
        #expect(problems(def()) == [])
    }

    // MARK: - Identity

    @Test func rejectsDuplicateID() {
        let found = problems(def(pattern: "~/Library/Caches/A"), def(pattern: "~/Library/Caches/B"))
        #expect(found == ["demo: duplicate id"])
    }

    @Test(arguments: ["Bad_Id", "Demo", "-demo", "demo-", "de--mo", "", "démo", "de mo"])
    func rejectsNonKebabCaseID(_ id: String) {
        #expect(problems(def(id: id)).contains { $0.contains("kebab-case") })
    }

    @Test(arguments: ["demo", "demo-app", "app2", "1password"])
    func acceptsKebabCaseID(_ id: String) {
        #expect(problems(def(id: id)) == [])
    }

    @Test(arguments: ["", "   "])
    func rejectsEmptyDisplayName(_ name: String) {
        #expect(problems(def(displayName: name)) == ["demo: empty displayName"])
    }

    @Test func rejectsDefinitionWithoutBundleIDsOrProcessNames() {
        let found = problems(def(bundleIDs: [], processNames: []))
        #expect(found.count == 1)
        #expect(found.first?.contains("bundle ID or process name") == true)
    }

    @Test func rejectsMissingIdentifiersEvenWhenQuitIsNotRequired() {
        #expect(problems(def(bundleIDs: [], processNames: [], mustQuit: false)).count == 1)
    }

    @Test func acceptsProcessNameAlone() {
        #expect(problems(def(bundleIDs: [])) == [])
    }

    @Test func acceptsBundleIDAlone() {
        #expect(problems(def(processNames: [])) == [])
    }

    @Test func rejectsBlankProcessName() {
        #expect(problems(def(processNames: ["Demo", " "])) == ["demo: blank process name"])
    }

    @Test(arguments: ["", "Demo", "com.example.Demo App", ".com.example", "com..example", "com.example."])
    func rejectsMalformedBundleID(_ bundleID: String) {
        #expect(problems(def(bundleIDs: [bundleID])).contains { $0.contains("bundle ID") })
    }

    @Test(arguments: ["com.example.Demo", "notion.id", "com.todesktop.230313mzl4w4u92", "com.example.demo-app"])
    func acceptsReverseDNSBundleID(_ bundleID: String) {
        #expect(problems(def(bundleIDs: [bundleID])) == [])
    }

    @Test func rejectsEmptySideEffectNote() {
        #expect(problems(def(sideEffectNote: " ")) == ["demo: sideEffectNote is empty; omit it instead"])
    }

    // MARK: - Locations

    @Test func rejectsDefinitionWithoutLocations() {
        #expect(problems(def(locations: [])) == ["demo: no locations"])
    }

    @Test func rejectsMissingNote() {
        #expect(problems(def(note: "")) == ["demo: empty note for ~/Library/Caches/Demo"])
        #expect(problems(def(note: "  \n")).count == 1)
    }

    @Test func rejectsAbsolutePattern() {
        #expect(problems(def(pattern: "/Library/Caches/Foo")) == ["demo: pattern must start with ~/: /Library/Caches/Foo"])
    }

    @Test func keepsCheckingAfterBadPrefix() {
        #expect(problems(def(pattern: "/x", note: "")).count == 2)
    }

    @Test(arguments: [
        "~/Library/Caches/Demo/../Other", "~/Library/Caches/./Demo", "~/Library//Caches/Demo",
        "~/Library/Caches/Demo/", "~/Library/Caches/**/Demo",
    ])
    func rejectsMalformedPattern(_ pattern: String) {
        #expect(problems(def(pattern: pattern)).contains { $0.contains("malformed pattern") })
    }

    @Test(arguments: ["~/*/Demo", "~/Library/*/Demo", "~/Library/Caches/*", "~/Library/Application Support/Demo*"])
    func rejectsWildcardInFirstThreeSegments(_ pattern: String) {
        #expect(problems(def(pattern: pattern)).contains { $0.contains("wildcard in the first three segments") })
    }

    @Test func acceptsWildcardDeeperDown() {
        #expect(problems(def(pattern: "~/Library/Application Support/Demo/*.log", kind: .logs)) == [])
    }

    @Test(arguments: [
        "~/Library/Caches", "~/Library/Logs", "~/Library/Application Support", "~/Library/Containers",
        "~/Library/Group Containers", "~/Library/Developer", "~/library/caches",
    ])
    func rejectsStructuralFolder(_ pattern: String) {
        #expect(problems(def(pattern: pattern)).contains { $0.contains("structural folder") })
    }

    @Test func rejectsDuplicatePatternWithinDefinition() {
        let location = DefinedLocation(pattern: "~/Library/Caches/Demo", kind: .cache, note: "Cache")
        #expect(problems(def(locations: [location, location])) == ["demo: duplicate pattern ~/Library/Caches/Demo"])
    }

    @Test func rejectsPatternClaimedByAnotherDefinition() {
        let found = problems(def(id: "one"), def(id: "two", pattern: "~/library/caches/demo"))
        #expect(found == ["two: pattern ~/library/caches/demo is already listed by one"])
    }

    // MARK: - Protected paths

    @Test(arguments: [
        "~/Library/Keychains/Demo", "~/Library/Keychains", "~/Library/Messages/Attachments",
        "~/Library/Mobile Documents/com~apple~CloudDocs", "~/Library/Preferences/com.example.Demo.plist",
    ])
    func rejectsProtectedPattern(_ pattern: String) {
        #expect(problems(def(pattern: pattern)).contains { $0.contains("touches protected path") })
    }

    @Test func rejectsAncestorOfProtectedPath() {
        #expect(problems(def(pattern: "~/Library")).contains { $0.contains("touches protected path") })
    }

    @Test func rejectsDotDotIntoProtectedPath() {
        let found = problems(def(pattern: "~/Library/Caches/../Keychains"))
        #expect(found.contains { $0.contains("malformed pattern") })
        #expect(found.contains { $0.contains("touches protected path") })
    }

    // MARK: - Scope

    @Test(arguments: [
        "~/Documents", "~/Desktop", "~/Downloads", "~/Pictures", "~/Music", "~/Movies",
        "~/Applications", "~/Public", "~/Documents/Demo", "~/Projects/demo/build",
    ])
    func rejectsPatternOutsideLibraryAndDotFolders(_ pattern: String) {
        #expect(problems(def(pattern: pattern)).contains { $0.contains("must start with ~/Library/ or a dot-folder") })
    }

    @Test(arguments: ["~/.demo/cache", "~/.cache/demo", "~/Library/Caches/Demo", "~/library/caches/demo2"])
    func acceptsPatternUnderLibraryOrDotFolder(_ pattern: String) {
        #expect(problems(def(pattern: pattern)) == [])
    }

    @Test func rejectsBareDotOrDotDotFirstSegmentAsMalformedOnly() {
        #expect(!problems(def(pattern: "~/../Demo")).contains { $0.contains("dot-folder") })
    }

    @Test(arguments: [
        "~/Library/Application Support/Demo", "~/Library/Containers/com.example.Demo",
        "~/Library/Group Containers/group.com.example.Demo", "~/library/application support/Demo",
    ])
    func rejectsWholeAppFolderBelowUserData(_ pattern: String) {
        for kind in [LocationKind.cache, .logs, .rebuildable] {
            #expect(problems(def(pattern: pattern, kind: kind)).contains { $0.contains("whole app folder") })
        }
    }

    @Test(arguments: [
        "~/Library/Application Support/Demo", "~/Library/Containers/com.example.Demo",
        "~/Library/Group Containers/group.com.example.Demo",
    ])
    func acceptsWholeAppFolderAsUserData(_ pattern: String) {
        #expect(problems(def(pattern: pattern, kind: .userData)) == [])
        #expect(problems(def(pattern: pattern, kind: .config)) == [])
    }

    @Test(arguments: [
        "~/Library/Application Support/Demo/Cache", "~/Library/Containers/com.example.Demo/Data",
        "~/Library/Group Containers/group.com.example.Demo/Cache",
    ])
    func acceptsFolderInsideAnAppFolderAsCache(_ pattern: String) {
        #expect(problems(def(pattern: pattern)) == [])
    }

    @Test func acceptsThreeSegmentCacheOutsideAppFolderParents() {
        #expect(problems(def(pattern: "~/Library/Logs/Demo", kind: .logs)) == [])
    }

    @Test(arguments: [
        "~/Library/Fonts", "~/Library/LaunchAgents", "~/Library/Saved Application State", "~/.config", "~/.aws",
        "~/.kube", "~/.docker",
    ])
    func rejectsTopLevelFolderBelowUserData(_ pattern: String) {
        for kind in [LocationKind.cache, .logs, .rebuildable] {
            #expect(problems(def(pattern: pattern, kind: kind)).contains { $0.contains("too broad") }, "\(pattern)")
        }
    }

    @Test(arguments: ["~/.demo", "~/Library/Demo"])
    func acceptsTopLevelFolderAsUserData(_ pattern: String) {
        #expect(problems(def(pattern: pattern, kind: .userData)) == [])
    }

    @Test(arguments: [
        "~/Library/Application Support/Demo/*", "~/Library/Containers/com.example.Demo/*",
        "~/Library/Group Containers/group.com.example.Demo/*", "~/library/application support/Demo/*",
    ])
    func rejectsWildcardOverAWholeAppFolderBelowUserData(_ pattern: String) {
        for kind in [LocationKind.cache, .logs, .rebuildable] {
            #expect(problems(def(pattern: pattern, kind: kind)).contains { $0.contains("whole app folder") })
        }
        #expect(problems(def(pattern: pattern, kind: .userData)) == [])
    }

    @Test(arguments: ["~/Library/Caches/Demo/*", "~/Library/Application Support/Demo/*/Cache"])
    func acceptsWildcardFourthSegmentElsewhere(_ pattern: String) {
        #expect(problems(def(pattern: pattern)) == [])
    }

    @Test(arguments: ["~/.Trash", "~/.Trash/Demo", "~/.trash/demo/*"])
    func rejectsTrash(_ pattern: String) {
        for kind in [LocationKind.cache, .userData] {
            #expect(problems(def(pattern: pattern, kind: kind)).contains { $0.contains("touches protected path") })
        }
    }

    @Test func acceptsOrdinaryCacheFolder() {
        #expect(problems(def(pattern: "~/Library/Caches/Foo")) == [])
    }
}
