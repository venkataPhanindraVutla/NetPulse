public struct InterfaceDelta: Sendable, Equatable {
    public let name: String
    public let kind: InterfaceKind
    public let rx: UInt64
    public let tx: UInt64

    public init(name: String, kind: InterfaceKind, rx: UInt64, tx: UInt64) {
        self.name = name
        self.kind = kind
        self.rx = rx
        self.tx = tx
    }
}

public enum Discontinuity: Sendable, Equatable {
    case counterReset(String)
    case appeared(String)
    case disappeared(String)
}

public struct DeltaTracker: Sendable {
    private struct Baseline: Sendable {
        var rx: UInt64
        var tx: UInt64
    }

    private var baselines: [String: Baseline] = [:]
    private var hasIngested = false

    public init() {}

    public mutating func ingest(_ counters: [InterfaceCounter])
        -> (deltas: [InterfaceDelta], discontinuities: [Discontinuity])
    {
        let physical = counters.filter { $0.kind.isPhysical }.sorted { $0.name < $1.name }
        let present = Set(physical.map(\.name))
        var deltas: [InterfaceDelta] = []
        var discontinuities: [Discontinuity] = []

        for name in baselines.keys.sorted() where !present.contains(name) {
            baselines[name] = nil
            discontinuities.append(.disappeared(name))
        }

        for c in physical {
            if let base = baselines[c.name] {
                if c.rxBytes < base.rx || c.txBytes < base.tx {
                    discontinuities.append(.counterReset(c.name))
                } else {
                    deltas.append(InterfaceDelta(
                        name: c.name, kind: c.kind,
                        rx: c.rxBytes - base.rx, tx: c.txBytes - base.tx))
                }
            } else if hasIngested {
                discontinuities.append(.appeared(c.name))
            }
            baselines[c.name] = Baseline(rx: c.rxBytes, tx: c.txBytes)
        }

        hasIngested = true
        return (deltas, discontinuities)
    }

    public mutating func reset() {
        baselines.removeAll()
        hasIngested = false
    }
}
