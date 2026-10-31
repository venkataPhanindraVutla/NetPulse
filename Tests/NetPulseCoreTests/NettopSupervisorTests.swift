import Foundation
import Testing
@testable import NetPulseCore

private let header = ",bytes_in,bytes_out,"
private let goodBlockLines = [header, "a.1,1,2,", header, "b.2,3,4,", header]

private struct LaunchError: Error {}

private final class FakeLauncher: LineProcessLaunching, @unchecked Sendable {
    enum Script {
        case lines([String], finish: Bool, terminateFinishes: Bool = true)
        case fail
    }

    private let lock = NSLock()
    private let scripts: (Int) -> Script
    private var launchCount = 0
    private var terminations = 0
    private var argumentLog: [[String]] = []
    let launches: AsyncStream<Int>
    private let launchContinuation: AsyncStream<Int>.Continuation

    init(_ scripts: @escaping (Int) -> Script) {
        self.scripts = scripts
        (launches, launchContinuation) = AsyncStream<Int>.makeStream()
    }

    var terminateCount: Int { lock.withLock { terminations } }
    var arguments: [[String]] { lock.withLock { argumentLog } }

    func launch(arguments: [String]) throws -> (lines: AsyncStream<String>, terminate: @Sendable () -> Void) {
        let index = lock.withLock { () -> Int in
            argumentLog.append(arguments)
            defer { launchCount += 1 }
            return launchCount
        }
        launchContinuation.yield(index)
        switch scripts(index) {
        case .fail:
            throw LaunchError()
        case let .lines(lines, finish, terminateFinishes):
            let (stream, continuation) = AsyncStream<String>.makeStream()
            for line in lines { continuation.yield(line) }
            if finish { continuation.finish() }
            return (stream, { [self] in
                lock.withLock { terminations += 1 }
                if terminateFinishes { continuation.finish() }
            })
        }
    }
}

private final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    var values: [Duration] { lock.withLock { recorded } }
    func record(_ d: Duration) { lock.withLock { recorded.append(d) } }
}

private func nextGap(_ iterator: inout AsyncStream<NettopEvent>.Iterator) async -> String? {
    while let event = await iterator.next() {
        if case let .gap(reason) = event { return reason }
    }
    return nil
}

