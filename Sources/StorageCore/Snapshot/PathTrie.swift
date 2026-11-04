import Foundation

/// What a trie node stands for: where the snapshot walk stops, or that it only passes through.
enum TrieTarget {
    case claim(String)
    case definition(Int, Int)
    case rule
    case appFolder
    case descend
}

/// A segment trie over folded absolute paths; `*` segments are globs.
final class TrieNode {
    var literal: [String: TrieNode] = [:]
    var globs: [(pattern: String, node: TrieNode)] = []
    var targets: [TrieTarget] = []
    /// A claim or definition location lies strictly below.
    var strongBelow = false
    /// Definitions with a location strictly below.
    var definitionsBelow: Set<Int> = []

    var hasChildren: Bool { !literal.isEmpty || !globs.isEmpty }

    func insert(_ segments: [String], target: TrieTarget) {
        var node = self
        for segment in segments {
            switch target {
            case .claim: node.strongBelow = true
            case .definition(let d, _): node.strongBelow = true; node.definitionsBelow.insert(d)
            default: break
            }
            if segment.contains("*") {
                if let existing = node.globs.first(where: { $0.pattern == segment }) {
                    node = existing.node
                } else {
                    let next = TrieNode()
                    node.globs.append((segment, next))
                    node = next
                }
            } else if let next = node.literal[segment] {
                node = next
            } else {
                let next = TrieNode()
                node.literal[segment] = next
                node = next
            }
        }
        node.targets.append(target)
    }

    /// The nodes reached from this one by a folded path segment.
    func next(_ folded: String) -> [TrieNode] {
        var result: [TrieNode] = []
        if let node = literal[folded] { result.append(node) }
        for glob in globs where PathPattern.globMatches(glob.pattern, folded) { result.append(glob.node) }
        return result
    }

    /// The folded segments of `path`, the form the trie stores.
    static func segments(_ path: String) -> [String] {
        PathKey(path).foldedSegments.map(String.init)
    }
}
