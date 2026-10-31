import AppKit
import NetPulseCore
import os

@MainActor
final class SystemEvents {
    private final class Tokens: @unchecked Sendable {
        var entries: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

        deinit {
            for entry in entries { entry.center.removeObserver(entry.token) }
        }
    }

    private let engine: MonitorEngine
    private let onTerminate: @MainActor () -> Void
    private let isUserPaused: @MainActor () -> Bool
    private let log = Logger(subsystem: "NetPulse", category: "system")
    private let tokens = Tokens()
    private var lifecycle: Task<Void, Never>?

    init(engine: MonitorEngine, isUserPaused: @escaping @MainActor () -> Bool = { false }, onTerminate: @escaping @MainActor () -> Void = {}) {
        self.engine = engine
        self.isUserPaused = isUserPaused
        self.onTerminate = onTerminate
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.sleep() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.wake() }
        observe(workspace, NSWorkspace.willPowerOffNotification) { $0.powerOff() }
        observe(.default, NSApplication.willTerminateNotification) { events in
            events.onTerminate()
            events.stopAndFlush(reason: "terminate", timeout: 3)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (SystemEvents) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { handler(self) }
            }
        }
        tokens.entries.append((center, token))
    }

    private func sleep() {
        log.info("will sleep")
        let engine = engine
        let previous = lifecycle
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            await previous?.value
            await engine.willSleep()
            await engine.flush()
            done.signal()
        }
        lifecycle = task
        let finished = done.wait(timeout: .now() + .seconds(2)) == .success
        log.info("sleep flush \(finished ? "done" : "timed out", privacy: .public)")
    }

    private func wake() {
        log.info("did wake")
        let engine = engine
        let previous = lifecycle
        // Detached like the sleep link: a sleep right after wake blocks the main thread waiting on this chain.
        lifecycle = Task.detached {
            await previous?.value
            await engine.didWake()
        }
    }

    // Power-off can still be cancelled by another app, so the engine is only paused here and resumed shortly after
    // unless the user had paused it. If the Mac really powers off, the process ends before the resume runs.
    private func powerOff() {
        stopAndFlush(reason: "power off", timeout: 2)
        let engine = engine
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !self.isUserPaused() else { return }
            self.log.info("power off did not happen; resuming")
            await engine.resume()
        }
    }

    private func stopAndFlush(reason: String, timeout: Int) {
        log.info("stopping: \(reason, privacy: .public)")
        let engine = engine
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await engine.pause()
            await engine.flush()
            done.signal()
        }
        _ = done.wait(timeout: .now() + .seconds(timeout))
    }
}
