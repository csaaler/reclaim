import AppKit
import SwiftUI

/// Non-modal Full Disk Access prompt shown at the top of the main window. It never blocks
/// quitting, so System Settings' "Quit & Reopen" works while it is visible.
struct FullDiskAccessBanner: View {
    enum Mode: Equatable {
        /// Access is missing.
        case needsAccess
        /// Access was granted while the app was running; a restart applies it.
        case restartNeeded
    }

    let mode: Mode
    let isAdHocSigned: Bool
    /// A relaunch has been requested; the button stays disabled.
    let isRelaunching: Bool
    /// Why the last relaunch failed.
    let relaunchError: String?
    let onOpenSettings: () -> Void
    let onQuitAndReopen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: mode == .needsAccess ? "lock.shield" : "arrow.clockwise.circle")
                .font(.title2)
                .foregroundStyle(mode == .needsAccess ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                switch mode {
                case .needsAccess:
                    Text("Grant Full Disk Access").font(.headline)
                    Text("Without it, folders such as Mail, Safari and some app containers are skipped and shown as unreadable. Turn on Reclaim under Privacy & Security → Full Disk Access, then quit and reopen the app. The app only measures sizes and never reads file contents.")
                        .fixedSize(horizontal: false, vertical: true)
                case .restartNeeded:
                    Text("Full Disk Access is on").font(.headline)
                    Text("Quit and reopen Reclaim so macOS applies it to the scan.")
                }
                if isAdHocSigned && mode == .needsAccess {
                    Text("This development build is ad-hoc signed; macOS forgets Full Disk Access after every rebuild. See README → Signing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let relaunchError {
                    Text("Could not reopen Reclaim: \(relaunchError)")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if mode == .needsAccess {
                        Button("Open System Settings", action: onOpenSettings)
                    }
                    Button("Quit & Reopen", action: onQuitAndReopen)
                        .disabled(isRelaunching)
                    Button(mode == .needsAccess ? "Continue without" : "Later", action: onDismiss)
                }
                .padding(.top, 4)
            }
            // The wrapped text grows taller as it narrows; without a floor, the split view's
            // minimum-size pass measures it at near-zero width and the window content becomes
            // thousands of points tall, pushing everything off-screen.
            .frame(minWidth: 420, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }
}

/// Tracks Full Disk Access and re-checks it whenever the app becomes active. Create one per
/// app (it probes the disk once on creation) and pass it down.
@MainActor @Observable
final class FullDiskAccessMonitor {
    private(set) var isGranted: Bool
    private let grantedAtLaunch: Bool
    var isDismissed = false
    var isAdHocSigned: Bool { FullDiskAccess.isAdHocSignedBuild }
    private(set) var isRelaunching = false
    private(set) var relaunchError: String?

    init() {
        let granted = FullDiskAccess.isGranted()
        isGranted = granted
        grantedAtLaunch = granted
    }

    /// Nil when nothing needs saying.
    var bannerMode: FullDiskAccessBanner.Mode? {
        if isDismissed { return nil }
        if !isGranted { return .needsAccess }
        return grantedAtLaunch ? nil : .restartNeeded
    }

    /// Starts a new instance of this app and quits this one once it launched, so a new grant
    /// takes effect. Repeated calls while a relaunch is pending do nothing; on failure the app
    /// keeps running and the error is shown.
    func quitAndReopen() {
        guard !isRelaunching else { return }
        isRelaunching = true
        relaunchError = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let bundle = Bundle.main.bundleURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
                Task { @MainActor in
                    if app != nil && error == nil {
                        NSApp.terminate(nil)
                    } else {
                        self.isRelaunching = false
                        self.relaunchError = error?.localizedDescription ?? "macOS did not start a new instance."
                    }
                }
            }
        }
    }

    func refresh() {
        let granted = FullDiskAccess.isGranted()
        if granted != isGranted { isDismissed = false }
        isGranted = granted
    }
}

#Preview("Needs access") {
    FullDiskAccessBanner(mode: .needsAccess, isAdHocSigned: true, isRelaunching: false, relaunchError: nil, onOpenSettings: {}, onQuitAndReopen: {}, onDismiss: {})
        .frame(width: 700)
}

#Preview("Restart") {
    FullDiskAccessBanner(mode: .restartNeeded, isAdHocSigned: false, isRelaunching: false, relaunchError: "The application could not be found.", onOpenSettings: {}, onQuitAndReopen: {}, onDismiss: {})
        .frame(width: 700)
}
