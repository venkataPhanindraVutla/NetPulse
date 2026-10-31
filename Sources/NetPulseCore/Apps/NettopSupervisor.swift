import Foundation

public enum NettopFilter: String, Sendable {
    /// Wi-Fi and wired together. `-t external` would also count utun, so a userspace VPN's traffic would be counted
    /// twice (tunnel and uplink); measured coverage without a VPN is identical.
    case physical, wifi, wired

    var interfaceTypes: [String] {
        switch self {
        case .physical: ["wifi", "wired"]
        case .wifi: ["wifi"]
        case .wired: ["wired"]
        }
    }
}

public enum NettopEvent: Sendable {
    case samples([ProcessSample])
    case gap(reason: String)
}

public protocol LineProcessLaunching: Sendable {
    func launch(arguments: [String]) throws -> (lines: AsyncStream<String>, terminate: @Sendable () -> Void)
}

public struct LiveNettopLauncher: LineProcessLaunching {
    public init() {}

    public func launch(arguments: [String]) throws -> (lines: AsyncStream<String>, terminate: @Sendable () -> Void) {
        // nettop block-buffers (8 KB) when stdout is a pipe, which would delay blocks by minutes; a pty makes it line-buffered.
        // The child gets its own session with the pty slave as controlling terminal, so it receives SIGHUP when the master closes (including when this process dies).
        var master: Int32 = -1
        var slave: Int32 = -1
        var slaveName = [CChar](repeating: 0, count: 128)
        var term = termios()
        cfmakeraw(&term)
        guard openpty(&master, &slave, &slaveName, &term, nil) == 0 else { throw LaunchError.ptyUnavailable }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // The parent keeps the slave open until the child exits so the master does not see EOF before the shell has opened it.
        // posix_spawn runs file actions before setsid, so the shell opens the pty slave itself (as session leader) to make it the controlling terminal, then execs nettop.
        // stdin is the pty slave too: nettop polls stdin for keystrokes and spins at >100% CPU on an EOF stdin such as /dev/null.
        let script = "exec /usr/bin/nettop \"$@\" <\"$0\" 2>/dev/null >\"$0\""
        let slavePath = String(decoding: slaveName.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let argv = (["sh", "-c", script, slavePath] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        guard status == 0 else {
            close(slave)
            close(master)
            throw LaunchError.spawnFailed(status)
        }

        let childPID = pid
        let slaveFD = slave
        let child = ChildProcess(pid: childPID)
        let (lines, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(8192))
        let buffer = LockedBuffer()
        let masterFD = master
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: DispatchQueue(label: "netpulse.nettop.read"))
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(masterFD, &bytes, bytes.count)
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            if count <= 0 {
                source.cancel()
                return
            }
            for line in buffer.append(Data(bytes[0..<count])) { continuation.yield(line) }
        }
        source.setCancelHandler {
            close(masterFD)
            if let rest = buffer.flush() { continuation.yield(rest) }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            source.cancel()
            child.terminate()
        }
        source.resume()
        DispatchQueue.global(qos: .utility).async {
            var wait: Int32 = 0
            while waitpid(childPID, &wait, 0) == -1, errno == EINTR {}
            close(slaveFD)
            child.markExited()
        }
        return (lines, { child.terminate() })
    }
}

private enum LaunchError: Error {
    case ptyUnavailable
    case spawnFailed(Int32)
}

private final class ChildProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let pid: pid_t
    private var exited = false

    init(pid: pid_t) { self.pid = pid }

    func markExited() { lock.withLock { exited = true } }

    func terminate() {
        let shouldKill = lock.withLock { () -> Bool in
            guard !exited else { return false }
            kill(pid, SIGTERM)
            return true
        }
        guard shouldKill else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.withLock { if !exited { kill(pid, SIGKILL) } }
        }
    }
}

final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            lines.append(line)
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }
}