private func makeSupervisor(
    launcher: FakeLauncher,
    interval: Int = 5,
    recorder: SleepRecorder = SleepRecorder(),
    stallTimer: @escaping @Sendable (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
) -> NettopSupervisor {
    NettopSupervisor(
        filter: .physical,
        interval: interval,
        launcher: launcher,
        sleep: { recorder.record($0) },
        stallTimer: stallTimer
    )
}

@Test(.timeLimit(.minutes(1))) func argumentsMatchSpec() async {
    let launcher = FakeLauncher { _ in .lines([], finish: false) }
    let supervisor = makeSupervisor(launcher: launcher)
    let stream = await supervisor.blocks()
    defer { _ = stream }
    var launches = launcher.launches.makeAsyncIterator()
    _ = await launches.next()
    #expect(launcher.arguments.first == ["-P", "-d", "-L", "0", "-s", "5", "-x", "-J", "bytes_in,bytes_out", "-t", "wifi", "-t", "wired"])
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1))) func emitsSamplesFromCompletedBlock() async {
    let launcher = FakeLauncher { _ in .lines([header, "x.9,1,1,", header, "a.1,1,2,", header, "b.2,3,4,", header], finish: false) }
    let supervisor = makeSupervisor(launcher: launcher)
    var iterator = await supervisor.blocks().makeAsyncIterator()
    let first = await iterator.next()
    guard case let .samples(samples)? = first else {
        Issue.record("expected samples, got \(String(describing: first))")
        return
    }
    #expect(samples == [ProcessSample(pid: 1, truncatedName: "a", bytesIn: 1, bytesOut: 2)])
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1))) func exitTriggersGapAndRestart() async {
    let recorder = SleepRecorder()
    let launcher = FakeLauncher { _ in .lines([], finish: true) }
    let supervisor = makeSupervisor(launcher: launcher, recorder: recorder)
    var iterator = await supervisor.blocks().makeAsyncIterator()
    #expect(await nextGap(&iterator) == "exited")
    #expect(await nextGap(&iterator) == "exited")
    #expect(recorder.values.first == .seconds(1))
    #expect(launcher.arguments.count >= 2)
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1))) func backoffSchedule() async {
    let recorder = SleepRecorder()
    let launcher = FakeLauncher { _ in .lines([], finish: true) }
    let supervisor = makeSupervisor(launcher: launcher, recorder: recorder)
    var iterator = await supervisor.blocks().makeAsyncIterator()
    for _ in 0..<6 { _ = await nextGap(&iterator) }
    #expect(Array(recorder.values.prefix(5)) == [.seconds(1), .seconds(5), .seconds(30), .seconds(60), .seconds(60)])
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1))) func successfulBlockResetsBackoff() async {
    let recorder = SleepRecorder()
    let launcher = FakeLauncher { index in
        index == 2 ? .lines(goodBlockLines, finish: true) : .lines([], finish: true)
    }
    let supervisor = makeSupervisor(launcher: launcher, recorder: recorder)
    var iterator = await supervisor.blocks().makeAsyncIterator()
    for _ in 0..<5 { _ = await nextGap(&iterator) }
    #expect(Array(recorder.values.prefix(4)) == [.seconds(1), .seconds(5), .seconds(1), .seconds(5)])
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1))) func launchFailureEmitsGapAndBacksOff() async {
    let recorder = SleepRecorder()
    let launcher = FakeLauncher { index in index < 2 ? .fail : .lines([], finish: true) }
    let supervisor = makeSupervisor(launcher: launcher, recorder: recorder)
    var iterator = await supervisor.blocks().makeAsyncIterator()
    #expect(await nextGap(&iterator) == "launch failed")
    #expect(await nextGap(&iterator) == "launch failed")
    #expect(await nextGap(&iterator) == "exited")
    #expect(Array(recorder.values.prefix(3)) == [.seconds(1), .seconds(5), .seconds(30)])
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1))) func unparseableOutputCountsAsStall() async {
    let launcher = FakeLauncher { _ in .lines(["garbage", "more garbage", header, "junk"], finish: false, terminateFinishes: false) }
    let fired = Counter()
    let supervisor = makeSupervisor(launcher: launcher, interval: 5, stallTimer: { delay in
        #expect(delay == .seconds(15))
        if fired.next() == 0 { return }
        try? await Task.sleep(for: .seconds(3600))
    })
    var iterator = await supervisor.blocks().makeAsyncIterator()
    #expect(await nextGap(&iterator) == "stalled")
    var launches = launcher.launches.makeAsyncIterator()
    _ = await launches.next()
    _ = await launches.next()
    #expect(launcher.terminateCount >= 1)
    await supervisor.stop()
}

private final class Gate: @unchecked Sendable {
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let release: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        (release, releaseContinuation) = AsyncStream<Void>.makeStream()
    }

    func pass() async {
        enteredContinuation.yield()
        for await _ in release { return }
    }

    func open() { releaseContinuation.yield() }
}

private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

@Test(.timeLimit(.minutes(1))) func stopTerminatesAndPreventsRelaunch() async {
    let gate = Gate()
    let launcher = FakeLauncher { _ in .lines([], finish: true) }
    let supervisor = NettopSupervisor(filter: .physical, interval: 5, launcher: launcher, sleep: { _ in await gate.pass() })
    let stream = await supervisor.blocks()
    var entered = gate.entered.makeAsyncIterator()
    _ = await entered.next()
    await supervisor.stop()
    gate.open()
    await settle()
    var iterator = stream.makeAsyncIterator()
    while await iterator.next() != nil {}
    #expect(launcher.arguments.count == 1)
}

@Test(.timeLimit(.minutes(1))) func stopTerminatesRunningChild() async {
    let launcher = FakeLauncher { _ in .lines([], finish: false) }
    let supervisor = makeSupervisor(launcher: launcher)
    let stream = await supervisor.blocks()
    defer { _ = stream }
    var launches = launcher.launches.makeAsyncIterator()
    _ = await launches.next()
    await supervisor.stop()
    #expect(launcher.terminateCount >= 1)
}

private func takeFirstSamples(_ stream: AsyncStream<NettopEvent>) async {
    for await event in stream {
        if case .samples = event { break }
    }
}

