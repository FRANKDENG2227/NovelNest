import Foundation

/// Recent search terms, newest first, without repeats.
public struct SearchHistory: Equatable, Sendable {
    public static let limit = 6

    public private(set) var terms: [String]

    public init(terms: [String] = []) {
        self.terms = Array(terms.prefix(Self.limit))
    }

    /// Stored as one term per line.
    public init(stored: String) {
        self.init(terms: stored.split(separator: "\n").map(String.init))
    }

    public var stored: String { terms.joined(separator: "\n") }

    /// Puts the term first; an earlier identical search (ignoring spaces at
    /// either end) moves up instead of repeating. The oldest falls off.
    public mutating func add(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !term.isEmpty else { return }
        terms.removeAll { $0 == term }
        terms.insert(term, at: 0)
        terms = Array(terms.prefix(Self.limit))
    }

    public mutating func remove(_ term: String) {
        terms.removeAll { $0 == term }
    }
}
