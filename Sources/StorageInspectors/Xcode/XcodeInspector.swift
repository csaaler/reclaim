import Foundation
import StorageCore

/// Xcode and Simulator storage: simulator devices and runtimes (via `xcrun simctl`),
/// DerivedData, device support, CoreSimulator caches and archives.
public struct XcodeInspector: Inspector {
    public let id = "xcode"
    public let displayName = "Xcode & Simulators"
    public let bundleIDs: [String] = [
        "com.apple.dt.Xcode",
        "com.apple.iphonesimulator",
    ]
    public let claimedPatterns: [String] = [
        "~/Library/Developer/*",
        "/Library/Developer/CoreSimulator/*",
    ]
    public let category: StorageCategory? = .developerTools

    /// Root-owned system cache directory; injectable so tests can point it into a fixture.
    private let adminCachesRoot: String

    public init(adminCachesRoot: String = "/Library/Developer/CoreSimulator/Caches") {
        self.adminCachesRoot = adminCachesRoot
    }

    private static let simulatorBundle = "com.apple.iphonesimulator"
    private static let xcodeBundle = "com.apple.dt.Xcode"
    private static let staleDays = 90
    private static let toolTimeout: Duration = .seconds(60)

    // MARK: simctl JSON

    private struct Device {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool
        let runtimeID: String
    }

    private struct Runtime {
        let identifier: String
        let runtimeIdentifier: String
        let version: String
        let platformIdentifier: String
        let sizeBytes: Int64
        let lastUsed: Date?
        let deletable: Bool
    }

    // MARK: Inspector

