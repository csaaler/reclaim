import Testing
import StorageCore

@Suite struct SampleSnapshotTests {
    @Test func sampleCoversWhatTheUINeeds() {
        let sample = StorageSnapshot.sample
        let gb: Int64 = 1_000_000_000
        #expect(sample.volume.totalBytes == 500 * gb)
        #expect(sample.volume.usedBytes == 400 * gb)
        #expect(sample.volume.availableBytes == 100 * gb)

        let locations = sample.apps.flatMap(\.locations)
        #expect(Set(locations.map(\.risk)) == Set(RiskLevel.allCases))
        #expect(sample.apps.contains { $0.isOrphan })
        #expect(locations.contains { $0.cleanability == .protected })
        #expect(locations.contains { if case .claimed = $0.cleanability { true } else { false } })
        #expect(locations.contains { if case .viewOnly = $0.cleanability { true } else { false } })
        #expect(sample.inspectors.contains { $0.unavailableReason != nil })
        #expect(sample.unaccounted.map(\.kind) == [.unreadable, .systemVolume, .purgeable, .notExplained])
        #expect(!sample.scan.largeFiles.isEmpty)
        for app in sample.apps {
            #expect(app.locations.map(\.allocatedBytes) == app.locations.map(\.allocatedBytes).sorted(by: >))
        }
    }

    @Test func categoriesPlusUnaccountedMatchUsedBytes() {
        let sample = StorageSnapshot.sample
        let total = sample.categories.reduce(0) { $0 + $1.bytes } + sample.unaccounted.reduce(0) { $0 + $1.bytes }
        let used = sample.volume.usedBytes
        #expect(abs(total - used) <= used / 100)
        #expect(sample.categories.first { $0.category == .other }.map { $0.bytes > 0 } == true)
    }

    @Test func mailTreeNodeMatchesProtectedLocation() throws {
        let scan = StorageSnapshot.sample.scan
        let mail = try #require(scan.summary(at: scan.root.path + "/Library/Mail"))
        #expect(!mail.isUnreadable)
        #expect(mail.allocatedBytes == 2_000_000_000)
        #expect(!scan.unreadablePaths.isEmpty)
        #expect(!scan.unreadablePaths.contains(mail.path))
    }

    @Test func summaryWalksTheTree() throws {
        let scan = StorageSnapshot.sample.scan
        let library = try #require(scan.summary(at: scan.root.path + "/Library"))
        let caches = try #require(library.children.first { $0.path.hasSuffix("/Caches") })
        #expect(scan.summary(at: caches.path)?.allocatedBytes == caches.allocatedBytes)
        #expect(scan.summary(at: "/nowhere") == nil)
    }
}
