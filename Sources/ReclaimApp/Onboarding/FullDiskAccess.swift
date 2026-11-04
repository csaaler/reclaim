import AppKit
import Foundation
import Security

enum FullDiskAccess {
    /// Files and folders only Full Disk Access holders can open. Without access each returns EPERM
    /// (verified on macOS 26 with an ad-hoc signed build); a missing probe is skipped.
    /// The system TCC database comes first because it always exists.
    static let probes: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Library/Application Support/com.apple.TCC/TCC.db",
                "\(home)/Library/Safari/Bookmarks.plist",
                "\(home)/Library/Containers/com.apple.stocks"]
    }()

    /// True when any probe can be opened. TCC ties the grant to the code signature, so a rebuilt
    /// ad-hoc build reads as not granted even if an older build was allowed.
    static func isGranted() -> Bool {
        for path in probes {
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
                return true
            }
        }
        return false
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True for an ad-hoc signed (or unsigned) build: no team identifier, so macOS forgets the
    /// Full Disk Access grant after every rebuild.
    /// Computed once per process; the signature does not change while the app runs.
    static let isAdHocSignedBuild: Bool = isAdHocSigned()

    static func isAdHocSigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        if let flags = dict[kSecCodeInfoFlags as String] as? UInt32,
           flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return true
        }
        return dict[kSecCodeInfoTeamIdentifier as String] == nil
    }
}
