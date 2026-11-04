import Foundation
import Testing
import StorageCore
import StorageTestKit

@Suite struct PathPatternTests {
    @Test func expandMatchesWildcardWithinSegment() throws {
        let fixture = try FixtureHome()
        try fixture.dir("Library/Caches/com.a.ShipIt")
        try fixture.dir("Library/Caches/com.b.ShipIt")
        try fixture.dir("Library/Caches/other")

        let paths = PathPattern.expand("~/Library/Caches/*.ShipIt", home: fixture.home)

        let caches = fixture.home.path + "/Library/Caches"
        #expect(paths == [caches + "/com.a.ShipIt", caches + "/com.b.ShipIt"])
    }

    @Test func expandReturnsNothingForMissingLiteralPath() throws {
        let fixture = try FixtureHome()
        #expect(PathPattern.expand("~/.gradle/caches", home: fixture.home).isEmpty)
    }

    @Test func expandAbsolutePatternAsIs() throws {
        let fixture = try FixtureHome()
        try fixture.dir("x/a")
        let paths = PathPattern.expand(fixture.home.path + "/x/*", home: URL(fileURLWithPath: "/nonexistent"))
        #expect(paths == [fixture.home.path + "/x/a"])
    }

    @Test func matchesWildcardSegmentExactly() {
        let home = URL(fileURLWithPath: "/Users/me")
        let pattern = "~/Library/Application Support/*/Cache"
        #expect(PathPattern.matches(pattern, path: home.path + "/Library/Application Support/Slack/Cache", home: home))
        #expect(!PathPattern.matches(pattern, path: home.path + "/Library/Application Support/Slack/Cache/x", home: home))
    }

    @Test func relativePatternMatchesTrailingSegment() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(PathPattern.matches("*.photoslibrary", path: "/Users/me/Pictures/Photos Library.photoslibrary", home: home))
        #expect(!PathPattern.matches("*.photoslibrary", path: "/Users/me/Pictures/Photos Library.photoslibrary/x", home: home))
    }

    // MARK: - Pattern overlap

    @Test(arguments: [
        ("~/Library/Caches/Demo", "~/Library/Caches/Demo"),
        ("~/Library/Caches/Demo", "~/Library/Caches/Demo/sub"),
        ("~/Library/Caches/Demo/sub", "~/Library/Caches/*"),
        ("~/Library/*", "~/Library/Caches/Demo"),
        ("~/*", "~/.npm/_cacache"),
        ("~/Library/Caches/*.ShipIt", "~/Library/Caches/com.example*"),
        ("~/Library/Caches/a*b", "~/Library/Caches/*ab*"),
        ("~/library/caches/DEMO", "~/Library/Caches/demo"),
        ("/Users/sample/Library/Caches/Demo", "~/Library/Caches/*"),
    ])
    func patternsOverlap(_ a: String, _ b: String) {
        let home = URL(fileURLWithPath: "/Users/sample")
        #expect(PathPattern.overlaps(a, b, home: home))
        #expect(PathPattern.overlaps(b, a, home: home))
    }

    @Test(arguments: [
        ("~/Library/Caches/Demo", "~/Library/Caches/Other"),
        ("~/Library/Caches/*.ShipIt", "~/Library/Caches/*-updater"),
        ("~/Library/Caches/a*", "~/Library/Caches/b*"),
        ("~/Library/Caches/*x", "~/Library/Caches/*y"),
        ("~/Library/Caches/Demo", "/Library/Caches/Demo"),
        ("~/Library/Caches/Demo", "*.photoslibrary"),
    ])
    func patternsDoNotOverlap(_ a: String, _ b: String) {
        let home = URL(fileURLWithPath: "/Users/sample")
        #expect(!PathPattern.overlaps(a, b, home: home))
        #expect(!PathPattern.overlaps(b, a, home: home))
    }
}
