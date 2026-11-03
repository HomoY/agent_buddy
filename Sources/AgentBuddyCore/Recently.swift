import Foundation

/// Answers kept for a moment: asked again within it (by another agent window,
/// say), they're not worked out again.
public final class Recently<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let lifetime: TimeInterval
    private var kept: [Key: (value: Value, at: Date)] = [:]

    public init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    public func value(_ key: Key, _ make: () -> Value) -> Value {
        lock.lock()
        if let hit = kept[key], Date().timeIntervalSince(hit.at) < lifetime {
            lock.unlock()
            return hit.value
        }
        lock.unlock()
        let value = make()
        lock.lock()
        defer { lock.unlock() }
        if kept.count > 64 {
            kept = kept.filter { Date().timeIntervalSince($0.value.at) < lifetime }
        }
        kept[key] = (value, Date())
        return value
    }
}
