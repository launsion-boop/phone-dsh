// SPDX-License-Identifier: MIT
// Bounded NSCache for derived render artifacts.
//
// NSCache enforces its own advisory limits, but a test needs deterministic
// count/cost bounds. This wrapper therefore mirrors every insert/remove and
// evicts FIFO when the documented count or byte budget is exceeded, while the
// actual storage (and the memory-pressure purge) stays an NSCache.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class NativeBoundedCache<Key: Hashable, Value> {
    private final class Box {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    let countLimit: Int
    let totalCostLimit: Int
    let name: String

    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var order: [Key] = []
    private var costs: [Key: Int] = [:]
    private var costSum = 0
    private var memoryWarningObserver: NSObjectProtocol?
    public private(set) var hitCount = 0
    public private(set) var missCount = 0

    public init(name: String, countLimit: Int, totalCostLimit: Int) {
        self.name = name
        self.countLimit = max(1, countLimit)
        self.totalCostLimit = max(1, totalCostLimit)
        cache.name = name
        cache.countLimit = self.countLimit
        cache.totalCostLimit = self.totalCostLimit
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
        #endif
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return costs.count
    }

    public var approximateCost: Int {
        lock.lock(); defer { lock.unlock() }
        return costSum
    }

    public func value(forKey key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        if let box = cache.object(forKey: nsKey(key)) {
            hitCount += 1
            return box.value
        }
        missCount += 1
        // NSCache may evict on its own; drop bookkeeping that no longer has a
        // backing entry so the cost/count mirrors the live cache as closely as
        // possible.
        if let cost = costs.removeValue(forKey: key) {
            costSum -= cost
            order.removeAll { $0 == key }
        }
        return nil
    }

    public func insert(_ value: Value, forKey key: Key, cost: Int) {
        let cost = max(0, cost)
        lock.lock(); defer { lock.unlock() }
        if let old = costs.removeValue(forKey: key) {
            costSum -= old
            order.removeAll { $0 == key }
        }
        cache.setObject(Box(value), forKey: nsKey(key), cost: cost)
        costs[key] = cost
        costSum += cost
        order.append(key)
        evictIfNeeded()
    }

    public func removeValue(forKey key: Key) {
        lock.lock(); defer { lock.unlock() }
        cache.removeObject(forKey: nsKey(key))
        if let cost = costs.removeValue(forKey: key) {
            costSum -= cost
            order.removeAll { $0 == key }
        }
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAllObjects()
        order.removeAll()
        costs.removeAll()
        costSum = 0
    }

    public func resetStatistics() {
        lock.lock(); defer { lock.unlock() }
        hitCount = 0
        missCount = 0
    }

    private func evictIfNeeded() {
        while !order.isEmpty && (order.count > countLimit || costSum > totalCostLimit) {
            let oldest = order.removeFirst()
            if let cost = costs.removeValue(forKey: oldest) {
                costSum -= cost
                cache.removeObject(forKey: nsKey(oldest))
            }
        }
    }

    private func nsKey(_ key: Key) -> NSString {
        NSString(string: String(describing: key))
    }
}
