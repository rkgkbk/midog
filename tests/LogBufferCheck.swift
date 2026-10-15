@main
enum LogBufferCheck {
    static func main() {
        var buffer = LogBuffer<Int>(capacity: 100)
        for i in 0..<100_000 {
            buffer.append(i)
            precondition(buffer.count <= 100)
        }
        precondition(buffer.drain() == Array(99_900..<100_000))
        precondition(buffer.count == 0)
        precondition(buffer.drain().isEmpty)
        buffer.append(1)
        buffer.append(2)
        precondition(buffer.drain() == [1, 2])
        var single = LogBuffer<Int>(capacity: 1)
        single.append(1)
        single.append(2)
        precondition(single.drain() == [2])
        print("LogBuffer: burst, ordering, capacity, drain and reuse passed")
    }
}
