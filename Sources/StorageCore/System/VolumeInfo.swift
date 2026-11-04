import Darwin
import Foundation

public enum VolumeInfo {
    /// Everything the overview shows about the volume holding `path`. Slow: it also runs
    /// `tmutil` to count local snapshots. Use `availableBytes(for:)` for repeated free-space reads.
    public static func stats(for path: String = "/System/Volumes/Data") throws -> VolumeStats {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? available
        let purgeable = max(0, important - available)

        let systemBytes = spaceUsed(byVolumeAt: "/") ?? 0
        return VolumeStats(
            totalBytes: total,
            usedBytes: total - available,
            availableBytes: available,
            purgeableBytes: purgeable,
            systemVolumeBytes: systemBytes,
            localSnapshotCount: localSnapshotCount())
    }

    /// Free space on the volume holding `path`. One file-system query and no subprocess, so it
    /// is cheap enough to call before and after every cleanup step. Throws when the value can't
    /// be read, so a caller never mistakes a failed read for a full disk.
    public static func availableBytes(for path: String = "/System/Volumes/Data") throws -> Int64 {
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacity else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        return Int64(available)
    }

    /// Space used by the volume mounted at `path` (`ATTR_VOL_SPACEUSED`). On APFS, `statfs` reports
    /// the whole container's blocks, so `f_blocks - f_bfree` would be the container's used space.
    static func spaceUsed(byVolumeAt path: String) -> Int64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        // Layout: u_int32_t length, then off_t space used.
        var buffer = [UInt8](repeating: 0, count: 32)
        guard getattrlist(path, &list, &buffer, buffer.count, 0) == 0 else { return nil }
        let used = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        return used > 0 ? used : nil
    }

    /// Runs `/usr/bin/tmutil` directly rather than through `ToolRunning`: it is a fixed system
    /// binary with fixed, read-only arguments, called synchronously while reading volume totals.
    /// `ToolRunning` is for the tools that inspectors find and cleanup steps run.
    private static func localSnapshotCount() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return 0 }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return 0 }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.hasPrefix("com.apple.TimeMachine.") }
            .count
    }
}
