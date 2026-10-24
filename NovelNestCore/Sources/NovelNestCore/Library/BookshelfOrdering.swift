import Foundation

/// The fields the bookshelf sorts on. The app's SwiftData `Book` conforms.
public protocol BookshelfItem {
    var title: String { get }
    var createdAt: Date { get }
    var lastOpenedAt: Date? { get }
}

/// Bookshelf order (spec §6): `lastOpenedAt DESC NULLS LAST`.
///
/// Never-opened books follow, newest import first; title breaks ties so the
/// order is stable across launches.
public enum BookshelfOrdering {
    public static func sorted<Item: BookshelfItem>(_ items: [Item]) -> [Item] {
        items.sorted { areInIncreasingOrder($0, $1) }
    }

    public static func areInIncreasingOrder(_ a: some BookshelfItem, _ b: some BookshelfItem) -> Bool {
        switch (a.lastOpenedAt, b.lastOpenedAt) {
        case let (aOpened?, bOpened?) where aOpened != bOpened:
            return aOpened > bOpened
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil) where a.createdAt != b.createdAt:
            return a.createdAt > b.createdAt
        default:
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}
