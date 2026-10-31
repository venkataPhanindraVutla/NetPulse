import Darwin
import Foundation
import NetPulseCore

struct Options {
    var seconds = 60
    var db: String?
    var network = false
    var nettopInterval = 5
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--seconds": options.seconds = number(args.next())
        case "--db":
            guard let path = args.next() else { usage() }
            options.db = path
        case "--network": options.network = true
        case "--nettop-interval": options.nettopInterval = number(args.next())
        default: usage()
        }
    }
    return options
}

func number(_ text: String?) -> Int {
    guard let value = text.flatMap(Int.init), value > 0 else { usage() }
    return value
}

func usage() -> Never {
    print("usage: netpulse-probe [--seconds N] [--db PATH] [--nettop-interval N] | --network")
    exit(2)
}

func printNetwork() {
    let detector = SystemNetworkDetector()
    if let primary = detector.primary() {
        print("primary: \(primary)")
        print("key: \(NetworkIdentity.key(for: primary).map { String(describing: $0) } ?? "nil")")
    } else {
        print("primary: none")
    }
    for observation in detector.activePhysical() {
        print("active: \(observation.interfaceName) key=\(NetworkIdentity.key(for: observation)?.fingerprint ?? "nil")")
    }
}

func ratio(_ part: UInt64, _ whole: UInt64) -> String {
    whole == 0 ? "n/a" : String(format: "%.3f", Double(part) / Double(whole))
}

func summarize(store: UsageStore, since start: Date) async throws {
    let interval = DateInterval(
        start: Date(timeIntervalSince1970: TimeInterval(PeriodBoundaries.bucketStart(start))),
        end: Date().addingTimeInterval(900))
    print("\n== networks")
    for network in try await store.networks() {
        let t = try await store.totals(network: network.id, in: interval)
        print("\(network.displayName) [\(network.key.fingerprint)]: ↓ \(ByteFormatter.bytes(t.down)) (\(t.down) B) ↑ \(ByteFormatter.bytes(t.up)) (\(t.up) B)")
    }
    let total = try await store.totals(network: nil, in: interval)
    let usage = try await store.appUsage(network: nil, in: interval)
    let apps = usage.filter { $0.id != "other" }
    print("\n== top apps")
    for app in apps.prefix(10) {
        print("\(app.displayName) [\(app.id)]: ↓ \(ByteFormatter.bytes(app.down)) ↑ \(ByteFormatter.bytes(app.up))")
    }
    if let other = usage.first(where: { $0.id == "other" }) {
        print("Other / system: ↓ \(ByteFormatter.bytes(other.down)) ↑ \(ByteFormatter.bytes(other.up))")
    }
    let appsDown = apps.reduce(UInt64(0)) { $0 + $1.down }
    let appsUp = apps.reduce(UInt64(0)) { $0 + $1.up }
    print("\n== Σapps/total: down \(ratio(appsDown, total.down)) (\(appsDown)/\(total.down)), up \(ratio(appsUp, total.up)) (\(appsUp)/\(total.up))")
}

func run(_ options: Options) async throws {
    let path = options.db ?? NSTemporaryDirectory() + "netpulse-probe-\(getpid()).sqlite"
    print("db: \(path)")
    let store = try UsageStore(path: path)
    let engine = MonitorEngine(
        store: store,
        reader: SysctlInterfaceReader(),
        detector: SystemNetworkDetector(),
        resolver: AppResolver(provider: LiveProcessInfoProvider()),
        launcher: LiveNettopLauncher(),
        nettopInterval: options.nettopInterval)

    let (stop, stopContinuation) = AsyncStream<String>.makeStream()
    var sources: [any DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { stopContinuation.yield("signal \(sig)") }
        source.resume()
        sources.append(source)
    }
    let seconds = options.seconds
    let deadline = Task {
        try? await Task.sleep(for: .seconds(seconds))
        stopContinuation.yield("deadline")
    }

    let startedAt = Date()
    await engine.start()
    let snapshots = await engine.snapshots()
    let printer = Task {
        var lastPrint = ContinuousClock.now - .seconds(1)
        for await s in snapshots {
            guard ContinuousClock.now - lastPrint >= .milliseconds(900) else { continue }
            lastPrint = .now
            var line = "↓ \(ByteFormatter.rate(s.speed.down, unit: .bytesPerSecond)) ↑ \(ByteFormatter.rate(s.speed.up, unit: .bytesPerSecond))  net=\(s.primaryNetwork?.displayName ?? "-")"
            if s.state != .monitoring { line += "  state=\(s.state)" }
            if !s.appTrackingAvailable { line += "  apps=unavailable" }
            print(line)
            fflush(stdout)
        }
    }

    var reasons = stop.makeAsyncIterator()
    let reason = await reasons.next() ?? "stream ended"
    print("stopping: \(reason)")
    deadline.cancel()
    printer.cancel()
    await engine.pause()
    await engine.flush()
    try await summarize(store: store, since: startedAt)
    try? await Task.sleep(for: .milliseconds(500))
    sources.forEach { $0.cancel() }
}

let options = parseOptions()
if options.network {
    printNetwork()
    exit(0)
}
do {
    try await run(options)
} catch {
    print("error: \(error)")
    exit(1)
}
