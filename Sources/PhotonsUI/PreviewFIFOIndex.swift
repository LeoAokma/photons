/// A bounded insertion-order index. Updating a resident digest keeps its original position.
struct PreviewFIFOIndex<Value> {
    let limit: Int
    private var values: [String: Value] = [:]
    private var keys: [String] = []
    private var oldest = 0

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    subscript(_ digest: String) -> Value? { values[digest] }

    mutating func store(_ value: Value, for digest: String) {
        guard values.updateValue(value, forKey: digest) == nil else { return }
        if keys.count < limit {
            keys.append(digest)
        } else {
            values.removeValue(forKey: keys[oldest])
            keys[oldest] = digest
            oldest = (oldest + 1) % limit
        }
    }
}
