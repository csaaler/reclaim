import Foundation
import Testing
import StorageCore
import StorageTestKit
@testable import StorageInspectors

@Suite("AndroidInspector")
struct AndroidInspectorTests {
    let procs = ["qemu-system-aarch64", "qemu-system-x86_64", "emulator"]

    func context(_ fixture: FixtureHome) -> InspectorContext {
        InspectorContext(home: fixture.home, tools: FakeToolRunner(), sizer: LogicalSizer(), now: Date())
    }

    func makeAVD(_ f: FixtureHome, _ name: String, display: String, sysdir: String, spaced: Bool) throws {
        let sep = spaced ? " = " : "="
        try f.file(".android/avd/\(name).avd/config.ini", bytes: 10)
        let ini = ".android/avd/\(name).avd/config.ini"
        let text = "avd.ini.displayname\(sep)\(display)\nimage.sysdir.1\(sep)\(sysdir)\n"
        try text.write(to: f.home.appendingPathComponent(ini), atomically: true, encoding: .utf8)
        try f.file(".android/avd/\(name).avd/userdata-qemu.img", bytes: 500,
                   modified: Date(timeIntervalSince1970: 2_000_000))
        try f.file(".android/avd/\(name).avd/hardware-qemu.ini.lock", bytes: 1,
                   modified: Date(timeIntervalSince1970: 1_000_000))
        try "path=\(f.home.path)/.android/avd/\(name).avd\n".write(
            to: f.home.appendingPathComponent(".android/avd/\(name).ini"), atomically: true, encoding: .utf8)
    }

    func makeFixture() throws -> FixtureHome {
        let f = try FixtureHome()
        try makeAVD(f, "Pixel_4_API_35", display: "Pixel 4 API 35",
                    sysdir: "system-images/android-35/google_apis_playstore/arm64-v8a/", spaced: true)
        try makeAVD(f, "Tablet_35", display: "Tablet 35",
                    sysdir: "system-images/android-35/google_apis_playstore/arm64-v8a/", spaced: false)
        try f.file("Library/Android/sdk/system-images/android-35/google_apis_playstore/arm64-v8a/system.img", bytes: 3000)
        try f.file("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a/system.img", bytes: 2000)
        try f.file("Library/Android/sdk/platforms/android-34/android.jar", bytes: 400)
        try f.file("Library/Android/sdk/build-tools/9.0.0/aapt", bytes: 100)
        try f.file("Library/Android/sdk/build-tools/34.0.0/aapt", bytes: 110)
        try f.file("Library/Android/sdk/build-tools/30.0.3/aapt", bytes: 120)
        try f.file("Library/Android/sdk/emulator/emulator", bytes: 700)
        try f.file("Library/Android/sdk/sources/android-34/a.java", bytes: 50)
        return f
    }

    @Test func avdItemsAndPlan() async throws {
        let f = try makeFixture()
        let ctx = context(f)
        let inspector = AndroidInspector()
        let items = try await inspector.discover(in: ctx)
        let avd = try #require(items.first { $0.id == "android.avd.Pixel_4_API_35" })
        #expect(avd.title == "Pixel 4 API 35")
        #expect(avd.risk == .userData)
        #expect(avd.allocatedBytes > 500)
        #expect(avd.lastUsed == Date(timeIntervalSince1970: 2_000_000))
        #expect(avd.requirement == .mustBeQuit(bundleIDs: [], processNames: procs))
        let tablet = try #require(items.first { $0.id == "android.avd.Tablet_35" })
        #expect(tablet.title == "Tablet 35")

        let plan = try await inspector.plan(for: [avd], in: ctx)
        let base = f.home.path + "/.android/avd/Pixel_4_API_35"
        #expect(plan.steps.map(\.action) == [
            .trash(path: base + ".avd", expectedFileID: nil),
            .trash(path: base + ".ini", expectedFileID: nil),
        ])
        #expect(plan.steps.allSatisfy { $0.risk == .userData && $0.requirement == avd.requirement })
    }

    @Test func systemImageListsBothAVDs() async throws {
        let f = try makeFixture()
        let ctx = context(f)
        let inspector = AndroidInspector()
        let items = try await inspector.discover(in: ctx)
        let image = try #require(items.first { $0.id == "android.sysimage.android-35/google_apis_playstore/arm64-v8a" })
        #expect(image.risk == .rebuildable)
        #expect(image.subtitle == "Used by AVD Pixel 4 API 35, Tablet 35")
        #expect(image.allocatedBytes == 3000)
        #expect(image.requirement == .mustBeQuit(bundleIDs: ["com.google.android.studio"], processNames: procs))
        let unused = try #require(items.first { $0.id == "android.sysimage.android-34/google_apis/arm64-v8a" })
        #expect(unused.subtitle == nil)

        let plan = try await inspector.plan(for: [image], in: ctx)
        #expect(plan.steps.map(\.action) == [
            .delete(path: f.home.path + "/Library/Android/sdk/system-images/android-35/google_apis_playstore/arm64-v8a", expectedFileID: nil),
        ])
    }

    @Test func sdkComponents() async throws {
        let f = try makeFixture()
        let ctx = context(f)
        let inspector = AndroidInspector()
        let items = try await inspector.discover(in: ctx)
        let sdk = f.home.path + "/Library/Android/sdk"
        let platform = try #require(items.first { $0.id == "android.platform.android-34" })
        #expect(platform.risk == .rebuildable)
        #expect(platform.allocatedBytes == 400)
        let newest = try #require(items.first { $0.id == "android.buildtools.34.0.0" })
        #expect(newest.subtitle == "Newest")
        #expect(items.first { $0.id == "android.buildtools.9.0.0" }?.subtitle == nil)
        #expect(items.first { $0.id == "android.buildtools.30.0.3" }?.subtitle == nil)
        #expect(items.first { $0.id == "android.emulator" }?.risk == .rebuildable)
        #expect(items.first { $0.id == "android.sources" }?.risk == .rebuildable)

        let plan = try await inspector.plan(for: items.filter { $0.id == "android.emulator" || $0.id == "android.sources" }, in: ctx)
        #expect(plan.steps.map(\.action) == [
            .delete(path: sdk + "/emulator", expectedFileID: nil),
            .delete(path: sdk + "/sources", expectedFileID: nil),
        ])
    }

    @Test func noAndroidDirs() async throws {
        let f = try FixtureHome()
        let items = try await AndroidInspector().discover(in: context(f))
        #expect(items.isEmpty)
    }
}
