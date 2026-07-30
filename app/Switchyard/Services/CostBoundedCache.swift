import Foundation

struct CostBoundedCache<Key: Hashable, Value> {
    struct InsertionResult: Equatable {
        let wasStored: Bool
        let evictedCost: Int
    }

    private struct Entry {
        var value: Value
        var cost: Int
        var lastAccess: UInt64
    }

    let costLimit: Int
    private(set) var totalCost = 0
    private var entries: [Key: Entry] = [:]
    private var accessSequence: UInt64 = 0

    init(costLimit: Int) {
        self.costLimit = max(0, costLimit)
    }

    var count: Int {
        entries.count
    }

    mutating func value(forKey key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        entry.lastAccess = nextAccessSequence()
        entries[key] = entry
        return entry.value
    }

    func valueWithoutUpdatingRecency(forKey key: Key) -> Value? {
        entries[key]?.value
    }

    @discardableResult
    mutating func insert(
        _ value: Value,
        cost: Int,
        forKey key: Key
    ) -> InsertionResult {
        let normalizedCost = max(1, cost)
        if let replaced = entries.removeValue(forKey: key) {
            totalCost -= replaced.cost
        }

        guard normalizedCost <= costLimit else {
            return InsertionResult(wasStored: false, evictedCost: 0)
        }

        var evictedCost = 0
        while totalCost > costLimit - normalizedCost,
              let evictionKey = leastRecentlyUsedKey() {
            guard let evicted = entries.removeValue(forKey: evictionKey) else {
                break
            }
            totalCost -= evicted.cost
            evictedCost += evicted.cost
        }

        entries[key] = Entry(
            value: value,
            cost: normalizedCost,
            lastAccess: nextAccessSequence()
        )
        totalCost += normalizedCost
        return InsertionResult(
            wasStored: true,
            evictedCost: evictedCost
        )
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let removed = entries.removeValue(forKey: key) else {
            return nil
        }
        totalCost -= removed.cost
        return removed.value
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        totalCost = 0
        accessSequence = 0
    }

    private func leastRecentlyUsedKey() -> Key? {
        entries.min { lhs, rhs in
            lhs.value.lastAccess < rhs.value.lastAccess
        }?.key
    }

    private mutating func nextAccessSequence() -> UInt64 {
        if accessSequence == .max {
            normalizeAccessSequences()
        }
        accessSequence += 1
        return accessSequence
    }

    private mutating func normalizeAccessSequences() {
        let orderedKeys = entries
            .sorted { lhs, rhs in
                lhs.value.lastAccess < rhs.value.lastAccess
            }
            .map(\.key)
        accessSequence = 0
        for key in orderedKeys {
            accessSequence += 1
            entries[key]?.lastAccess = accessSequence
        }
    }
}