    public func discover(in context: InspectorContext) async throws -> [InspectorItem] {
        guard let xcrun = context.tools.locate("xcrun") else {
            throw InspectorUnavailable("xcrun is not installed")
        }
        var items: [InspectorItem] = []
        var devices: [Device] = []
        var runtimes: [Runtime] = []
        // Without the command line tools, /usr/bin/xcrun is a stub that asks to install them.
        if try await commandLineToolsInstalled(context) {
            do {
                devices = try await loadDevices(xcrun: xcrun, context: context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                items.append(errorItem("devices", "Simulator devices couldn't be listed", error))
            }
            do {
                runtimes = try await loadRuntimes(xcrun: xcrun, context: context)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                items.append(errorItem("runtimes", "Simulator runtimes couldn't be listed", error))
            }
        } else {
            items.append(InspectorItem(
                id: "xcode.command-line-tools",
                inspectorID: id,
                title: "Xcode command line tools not installed",
                subtitle: "Simulator devices and runtimes can't be listed",
                whatYouLose: "Nothing; this entry only reports that simulators were not checked.",
                allocatedBytes: 0,
                risk: .rebuildable,
                lastUsed: nil,
                paths: [],
                requirement: .none,
                actionTitle: "Unavailable",
                isActionable: false
            ))
        }
        items += await unavailableDeviceItem(devices, context: context)
        items += await staleDeviceItems(devices, context: context)
        items += runtimeItems(runtimes, devices: devices)
        items += await derivedDataItems(context: context)
        items += await deviceSupportItems(context: context)
        items += await cacheItems(context: context)
        items += await archiveItems(context: context)
        return items
    }

    public func plan(for items: [InspectorItem], in context: InspectorContext) async throws -> CleanupPlan {
        var xcrun: String?
        func requireXcrun() throws -> String {
            if let xcrun { return xcrun }
            guard let found = context.tools.locate("xcrun") else {
                throw InspectorUnavailable("xcrun is not installed")
            }
            xcrun = found
            return found
        }

        var steps: [CleanupStep] = []
        for item in items {
            if item.id == "xcode.unavailable-devices" {
                steps.append(step(item, .runTool(executable: try requireXcrun(), arguments: ["simctl", "delete", "unavailable"])))
            } else if let udid = item.id.removingPrefix("xcode.device.") {
                steps.append(step(item, .runTool(executable: try requireXcrun(), arguments: ["simctl", "delete", udid])))
            } else if let runtime = item.id.removingPrefix("xcode.runtime.") {
                steps.append(step(item, .runTool(executable: try requireXcrun(), arguments: ["simctl", "runtime", "delete", runtime])))
            } else if item.id.hasPrefix("xcode.archive.") {
                for path in item.paths { steps.append(step(item, .trash(path: path, expectedFileID: nil))) }
            } else if item.id == "xcode.system-cache" {
                continue // requires admin: view-only
            } else if item.id.hasPrefix("xcode.derived.") || item.id.hasPrefix("xcode.support.") || item.id.hasPrefix("xcode.cache.") {
                for path in item.paths { steps.append(step(item, .delete(path: path, expectedFileID: nil))) }
            }
        }
        return CleanupPlan(steps: steps)
    }

    private struct SimctlFailure: Error { let message: String }

    static let xcodeSelect = "/usr/bin/xcode-select"

    /// `xcode-select -p` exits 0 only when a developer directory (Xcode or the command line
    /// tools) is set up. Any failure, including a thrown error, counts as not installed.
    private func commandLineToolsInstalled(_ context: InspectorContext) async throws -> Bool {
        do {
            return try await context.tools.run(Self.xcodeSelect, ["-p"], timeout: .seconds(10)).exitCode == 0
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    private func errorItem(_ kind: String, _ title: String, _ error: Error) -> InspectorItem {
        let message = (error as? SimctlFailure)?.message ?? String(describing: error)
        return InspectorItem(
            id: "xcode.error.\(kind)",
            inspectorID: id,
            title: title,
            subtitle: message.trimmingCharacters(in: .whitespacesAndNewlines),
            whatYouLose: "Nothing; this entry only reports that simctl failed.",
            allocatedBytes: 0,
            risk: .rebuildable,
            lastUsed: nil,
            paths: [],
            requirement: .none,
            actionTitle: "Unavailable",
            isActionable: false
        )
    }

    private func step(_ item: InspectorItem, _ action: CleanupAction) -> CleanupStep {
        CleanupStep(
            title: item.actionTitle,
            risk: item.risk,
            estimatedBytes: item.allocatedBytes,
            requirement: item.requirement,
            action: action
        )
    }

    // MARK: Loading

    private func loadDevices(xcrun: String, context: InspectorContext) async throws -> [Device] {
        let root = try await simctlJSON(xcrun, ["simctl", "list", "devices", "--json"], context)
        guard let groups = root["devices"] as? [String: Any] else {
            throw SimctlFailure(message: "Unexpected simctl output: no \"devices\" key")
        }
        var result: [Device] = []
        for (runtimeID, value) in groups {
            for entry in (value as? [[String: Any]]) ?? [] {
                guard let udid = entry["udid"] as? String else { continue }
                result.append(Device(
                    udid: udid,
                    name: entry["name"] as? String ?? udid,
                    state: entry["state"] as? String ?? "",
                    isAvailable: entry["isAvailable"] as? Bool ?? true,
                    runtimeID: runtimeID
                ))
            }
        }
        return result.sorted { $0.udid < $1.udid }
    }

    private func loadRuntimes(xcrun: String, context: InspectorContext) async throws -> [Runtime] {
        let root = try await simctlJSON(xcrun, ["simctl", "runtime", "list", "-j"], context)
        var result: [Runtime] = []
        for (key, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            let formatter = ISO8601DateFormatter()
            result.append(Runtime(
                identifier: entry["identifier"] as? String ?? key,
                runtimeIdentifier: entry["runtimeIdentifier"] as? String ?? "",
                version: entry["version"] as? String ?? "",
                platformIdentifier: entry["platformIdentifier"] as? String ?? "",
                sizeBytes: (entry["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                lastUsed: (entry["lastUsedAt"] as? String).flatMap { formatter.date(from: $0) },
                deletable: entry["deletable"] as? Bool ?? true
            ))
        }
        return result.sorted { $0.identifier < $1.identifier }
    }

    /// simctl may print progress or warnings before the JSON; parse from the first brace.
    private func simctlJSON(_ xcrun: String, _ args: [String], _ context: InspectorContext) async throws -> [String: Any] {
        let output: ToolOutput
        do {
            output = try await context.tools.run(xcrun, args, timeout: Self.toolTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SimctlFailure(message: String(describing: error))
        }
        guard output.exitCode == 0 else {
            let text = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimctlFailure(message: text.isEmpty ? "simctl exited with code \(output.exitCode)" : text)
        }
        guard let start = output.stdout.firstIndex(of: "{"),
              let data = String(output.stdout[start...]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SimctlFailure(message: "simctl returned output that is not valid JSON")
        }
        return json
    }

    // MARK: Simulator devices

    private func devicesDir(_ context: InspectorContext) -> String {
        context.home.appendingPathComponent("Library/Developer/CoreSimulator/Devices").path
    }

    private func unavailableDeviceItem(_ devices: [Device], context: InspectorContext) async -> [InspectorItem] {
        let unavailable = devices.filter { !$0.isAvailable }
        guard !unavailable.isEmpty else { return [] }
        var paths: [String] = []
        var bytes: Int64 = 0
        for device in unavailable {
            let path = devicesDir(context) + "/" + device.udid
            guard FileManager.default.fileExists(atPath: path) else { continue }
            paths.append(path)
            bytes += await context.sizer.allocatedSize(of: path)
        }
        guard !paths.isEmpty || bytes > 0 else { return [] }
        return [InspectorItem(
            id: "xcode.unavailable-devices",
            inspectorID: id,
            title: "Unavailable simulator devices",
            subtitle: "\(unavailable.count) \(unavailable.count == 1 ? "device" : "devices") whose runtime is no longer installed",
            whatYouLose: "Simulator devices that can no longer boot, with their app data.",
            allocatedBytes: bytes,
            risk: .rebuildable,
            lastUsed: nil,
            paths: paths,
            requirement: .none,
            actionTitle: "Delete unavailable simulator devices"
        )]
    }

    private func staleDeviceItems(_ devices: [Device], context: InspectorContext) async -> [InspectorItem] {
        let cutoff = context.now.addingTimeInterval(-Double(Self.staleDays) * 86_400)
        var items: [InspectorItem] = []
        for device in devices where device.isAvailable && device.state == "Shutdown" {
            let dir = devicesDir(context) + "/" + device.udid
            guard let lastUsed = modified(dir + "/data"), lastUsed <= cutoff else { continue }
            items.append(InspectorItem(
                id: "xcode.device.\(device.udid)",
                inspectorID: id,
                title: device.name,
                subtitle: "Not booted in \(Self.staleDays)+ days",
                whatYouLose: "This simulator and all app data installed in it.",
                allocatedBytes: await context.sizer.allocatedSize(of: dir),
                risk: .userData,
                lastUsed: lastUsed,
                paths: [dir],
                requirement: .mustBeQuit(bundleIDs: [Self.simulatorBundle], processNames: []),
                actionTitle: "Delete simulator"
            ))
        }
        return items
    }

    // MARK: Runtimes

    private func runtimeItems(_ runtimes: [Runtime], devices: [Device]) -> [InspectorItem] {
        runtimes.filter(\.deletable).map { runtime in
            let users = devices.filter { $0.isAvailable && !runtime.runtimeIdentifier.isEmpty && $0.runtimeID == runtime.runtimeIdentifier }.count
            let subtitle = users > 0
                ? "In use by \(users) \(users == 1 ? "device" : "devices") — they'll be deleted too"
                : nil
            return InspectorItem(
                id: "xcode.runtime.\(runtime.identifier)",
                inspectorID: id,
                title: runtimeTitle(runtime),
                subtitle: subtitle,
                whatYouLose: "The simulator runtime; re-download it from Xcode when needed.",
                allocatedBytes: runtime.sizeBytes,
                risk: .rebuildable,
                lastUsed: runtime.lastUsed,
                paths: [],
                requirement: .none,
                actionTitle: "Delete simulator runtime"
            )
        }
    }

    private func platformName(_ platformIdentifier: String) -> String? {
        switch platformIdentifier {
        case "com.apple.platform.iphonesimulator": "iOS"
        case "com.apple.platform.appletvsimulator": "tvOS"
        case "com.apple.platform.watchsimulator": "watchOS"
        case "com.apple.platform.xrsimulator": "visionOS"
        default: nil
        }
    }

    private func runtimeTitle(_ runtime: Runtime) -> String {
        let platform = platformName(runtime.platformIdentifier) ?? "Simulator"
        return runtime.version.isEmpty ? "\(platform) runtime" : "\(platform) \(runtime.version)"
    }

    // MARK: Xcode folders

    private func xcodeDir(_ context: InspectorContext) -> URL {
        context.home.appendingPathComponent("Library/Developer/Xcode")
    }

    private func children(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    private func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func derivedDataItems(context: InspectorContext) async -> [InspectorItem] {
        let root = xcodeDir(context).appendingPathComponent("DerivedData").path
        var items: [InspectorItem] = []
        for name in children(root) {
            let path = root + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            items.append(InspectorItem(
                id: "xcode.derived.\(name)",
                inspectorID: id,
                title: Self.derivedDataTitle(name),
                subtitle: nil,
                whatYouLose: "Build products and indexes; Xcode rebuilds them on the next build.",
                allocatedBytes: await context.sizer.allocatedSize(of: path),
                risk: .cache,
                lastUsed: modified(path),
                paths: [path],
                requirement: .mustBeQuit(bundleIDs: [Self.xcodeBundle], processNames: []),
                actionTitle: "Delete DerivedData"
            ))
        }
        return items
    }

    /// "MyApp-abcdefghijklmnopqrstuvwxyz" becomes "MyApp"; names without a hash suffix are kept.
    static func derivedDataTitle(_ folder: String) -> String {
        guard let dash = folder.lastIndex(of: "-") else { return folder }
        let hash = folder[folder.index(after: dash)...]
        guard hash.count >= 20, hash.allSatisfy({ $0.isASCII && $0.isLetter }) else { return folder }
        return String(folder[..<dash])
    }

    private func deviceSupportItems(context: InspectorContext) async -> [InspectorItem] {
        let root = xcodeDir(context).path
        var items: [InspectorItem] = []
        for group in children(root) where group.hasSuffix(" DeviceSupport") {
            let platform = String(group.dropLast(" DeviceSupport".count))
            for version in children(root + "/" + group) {
                let path = root + "/" + group + "/" + version
                items.append(InspectorItem(
                    id: "xcode.support.\(group)/\(version)",
                    inspectorID: id,
                    title: "\(platform) device support \(version)",
                    subtitle: nil,
                    whatYouLose: "Debug symbols copied from a device; Xcode re-copies them when the device is next connected.",
                    allocatedBytes: await context.sizer.allocatedSize(of: path),
                    risk: .rebuildable,
                    lastUsed: modified(path),
                    paths: [path],
                    requirement: .none,
                    actionTitle: "Delete device support"
                ))
            }
        }
        return items
    }

    // MARK: Caches

    private func cacheItems(context: InspectorContext) async -> [InspectorItem] {
        var items: [InspectorItem] = []
        let root = context.home.appendingPathComponent("Library/Developer/CoreSimulator/Caches").path
        for name in children(root) {
            let path = root + "/" + name
            items.append(InspectorItem(
                id: "xcode.cache.\(name)",
                inspectorID: id,
                title: "CoreSimulator cache: \(name)",
                subtitle: nil,
                whatYouLose: "Simulator caches; rebuilt automatically.",
                allocatedBytes: await context.sizer.allocatedSize(of: path),
                risk: .cache,
                lastUsed: modified(path),
                paths: [path],
                requirement: .none,
                actionTitle: "Delete cache"
            ))
        }
        if FileManager.default.fileExists(atPath: adminCachesRoot) {
            items.append(InspectorItem(
                id: "xcode.system-cache",
                inspectorID: id,
                title: "System CoreSimulator caches",
                subtitle: "requires admin",
                whatYouLose: "Simulator caches owned by root; Reclaim cannot remove them.",
                allocatedBytes: await context.sizer.allocatedSize(of: adminCachesRoot),
                risk: .cache,
                lastUsed: modified(adminCachesRoot),
                paths: [adminCachesRoot],
                requirement: .none,
                actionTitle: "Requires admin",
                isActionable: false
            ))
        }
        return items
    }

    // MARK: Archives

    private func archiveItems(context: InspectorContext) async -> [InspectorItem] {
        let root = xcodeDir(context).appendingPathComponent("Archives").path
        var items: [InspectorItem] = []
        for day in children(root) {
            for name in children(root + "/" + day) where name.hasSuffix(".xcarchive") {
                let path = root + "/" + day + "/" + name
                items.append(InspectorItem(
                    id: "xcode.archive.\(day)/\(name)",
                    inspectorID: id,
                    title: String(name.dropLast(".xcarchive".count)),
                    subtitle: day,
                    whatYouLose: "An archived app build, including its dSYMs; needed to symbolicate crashes of released versions.",
                    allocatedBytes: await context.sizer.allocatedSize(of: path),
                    risk: .userData,
                    lastUsed: modified(path),
                    paths: [path],
                    requirement: .none,
                    actionTitle: "Move archive to Trash"
                ))
            }
        }
        return items
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
