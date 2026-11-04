import AppKit
import Darwin
import Foundation

public struct WorkspaceAppChecker: RunningAppChecking {
    public init() {}

    public func isRunning(bundleIDs: [String], processNames: [String]) async -> Bool {
        if !bundleIDs.isEmpty {
            let ids = Set(bundleIDs)
            let apps = NSWorkspace.shared.runningApplications
            if apps.contains(where: { $0.bundleIdentifier.map(ids.contains) ?? false }) { return true }
        }
        if !processNames.isEmpty {
            let names = Set(processNames)
            return Self.runningProcessNames().contains(where: names.contains)
        }
        return false
    }

    public func requestQuit(bundleIDs: [String]) async -> Bool {
        let ids = Set(bundleIDs)
        let targets = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map(ids.contains) ?? false
        }
        if targets.isEmpty { return true }
        for app in targets { _ = app.terminate() }  // never forceTerminate
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if targets.allSatisfy({ $0.isTerminated }) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return targets.allSatisfy { $0.isTerminated }
    }

    private static func runningProcessNames() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let n = Int(bytes) / MemoryLayout<pid_t>.size
        var names: [String] = []
        var buf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(n) where pid > 0 {
            let len = proc_name(pid, &buf, UInt32(buf.count))
            if len > 0 { names.append(String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
        }
        return names
    }
}
