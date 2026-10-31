public struct Speed: Sendable, Equatable {
    public var down: Double
    public var up: Double

    public init(down: Double, up: Double) {
        self.down = down
        self.up = up
    }

    public static let zero = Speed(down: 0, up: 0)
}

public struct SpeedCalculator: Sendable {
    private var last: (rx: UInt64, tx: UInt64, at: ContinuousClock.Instant)?

    public init() {}

    public mutating func update(totalRx: UInt64, totalTx: UInt64, at: ContinuousClock.Instant) -> Speed {
        guard let prev = last else {
            last = (totalRx, totalTx, at)
            return .zero
        }
        let elapsed = prev.at.duration(to: at)
        guard elapsed > .zero else { return .zero }
        last = (totalRx, totalTx, at)
        guard totalRx >= prev.rx, totalTx >= prev.tx else { return .zero }
        let c = elapsed.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        return Speed(
            down: Double(totalRx - prev.rx) / seconds,
            up: Double(totalTx - prev.tx) / seconds)
    }

    public mutating func reset() { last = nil }
}