private final class StallWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: Task<Void, Never>?
    private var stalledFlag = false
    private var blockFlag = false
    private var closed = false

    var stalled: Bool { lock.withLock { stalledFlag } }
    var sawBlock: Bool { lock.withLock { blockFlag } }

    func noteBlock() { lock.withLock { blockFlag = true } }

    func arm(after delay: Duration, timer sleeper: @escaping @Sendable (Duration) async -> Void, onStall: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        guard !closed else { return }
        timer = Task { [self] in
            await sleeper(delay)
            if Task.isCancelled { return }
            let fire = lock.withLock { () -> Bool in
                guard !closed, !Task.isCancelled else { return false }
                stalledFlag = true
                return true
            }
            if fire { onStall() }
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        timer?.cancel()
        timer = nil
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

private final class SupervisorCore: @unchecked Sendable {
    private let lock = NSLock()
    private let filter: NettopFilter
    private let interval: Int
    private let launcher: any LineProcessLaunching
    private let sleep: @Sendable (Duration) async -> Void
    private let stallTimer: @Sendable (Duration) async -> Void
    private var continuation: AsyncStream<NettopEvent>.Continuation?
    private var runTask: Task<Void, Never>?
    private var terminateCurrent: (@Sendable () -> Void)?
    private var started = false
    private var stopped = false

    init(
        filter: NettopFilter,
        interval: Int,
        launcher: any LineProcessLaunching,
        sleep: @escaping @Sendable (Duration) async -> Void,
        stallTimer: @escaping @Sendable (Duration) async -> Void
    ) {
        self.filter = filter
        self.interval = max(1, interval)
        self.launcher = launcher
        self.sleep = sleep
        self.stallTimer = stallTimer
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    func start() -> AsyncStream<NettopEvent> {
        let (stream, continuation) = AsyncStream<NettopEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let begin = lock.withLock { () -> Bool in
            guard !started, !stopped else { return false }
            started = true
            self.continuation = continuation
            return true
        }
        guard begin else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in self?.stop() }
        let task = Task { await self.run() }
        lock.withLock { runTask = task }
        return stream
    }

    func stop() {
        let (terminate, task, continuation) = lock.withLock { () -> ((@Sendable () -> Void)?, Task<Void, Never>?, AsyncStream<NettopEvent>.Continuation?) in
            guard !stopped else { return (nil, nil, nil) }
            stopped = true
            defer { terminateCurrent = nil }
            return (terminateCurrent, runTask, self.continuation)
        }
        terminate?()
        task?.cancel()
        continuation?.finish()
    }

    private var arguments: [String] {
        ["-P", "-d", "-L", "0", "-s", "\(interval)", "-x", "-J", "bytes_in,bytes_out"] + filter.interfaceTypes.flatMap { ["-t", $0] }
    }

    private func run() async {
        var failures = 0
        while !isStopped {
            let outcome = await runOnce()
            if isStopped { break }
            if outcome.sawBlock { failures = 0 }
            continuation?.yield(.gap(reason: outcome.reason))
            let delay = NettopSupervisor.backoff[min(failures, NettopSupervisor.backoff.count - 1)]
            failures += 1
            await sleep(delay)
        }
    }

    private func runOnce() async -> (reason: String, sawBlock: Bool) {
        let launched: (lines: AsyncStream<String>, terminate: @Sendable () -> Void)
        do {
            launched = try launcher.launch(arguments: arguments)
        } catch {
            return ("launch failed", false)
        }
        let terminate = launched.terminate
        let adopted = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            terminateCurrent = terminate
            return true
        }
        guard adopted else {
            terminate()
            return ("exited", false)
        }
        let watch = StallWatch()
        let continuation = continuation
        let lines = launched.lines
        let window = Duration.seconds(3 * interval)
        let stallTimer = stallTimer
        let readerBox = TaskBox()
        let onStall: @Sendable () -> Void = {
            terminate()
            readerBox.cancel()
        }
        let reader = Task {
            var parser = NettopParser()
            for await line in lines {
                if let block = parser.consume(line: line) {
                    watch.noteBlock()
                    continuation?.yield(.samples(block))
                    watch.arm(after: window, timer: stallTimer, onStall: onStall)
                }
            }
        }
        readerBox.set(reader)
        watch.arm(after: window, timer: stallTimer, onStall: onStall)
        await reader.value
        watch.close()
        lock.withLock { terminateCurrent = nil }
        return (watch.stalled ? "stalled" : "exited", watch.sawBlock)
    }
}

public actor NettopSupervisor {
    public static let backoff: [Duration] = [.seconds(1), .seconds(5), .seconds(30), .seconds(60)]

    private let core: SupervisorCore

    public init(
        filter: NettopFilter,
        interval: Int,
        launcher: any LineProcessLaunching,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        stallTimer: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        core = SupervisorCore(filter: filter, interval: interval, launcher: launcher, sleep: sleep, stallTimer: stallTimer)
    }

    deinit { core.stop() }

    /// Single use: the first call starts nettop; the stream ends when it is released or the supervisor deinits, so keep the supervisor alive while consuming.
    public func blocks() -> AsyncStream<NettopEvent> { core.start() }

    public func stop() { core.stop() }
}
