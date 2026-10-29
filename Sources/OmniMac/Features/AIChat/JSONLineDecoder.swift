import Foundation

struct JSONLineDecoder {
    private var buffer = Data()

    mutating func feed(_ data: Data) throws -> [Any] {
        buffer.append(data)
        var result: [Any] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            result.append(try JSONSerialization.jsonObject(with: Data(line)))
        }
        return result
    }
}

struct BoundedDataBuffer {
    let limit: Int
    private(set) var data = Data()

    mutating func append(_ newData: Data) {
        data.append(newData)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }
}
