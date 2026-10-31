public struct ProcessSample: Sendable, Equatable {
    public let pid: Int32
    public let truncatedName: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(pid: Int32, truncatedName: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.pid = pid
        self.truncatedName = truncatedName
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct NettopParser: Sendable {
    public private(set) var malformedLineCount = 0
    private var headersSeen = 0
    private var current: [ProcessSample] = []

    public init() {}

    public mutating func consume(line: String) -> [ProcessSample]? {
        if line.hasPrefix(",bytes_in") {
            headersSeen += 1
            let completed = current
            current = []
            return headersSeen >= 3 ? completed : nil
        }
        guard !line.allSatisfy(\.isWhitespace) else { return nil }
        if let sample = Self.parseRow(line) {
            if headersSeen >= 1 { current.append(sample) }
        } else {
            malformedLineCount += 1
        }
        return nil
    }

    /// `name.pid,bytes_in,bytes_out,` read from the right, so a process name containing a comma still parses.
    static func parseRow(_ line: String) -> ProcessSample? {
        var fields = line.split(separator: ",", omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count >= 3,
              let bytesOut = UInt64(fields[fields.count - 1]),
              let bytesIn = UInt64(fields[fields.count - 2])
        else { return nil }
        let head = fields[..<(fields.count - 2)].joined(separator: ",")
        guard let dot = head.lastIndex(of: "."), let pid = Int32(head[head.index(after: dot)...]) else { return nil }
        return ProcessSample(pid: pid, truncatedName: String(head[..<dot]), bytesIn: bytesIn, bytesOut: bytesOut)
    }
}
