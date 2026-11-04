import SwiftUI
import StorageCore

struct ReviewView: View {
    @Bindable var model: CleanupReviewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.entries.isEmpty {
                ContentUnavailableView("The cleanup list is empty", systemImage: "cart",
                                       description: Text("Add items from By App, By Category or Dev Tools."))
            } else {
                List {
                    ForEach(model.entries) { entry in
                        Section {
                            if let error = entry.planError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            } else if entry.steps.isEmpty {
                                Text(entry.nothingToDo ?? "Nothing to do for \(entry.candidate.displayTitle).")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(entry.planNotes, id: \.self) { note in
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(entry.steps) { step in
                                StepRow(model: model, step: step,
                                        whatYouLose: step.acknowledgementText(default: entry.candidate.whatYouLose),
                                        lossDescription: entry.candidate.lossDescription)
                            }
                        } header: {
                            HStack {
                                Text(entry.candidate.displayTitle)
                                Spacer()
                                Button("Remove") { model.remove(entry) }
                                    .buttonStyle(.borderless)
                                    .disabled(model.phase != .reviewing)
                                    .help("Take this off the cleanup list")
                            }
                        }
                    }
                }
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Review cleanup").font(.title2.weight(.semibold))
            Spacer()
            Button("Check again") { Task { await model.refreshBlockers() } }
                .disabled(model.phase != .reviewing || model.isCheckingBlockers)
                .help("Re-check running apps and paths")
        }
        .padding(16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Frees \(ByteText.string(model.freesNowBytes)) now · \(ByteText.string(model.trashBytes)) after emptying Trash")
                .font(.headline)
                .monospacedDigit()
            if let message = model.preExecutionMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            HStack {
                if model.phase == .executing {
                    ProgressView().controlSize(.small)
                    Text(model.cancelRequested ? "Stopping — stops after the current step." : "Cleaning up…")
                        .foregroundStyle(.secondary)
                } else if let hint = model.confirmHint {
                    Text(hint).foregroundStyle(.secondary)
                }
                Spacer()
                if model.phase == .executing {
                    Button("Stop") { model.cancelExecution() }
                        .disabled(model.cancelRequested)
                        .help("Stops after the current step. The current step is not undone.")
                } else {
                    // Return closes the review; no key ever confirms a deletion.
                    Button("Cancel", action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
                Button("Confirm cleanup") { Task { await model.confirm() } }
                    .disabled(!model.canConfirm)
            }
        }
        .padding(16)
    }
}

private struct StepRow: View {
    @Bindable var model: CleanupReviewModel
    let step: CleanupStep
    let whatYouLose: String
    /// The candidate's own description of what is lost, shown for every risk level.
    let lossDescription: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                    Text(step.target)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(step.fullTarget)
                }
                Spacer()
                RiskBadge(risk: step.risk)
                ByteText(bytes: step.estimatedBytes)
                    .frame(width: 80, alignment: .trailing)
            }
            Label(step.methodTitle, systemImage: step.methodSymbol)
                .font(.caption)
                .foregroundStyle(step.isIrreversible ? .primary : .secondary)
            if let lossDescription, lossDescription != step.sideEffectNote {
                Text(lossDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = step.sideEffectNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array((model.blockers[step.id] ?? []).enumerated()), id: \.offset) { _, blocker in
                BlockerRow(model: model, blocker: blocker)
            }
            if step.risk == .userData {
                Toggle(isOn: Binding(
                    get: { model.acknowledged.contains(step.id) },
                    set: { model.setAcknowledged($0, for: step) }
                )) {
                    Text("I understand \(whatYouLose)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .disabled(model.phase != .reviewing)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BlockerRow: View {
    @Bindable var model: CleanupReviewModel
    let blocker: Blocker

    var body: some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.orange)
            if case .appRunning(let rawName, let bundleIDs) = blocker {
                let name = CleanupReviewModel.appDisplayName(rawName, bundleIDs: bundleIDs)
                if bundleIDs.isEmpty {
                    Text("Quit \(name) yourself, then Check again.").font(.caption).foregroundStyle(.secondary)
                } else if model.quitting.contains(rawName) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(name) to quit…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Quit \(name)") { Task { await model.quit(name: rawName, bundleIDs: bundleIDs) } }
                        .controlSize(.small)
                        .disabled(model.phase != .reviewing)
                        .help("Asks \(name) to quit normally. It is never force-quit.")
                    if model.quitFailures.contains(rawName) {
                        Text("\(name) did not quit. Quit it yourself, then Check again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var message: String {
        if case .appRunning(let rawName, let bundleIDs) = blocker {
            return "\(CleanupReviewModel.appDisplayName(rawName, bundleIDs: bundleIDs)) is running. Quit it first."
        }
        return blocker.message
    }
}
