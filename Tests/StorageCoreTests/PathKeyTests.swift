import Testing
import StorageCore

@Suite struct PathKeyTests {
    @Test func insideIsCaseInsensitive() {
        #expect(PathKey("/Users/a/Library/Keychains/x").isInside(PathKey("/users/A/library/KEYCHAINS")))
    }

    @Test func standardizesDotDotAndTrailingSlash() {
        #expect(PathKey("/a/b/../c/").raw == "/a/c")
        #expect(PathKey("//a//b/./c").raw == "/a/b/c")
    }

    @Test func nfdAndNfcAreTheSameKey() {
        let nfd = PathKey("/Caf\u{0065}\u{0301}")
        let nfc = PathKey("/Caf\u{00E9}")
        #expect(nfd.isSame(as: nfc))
        #expect(nfd == nfc)
    }

    @Test func insideIsStrictAndSegmentAware() {
        #expect(!PathKey("/a/bc").isInside(PathKey("/a/b")))
        #expect(!PathKey("/a/b").isInside(PathKey("/a/b")))
        #expect(PathKey("/a/b/c").isInside(PathKey("/")))
    }
}
