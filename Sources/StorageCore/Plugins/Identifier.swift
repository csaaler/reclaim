import Foundation

/// Shape checks for the ids and names that definitions and inspectors declare. Shared by
/// `DefinitionValidator` and the inspector conformance tests, so both apply the same rules.
public enum Identifier {
    /// Empty, or only whitespace and newlines.
    public static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Lowercase ASCII letters, digits and single hyphens, not starting or ending with a hyphen
    /// (`demo-app`, `1password`).
    public static func isKebabCase(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix("-"), !id.hasSuffix("-"), !id.contains("--") else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// Two or more non-empty dot-separated labels of ASCII letters, digits and `-`
    /// (`com.example.App`, `notion.id`). `OwnerToken.looksLikeBundleID` is stricter, because it
    /// guesses from folder names.
    public static func isReverseDNS(_ bundleID: String) -> Bool {
        let labels = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
