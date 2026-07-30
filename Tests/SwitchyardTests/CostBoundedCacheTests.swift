import Testing
@testable import Switchyard

@Suite("Cost Bounded Cache")
struct CostBoundedCacheTests {
    @Test("evicts the least recently used values by cost")
    func evictsByCostAndRecency() {
        var cache = CostBoundedCache<String, String>(costLimit: 12)

        #expect(cache.insert("A", cost: 6, forKey: "a").evictedCost == 0)
        #expect(cache.insert("B", cost: 4, forKey: "b").evictedCost == 0)
        #expect(cache.value(forKey: "a") == "A")
        let result = cache.insert("C", cost: 5, forKey: "c")

        #expect(result == .init(wasStored: true, evictedCost: 4))
        #expect(cache.valueWithoutUpdatingRecency(forKey: "a") == "A")
        #expect(cache.valueWithoutUpdatingRecency(forKey: "b") == nil)
        #expect(cache.valueWithoutUpdatingRecency(forKey: "c") == "C")
        #expect(cache.totalCost == 11)
    }

    @Test("replacement updates cost without evicting unrelated values")
    func replacementUpdatesCost() {
        var cache = CostBoundedCache<String, String>(costLimit: 10)
        cache.insert("old", cost: 7, forKey: "a")
        cache.insert("B", cost: 3, forKey: "b")

        let result = cache.insert("new", cost: 2, forKey: "a")

        #expect(result == .init(wasStored: true, evictedCost: 0))
        #expect(cache.valueWithoutUpdatingRecency(forKey: "a") == "new")
        #expect(cache.valueWithoutUpdatingRecency(forKey: "b") == "B")
        #expect(cache.totalCost == 5)
    }

    @Test("oversized replacements invalidate only the replaced key")
    func oversizedValuesAreNotStored() {
        var cache = CostBoundedCache<String, String>(costLimit: 8)
        cache.insert("A", cost: 4, forKey: "a")
        cache.insert("B", cost: 4, forKey: "b")

        let result = cache.insert("huge", cost: 9, forKey: "a")

        #expect(result == .init(wasStored: false, evictedCost: 0))
        #expect(cache.valueWithoutUpdatingRecency(forKey: "a") == nil)
        #expect(cache.valueWithoutUpdatingRecency(forKey: "b") == "B")
        #expect(cache.totalCost == 4)
    }

    @Test("a zero cost limit rejects even normalized zero-cost values")
    func zeroLimitRejectsValues() {
        var cache = CostBoundedCache<String, String>(costLimit: 0)

        let result = cache.insert("A", cost: 0, forKey: "a")

        #expect(result == .init(wasStored: false, evictedCost: 0))
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
    }

    @Test("zero cost values still consume bounded capacity")
    func zeroCostIsNormalized() {
        var cache = CostBoundedCache<String, String>(costLimit: 2)

        cache.insert("A", cost: 0, forKey: "a")
        cache.insert("B", cost: 0, forKey: "b")
        let result = cache.insert("C", cost: 0, forKey: "c")

        #expect(result == .init(wasStored: true, evictedCost: 1))
        #expect(cache.count == 2)
        #expect(cache.totalCost == 2)
        #expect(cache.valueWithoutUpdatingRecency(forKey: "a") == nil)
    }

    @Test("remove and clear keep the tracked cost exact")
    func removalAndClear() {
        var cache = CostBoundedCache<String, String>(costLimit: 10)
        cache.insert("A", cost: 3, forKey: "a")
        cache.insert("B", cost: 4, forKey: "b")

        #expect(cache.removeValue(forKey: "a") == "A")
        #expect(cache.totalCost == 4)
        cache.removeAll(keepingCapacity: true)
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
    }
}
