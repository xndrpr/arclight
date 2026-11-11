extension Array {
    /// The element at `i`, or nil when `i` is out of range.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension Sequence {
    /// The first element for each distinct `key`, in order.
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
