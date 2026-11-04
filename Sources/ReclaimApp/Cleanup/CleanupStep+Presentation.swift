import Foundation
import StorageCore

enum StepMethod: Equatable {
    case delete, trash, runTool, editFile
}

extension CleanupStep {
    /// How the engine will actually perform this step (`effectiveAction`, so a 🔴 delete shows
    /// as a move to the Trash).
    var method: StepMethod {
        switch effectiveAction {
        case .delete: .delete
        case .trash: .trash
        case .runTool: .runTool
        case .removeJSONKeys: .editFile
        }
    }

    var methodTitle: String {
        switch method {
        case .delete: "Delete permanently"
        case .trash: "Move to Trash — frees space after emptying Trash"
        case .runTool: "Runs command (irreversible)"
        case .editFile: "Edits this file — the original is backed up to the Trash first"
        }
    }

    var methodSymbol: String {
        switch method {
        case .delete: "xmark.bin"
        case .trash: "trash"
        case .runTool: "terminal"
        case .editFile: "doc.badge.gearshape"
        }
    }

    /// The path, or the tool command (executable and arguments, quoted as a shell would need).
    var target: String {
        switch effectiveAction {
        case .delete(let path, _), .trash(let path, _), .removeJSONKeys(let path, _): abbreviatedPath(path)
        case .runTool(let executable, let arguments): Self.commandLine(executable, arguments)
        }
    }

    var fullTarget: String {
        switch effectiveAction {
        case .delete(let path, _), .trash(let path, _), .removeJSONKeys(let path, _): path
        case .runTool(let executable, let arguments): Self.commandLine(executable, arguments)
        }
    }

    /// What the 🔴 checkbox says after "I understand ": the step's own `acknowledgement` when it
    /// has one, else `whatYouLose` from its item. A file edit without one names the file, so it
    /// is never acknowledged with wording meant for removing the item.
    func acknowledgementText(default whatYouLose: String) -> String {
        if let acknowledgement { return acknowledgement }
        guard case .removeJSONKeys(let path, _) = effectiveAction else { return whatYouLose }
        return "\(abbreviatedPath(path)) will be edited (a backup goes to the Trash)"
    }

    /// `executable` and `arguments` joined with spaces, each quoted only when a shell would need it,
    /// so an argument containing a space reads as one argument.
    static func commandLine(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuoted).joined(separator: " ")
    }

    /// `word` unchanged when it has only characters a shell leaves alone, otherwise in single
    /// quotes (with each `'` written as `'\''`). An empty word becomes `''`.
    static func shellQuoted(_ word: String) -> String {
        let plain = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,+@%")
        if !word.isEmpty, word.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
