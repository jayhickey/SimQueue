// SPDX-License-Identifier: MIT

/// A map from target keys (`kind:rest`) to values, bucketed by key prefix (up to and
/// including the first `:`), so a pass that covers one prefix touches only that bucket.
public struct PrefixBuckets<Value: Sendable>: Sendable {
    public private(set) var buckets: [String: [String: Value]] = [:]

    public init() {}

    public init(_ values: [String: Value]) {
        for (key, value) in values { self[key] = value }
    }

    /// The bucket a key falls in: its prefix through the first `:`, or the whole key.
    public static func prefix(of key: String) -> String {
        guard let colon = key.firstIndex(of: ":") else { return key }
        return String(key[...colon])
    }

    public subscript(key: String) -> Value? {
        get { buckets[Self.prefix(of: key)]?[key] }
        set {
            let prefix = Self.prefix(of: key)
            if let newValue {
                buckets[prefix, default: [:]][key] = newValue
            } else if buckets[prefix]?.removeValue(forKey: key) != nil, buckets[prefix]?.isEmpty == true {
                buckets[prefix] = nil
            }
        }
    }

    /// Every entry whose key starts with `prefix` (a bucket prefix, e.g. `process_group:`).
    public func bucket(_ prefix: String) -> [String: Value] { buckets[prefix] ?? [:] }

    /// Replaces one bucket wholesale.
    public mutating func setBucket(_ prefix: String, _ values: [String: Value]) {
        buckets[prefix] = values.isEmpty ? nil : values
    }

    public var count: Int { buckets.values.reduce(0) { $0 + $1.count } }

    /// Every entry, flattened (cost grows with the whole map; not for per-pass paths).
    public var all: [String: Value] {
        var result: [String: Value] = [:]
        for bucket in buckets.values { result.merge(bucket) { first, _ in first } }
        return result
    }
}
