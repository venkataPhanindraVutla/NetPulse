import AppKit
import NetPulseCore
import Observation
import SwiftUI

/// Owns the status item and its popover. The label is AppKit text, set only when the displayed text changes. The
/// popover's SwiftUI content exists only while it is shown, so nothing in SwiftUI follows per-second state while it is closed.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    static var shared: StatusItemController?

    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var window: NSWindow?
    private var shown: (text: MenuBarText, style: LabelStyle, unit: RateUnit)?
    private var closedAt: ContinuousClock.Instant?
    private var closing: NSViewController?

    init(model: AppModel) {
        self.model = model
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle(_:))
            button.imagePosition = .imageOnly
        }
        observe()
    }

    private func observe() {
        let (text, style, unit) = withObservationTracking {
            (model.menuBarText, model.labelStyle, model.rateUnit)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        if let shown, shown == (text, style, unit) { return }
        let resized = shown.map { $0.style != style || $0.unit != unit || $0.text.paused != text.paused } ?? true
        shown = (text, style, unit)
        apply(MenuBarLabel.content(text, style: style, unit: unit), accessibility: MenuBarLabel.accessibilityLabel(text, style: style, unit: unit), resized: resized)
    }

    /// Within one style the label's width never changes, so the item gets a fixed length for it: a per-second update
    /// then only redraws the button instead of also re-running layout for the status item.
    private func apply(_ content: MenuBarContent, accessibility: String, resized: Bool) {
        guard let button = item.button else { return }
        switch content {
        case .title(let title):
            if resized {
                button.image = nil
                button.imagePosition = .noImage
            }
            button.attributedTitle = title
        case .image(let image):
            if resized {
                button.title = ""
                button.imagePosition = .imageOnly
            }
            button.image = image
        }
        button.setAccessibilityLabel(accessibility)
        if resized {
            item.length = NSStatusItem.variableLength
            item.length = button.intrinsicContentSize.width.rounded(.up)
        }
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // A transient popover closes on the mouse-down of the click that lands on this button; don't reopen it on the mouse-up.
        if let closedAt, closedAt.duration(to: .now) < .milliseconds(300) { return }
        show()
    }

    func show() {
        guard !popover.isShown, let button = item.button else { return }
        let host = NSHostingController(rootView: PopoverView().environment(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        model.popoverOpen = true
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }

    /// Opening the app again (double-click in Finder) shows the panel. A full menu bar can hide the status item behind
    /// the notch, so when the item isn't visible the panel opens in an ordinary window instead of a popover.
    func reopen() {
        if let buttonWindow = item.button?.window, buttonWindow.occlusionState.contains(.visible) {
            show()
            return
        }
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: PopoverView().environment(model))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = "NetPulse"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        model.popoverOpen = true
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        window = nil
        model.popoverOpen = popover.isShown
    }

    func popoverWillClose(_ notification: Notification) {
        closedAt = .now
        closing = popover.contentViewController
    }

    /// If the popover was shown again while this close was animating, the new content stays.
    func popoverDidClose(_ notification: Notification) {
        defer { closing = nil }
        guard !popover.isShown, popover.contentViewController === closing else { return }
        item.button?.highlight(false)
        popover.contentViewController = nil
        model.popoverOpen = window != nil
    }
}
