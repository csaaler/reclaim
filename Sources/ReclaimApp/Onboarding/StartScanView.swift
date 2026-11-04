import AppKit
import SwiftUI

/// Shown until the first scan: Full Disk Access first, then an explicit Start Scan. Nothing reads
/// the disk before the user starts a scan, and a scan without Full Disk Access would make macOS
/// ask for each protected folder (media library, network volumes, other apps' data) one by one.
struct StartScanView: View {
    let isGranted: Bool
    let isAdHocSigned: Bool
    /// A relaunch has been requested; the button stays disabled.
    let isRelaunching: Bool
    /// Why the last relaunch failed.
    let relaunchError: String?
    /// Why the last scan did not produce an overview, if one was attempted.
    let errorMessage: String?
    let onOpenSettings: () -> Void
    let onQuitAndReopen: () -> Void
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Scan your disk").font(.largeTitle.bold())
                Text("Reclaim measures every folder on your Data volume and explains where the space went. It only reads sizes, never file contents, and changes nothing until you review a cleanup.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(number: 1, title: isGranted ? "Full Disk Access is on" : "Turn on Full Disk Access", done: isGranted) {
                if !isGranted {
                    Text("macOS does not ask for Full Disk Access; you turn it on yourself. Open Privacy & Security → Full Disk Access, switch on Reclaim (add it with + if it is missing), then quit and reopen Reclaim.")
                        .fixedSize(horizontal: false, vertical: true)
                    if isAdHocSigned {
                        Text("This build is ad-hoc signed, so macOS forgets the grant after every rebuild. See README → Signing.")
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
                        Button("Open System Settings", action: onOpenSettings)
                        Button("Quit & Reopen", action: onQuitAndReopen)
                            .disabled(isRelaunching)
                    }
                }
            }

            step(number: 2, title: "Start the scan", done: false) {
                Text("A full scan usually takes a minute or two.")
                    .foregroundStyle(.secondary)
                Button(action: onStart) {
                    Label("Start Scan", systemImage: "play.fill")
                        .padding(.horizontal, 6)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isGranted)
                .help(isGranted ? "Scan the Data volume" : "Turn on Full Disk Access first")
            }
            .opacity(isGranted ? 1 : 0.6)
        }
        // Wrapped text grows taller as it narrows; the floor keeps the split view's minimum-size
        // pass from measuring it at near-zero width and inflating the window's content.
        .frame(minWidth: 420, maxWidth: 560, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(number: Int, title: String, done: Bool,
                      @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "Done" : "Step \(number)")
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Tracks Full Disk Access and re-checks it whenever the app becomes active. Create one per
/// app and pass it down.
@MainActor @Observable
final class FullDiskAccessMonitor {
    private(set) var isGranted: Bool
    var isAdHocSigned: Bool { FullDiskAccess.isAdHocSignedBuild }
    private(set) var isRelaunching = false
    private(set) var relaunchError: String?

    init() {
        isGranted = FullDiskAccess.isGranted()
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
        isGranted = FullDiskAccess.isGranted()
    }
}

#Preview("Needs access") {
    StartScanView(isGranted: false, isAdHocSigned: true, isRelaunching: false, relaunchError: nil,
                  errorMessage: nil, onOpenSettings: {}, onQuitAndReopen: {}, onStart: {})
        .frame(width: 900, height: 600)
}

#Preview("Ready") {
    StartScanView(isGranted: true, isAdHocSigned: false, isRelaunching: false, relaunchError: nil,
                  errorMessage: "Scan cancelled.", onOpenSettings: {}, onQuitAndReopen: {}, onStart: {})
        .frame(width: 900, height: 600)
}
