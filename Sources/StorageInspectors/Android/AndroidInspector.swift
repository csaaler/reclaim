import Foundation
import StorageCore

/// Android emulators (AVDs) and SDK components. Cleans by path; `sdkmanager` is not used.
public struct AndroidInspector: Inspector {
    public let id = "android"
    public let displayName = "Android SDK & Emulators"
    public let bundleIDs: [String] = ["com.google.android.studio"]
    public let claimedPatterns: [String] = [
        "~/.android/avd/*",
        "~/Library/Android/sdk/*",
    ]
    public let category: StorageCategory? = .developerTools

    private static let emulatorProcesses = ["qemu-system-aarch64", "qemu-system-x86_64", "emulator"]
    private static let studioID = "com.google.android.studio"

    public init() {}

    public func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        let avds = Self.readAVDs(home: context.home)
        var items: [InspectorItem] = []
        for avd in avds {
            items.append(await avdItem(avd, context))
        }
        items += await sdkItems(avds: avds, context)
        return items
    }

    public func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        var steps: [CleanupStep] = []
        for item in items where item.inspectorID == id {
            for path in item.paths {
                let action: CleanupAction = item.risk == .userData
                    ? .trash(path: path, expectedFileID: nil)
                    : .delete(path: path, expectedFileID: nil)
                let bytes = item.paths.count == 1 ? item.allocatedBytes : await context.sizer.allocatedSize(of: path)
                steps.append(CleanupStep(
                    title: "\(item.actionTitle): \(URL(fileURLWithPath: path).lastPathComponent)",
                    risk: item.risk,
                    estimatedBytes: bytes,
                    requirement: item.requirement,
                    action: action
                ))
            }
        }
        return CleanupPlan(steps: steps)
    }

    // MARK: AVDs

    private struct AVD {
        let name: String
        let displayName: String
        let avdPath: String
        let iniPath: String
        /// `system-images/<api>/<tag>/<abi>` without trailing slash, if configured.
        let sysdir: String?
    }

    private static func readAVDs(home: URL) -> [AVD] {
        let root = home.appendingPathComponent(".android/avd").path
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
        return entries.filter { $0.hasSuffix(".avd") }.map { entry in
            let name = String(entry.dropLast(4))
            let avdPath = root + "/" + entry
            let config = parseINI(path: avdPath + "/config.ini")
            var sysdir = config["image.sysdir.1"]
            while sysdir?.hasSuffix("/") == true { sysdir?.removeLast() }
            return AVD(
                name: name,
                displayName: config["avd.ini.displayname"].flatMap { $0.isEmpty ? nil : $0 } ?? name,
                avdPath: avdPath,
                iniPath: root + "/" + name + ".ini",
                sysdir: sysdir
            )
        }
    }

    /// Reads `key=value` / `key = value` lines.
    private static func parseINI(path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.hasPrefix("#") else { continue }
            result[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private func avdItem(_ avd: AVD, _ context: InspectorContext) async -> InspectorItem {
        var paths = [avd.avdPath]
        if FileManager.default.fileExists(atPath: avd.iniPath) { paths.append(avd.iniPath) }
        var bytes: Int64 = 0
        for path in paths { bytes += await context.sizer.allocatedSize(of: path) }
        return InspectorItem(
            id: "android.avd.\(avd.name)",
            inspectorID: id,
            title: avd.displayName,
            subtitle: avd.sysdir.map { "System image \($0.replacingOccurrences(of: "system-images/", with: ""))" },
            whatYouLose: "The emulator's apps, data and snapshots. The virtual device must be created again.",
            allocatedBytes: bytes,
            risk: .userData,
            lastUsed: Self.lastUsed(of: avd.avdPath),
            paths: paths,
            requirement: .mustBeQuit(bundleIDs: [], processNames: Self.emulatorProcesses),
            actionTitle: "Remove emulator"
        )
    }

    /// Newest mtime of `*.lock`, `userdata-qemu.img` or `snapshots/` inside the AVD.
    private static func lastUsed(of avdPath: String) -> Date? {
        let manager = FileManager.default
        let names = ((try? manager.contentsOfDirectory(atPath: avdPath)) ?? [])
            .filter { $0.hasSuffix(".lock") || $0 == "userdata-qemu.img" || $0 == "snapshots" }
        return names.compactMap {
            (try? manager.attributesOfItem(atPath: avdPath + "/" + $0))?[.modificationDate] as? Date
        }.max()
    }

    // MARK: SDK

    private func sdkItems(avds: [AVD], _ context: InspectorContext) async -> [InspectorItem] {
        let sdk = context.home.appendingPathComponent("Library/Android/sdk").path
        let requirement = AppStateRequirement.mustBeQuit(
            bundleIDs: [Self.studioID], processNames: Self.emulatorProcesses)
        var items: [InspectorItem] = []

        func item(_ key: String, _ title: String, _ subtitle: String?, _ lose: String, _ path: String, _ action: String) async -> InspectorItem {
            InspectorItem(
                id: "android.\(key)", inspectorID: id, title: title, subtitle: subtitle,
                whatYouLose: lose,
                allocatedBytes: await context.sizer.allocatedSize(of: path),
                risk: .rebuildable, lastUsed: Self.mtime(path), paths: [path],
                requirement: requirement, actionTitle: action)
        }

        // System images: <api>/<tag>/<abi>
        for api in Self.subdirs(sdk + "/system-images") {
            for tag in Self.subdirs(sdk + "/system-images/\(api)") {
                for abi in Self.subdirs(sdk + "/system-images/\(api)/\(tag)") {
                    let rel = "\(api)/\(tag)/\(abi)"
                    let users = avds.filter { $0.sysdir == "system-images/\(rel)" }.map(\.displayName)
                    items.append(await item(
                        "sysimage.\(rel)", "System image \(api) \(tag) \(abi)",
                        users.isEmpty ? nil : "Used by AVD " + users.joined(separator: ", "),
                        "Emulators using this image cannot start until it is downloaded again.",
                        sdk + "/system-images/" + rel, "Remove system image"))
                }
            }
        }

        for platform in Self.subdirs(sdk + "/platforms") where platform.hasPrefix("android-") {
            items.append(await item(
                "platform.\(platform)", "SDK platform \(platform)", nil,
                "Projects targeting this API level need it downloaded again.",
                sdk + "/platforms/" + platform, "Remove SDK platform"))
        }

        let buildTools = Self.subdirs(sdk + "/build-tools")
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        for version in buildTools {
            items.append(await item(
                "buildtools.\(version)", "Build-tools \(version)",
                version == buildTools.last ? "Newest" : nil,
                "Builds that pin this version need it downloaded again.",
                sdk + "/build-tools/" + version, "Remove build-tools"))
        }

        if Self.isDirectory(sdk + "/emulator") {
            items.append(await item(
                "emulator", "Android Emulator", nil,
                "The emulator binaries must be downloaded again before any virtual device runs.",
                sdk + "/emulator", "Remove emulator package"))
        }
        if Self.isDirectory(sdk + "/sources") {
            items.append(await item(
                "sources", "Android SDK sources", nil,
                "Framework source files used for debugging must be downloaded again.",
                sdk + "/sources", "Remove SDK sources"))
        }
        return items
    }

    private static func subdirs(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") && isDirectory(path + "/" + $0) }
            .sorted()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