@Test(.timeLimit(.minutes(1))) func consumerDroppingStreamTerminatesAndStopsRelaunching() async {
    let launcher = FakeLauncher { _ in .lines(goodBlockLines, finish: false) }
    let supervisor = makeSupervisor(launcher: launcher)
    await takeFirstSamples(await supervisor.blocks())
    await settle()
    #expect(launcher.terminateCount >= 1)
    #expect(launcher.arguments.count == 1)
}

@Test(.timeLimit(.minutes(1))) func droppingSupervisorTerminatesChildAndFinishesStream() async {
    let launcher = FakeLauncher { _ in .lines([], finish: false) }
    var supervisor: NettopSupervisor? = makeSupervisor(launcher: launcher)
    let stream = await supervisor!.blocks()
    var launches = launcher.launches.makeAsyncIterator()
    _ = await launches.next()
    supervisor = nil
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    #expect(launcher.terminateCount >= 1)
    #expect(launcher.arguments.count == 1)
}

@Test(.timeLimit(.minutes(1))) func completedBlocksRearmStallTimerSoHealthyStreamNeverStalls() async {
    let lines = [header, "a.1,1,2,", header, "b.2,3,4,", header, "c.3,5,6,", header]
    let launcher = FakeLauncher { _ in .lines(lines, finish: false) }
    let (armed, armedContinuation) = AsyncStream<Duration>.makeStream()
    let supervisor = makeSupervisor(launcher: launcher, stallTimer: { delay in
        armedContinuation.yield(delay)
        try? await Task.sleep(for: .seconds(3600))
    })
    var events = await supervisor.blocks().makeAsyncIterator()
    var arms = armed.makeAsyncIterator()
    for _ in 0..<3 { _ = await arms.next() }
    guard case .samples? = await events.next(), case .samples? = await events.next() else {
        Issue.record("expected two sample blocks")
        return
    }
    #expect(launcher.terminateCount == 0)
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1))) func lockedBufferSplitsLinesAcrossChunks() {
    let buffer = LockedBuffer()
    #expect(buffer.append(Data("ab".utf8)).isEmpty)
    #expect(buffer.append(Data("c\r\nde".utf8)) == ["abc"])
    #expect(buffer.append(Data("f\ng\n".utf8)) == ["def", "g"])
    #expect(buffer.append(Data("tail".utf8)).isEmpty)
    #expect(buffer.flush() == "tail")
    #expect(buffer.flush() == nil)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}

private func childNettopCPUSeconds() throws -> [Double] {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-P", "\(getpid())", "nettop"]
    let out = Pipe()
    pgrep.standardOutput = out
    try pgrep.run()
    pgrep.waitUntilExit()
    let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(whereSeparator: \.isNewline).map(String.init)
    return try pids.compactMap { pid in
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "time=", "-p", pid]
        let psOut = Pipe()
        ps.standardOutput = psOut
        try ps.run()
        ps.waitUntilExit()
        let text = String(decoding: psOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}

// Both tests inspect this process's nettop children, so they must not overlap.
@Suite(.serialized) struct LiveNettopTests {
    @Test(.timeLimit(.minutes(1))) func liveNettopDeliversBlockAndLeavesNoChild() async throws {
        let supervisor = NettopSupervisor(filter: .physical, interval: 1, launcher: LiveNettopLauncher())
        let stream = await supervisor.blocks()
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream {
                    if case .samples = event { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        await supervisor.stop()
        #expect(received)

        try await Task.sleep(for: .milliseconds(500))
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", "\(getpid())", "nettop"]
        let out = Pipe()
        pgrep.standardOutput = out
        try pgrep.run()
        pgrep.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func liveNettopIdlesBetweenSamples() async throws {
        let launched = try LiveNettopLauncher().launch(arguments: ["-P", "-d", "-L", "0", "-s", "5", "-x", "-J", "bytes_in,bytes_out", "-t", "wifi", "-t", "wired"])
        defer { launched.terminate() }
        try await Task.sleep(for: .seconds(3))
        let cpu = try childNettopCPUSeconds()
        #expect(!cpu.isEmpty)
        #expect(cpu.allSatisfy { $0 < 1.0 }, "nettop CPU seconds after 3 s: \(cpu)")
    }
}
