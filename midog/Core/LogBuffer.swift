/// Fixed-capacity FIFO: a log burst must not grow memory or shift an array per line.
nonisolated struct LogBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        if count == storage.count {
            storage[head] = element
            head = (head + 1) % storage.count
        } else {
            storage[(head + count) % storage.count] = element
            count += 1
        }
    }

    mutating func drain() -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            let index = (head + offset) % storage.count
            if let element = storage[index] { result.append(element) }
            storage[index] = nil
        }
        head = 0
        count = 0
        return result
    }
}
