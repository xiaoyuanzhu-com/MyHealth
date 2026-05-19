import Foundation

/// Merges incoming samples into an existing remote snapshot. Two passes:
///   1. Dedup by UUID — same UUID → keep incoming (new wins).
///   2. Sort by `(start, end, source)` per spec.
enum SnapshotMerger {

    static func merge(existing: [QuantitySample], incoming: [QuantitySample]) -> [QuantitySample] {
        var byUUID: [String: QuantitySample] = [:]
        var orderless: [QuantitySample] = []
        for s in existing { append(s, into: &byUUID, orderless: &orderless) }
        for s in incoming { append(s, into: &byUUID, orderless: &orderless) }
        let combined = orderless + byUUID.values
        return combined.sorted(by: compare)
    }

    static func mergeCategory(existing: [CategorySample], incoming: [CategorySample]) -> [CategorySample] {
        var byUUID: [String: CategorySample] = [:]
        var orderless: [CategorySample] = []
        for s in existing { appendCat(s, into: &byUUID, orderless: &orderless) }
        for s in incoming { appendCat(s, into: &byUUID, orderless: &orderless) }
        let combined = orderless + byUUID.values
        return combined.sorted(by: compareCat)
    }

    // MARK: - private

    private static func append(_ s: QuantitySample,
                               into dict: inout [String: QuantitySample],
                               orderless: inout [QuantitySample]) {
        if let u = s.uuid { dict[u] = s } else { orderless.append(s) }
    }

    private static func appendCat(_ s: CategorySample,
                                  into dict: inout [String: CategorySample],
                                  orderless: inout [CategorySample]) {
        if let u = s.uuid { dict[u] = s } else { orderless.append(s) }
    }

    private static func compare(_ a: QuantitySample, _ b: QuantitySample) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        return a.source < b.source
    }

    private static func compareCat(_ a: CategorySample, _ b: CategorySample) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        return a.source < b.source
    }
}
