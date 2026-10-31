import AppKit
import NetPulseCore

/// What the status item shows: an AppKit title or a template image.
enum MenuBarContent {
    case title(NSAttributedString)
    case image(NSImage)
}

@MainActor
enum MenuBarLabel {
    static let stackedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    static var lineFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    static func content(_ text: MenuBarText, style: LabelStyle, unit: RateUnit) -> MenuBarContent {
        if text.paused { return .image(paused) }
        switch style {
        case .stacked:
            return .image(stacked(up: text.up, down: text.down, unit: unit))
        case .singleLine:
            let column = Layout.line(unit)
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [
                NSTextTab(textAlignment: .right, location: column.down),
                NSTextTab(textAlignment: .left, location: column.down + column.gap),
                NSTextTab(textAlignment: .right, location: column.down + column.gap + column.down),
            ]
            return .title(NSAttributedString(
                string: "↓\t\(text.down)\t↑\t\(text.up)", attributes: [.font: lineFont, .paragraphStyle: paragraph]))
        case .downloadOnly:
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: Layout.line(unit).down)]
            return .title(NSAttributedString(
                string: "↓\t\(text.down)", attributes: [.font: lineFont, .paragraphStyle: paragraph]))
        case .iconOnly:
            return .image(icon)
        }
    }

    /// Two rows of AppKit text drawn into a template image. The status button lays out a multi-line title by its
    /// last baseline (it sits high in the bar), while images are centered, so the stacked rows go in an image.
    /// The text is drawn only when the system rasterizes the image; no SwiftUI rendering is involved.
    private static func stacked(up: String, down: String, unit: RateUnit) -> NSImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 10
        paragraph.maximumLineHeight = 10
        let column = Layout.stacked(unit)
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: column)]
        let rows = NSAttributedString(
            string: "↑\t\(up)\n↓\t\(down)", attributes: [.font: stackedFont, .paragraphStyle: paragraph])
        let image = NSImage(size: NSSize(width: column, height: 22), flipped: true) { _ in
            rows.draw(in: NSRect(x: 0, y: 1, width: column + 2, height: 20))
            return true
        }
        image.isTemplate = true
        return image
    }

    static func accessibilityLabel(_ text: MenuBarText, style: LabelStyle, unit: RateUnit) -> String {
        if text.paused { return "NetPulse, paused" }
        switch style {
        case .stacked:
            return "NetPulse, download \(Spoken.text(expanded(text.down, unit))), upload \(Spoken.text(expanded(text.up, unit)))"
        case .singleLine:
            return "NetPulse, download \(Spoken.text(text.down)), upload \(Spoken.text(text.up))"
        case .downloadOnly:
            return "NetPulse, download \(Spoken.text(text.down))"
        case .iconOnly:
            return "NetPulse"
        }
    }

    /// "8.4M" → "8.4 MB/s" (or Mbps): the compact label carries the same number and magnitude as the full rate.
    private static func expanded(_ compact: String, _ unit: RateUnit) -> String {
        let bits = unit == .bitsPerSecond
        guard let last = compact.last, last.isLetter else { return "\(compact) \(bits ? "bps" : "B/s")" }
        return "\(compact.dropLast()) \(last)\(bits ? "bps" : "B/s")"
    }

    static let icon: NSImage = {
        let image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil) ?? NSImage()
        image.isTemplate = true
        return image
    }()

    /// The ↑↓ symbol with a pause badge cut into its corner. Drawn by a handler, so it is sharp at any display scale.
    static let paused: NSImage = {
        let size = NSSize(width: 24, height: 18)
        let badge = NSRect(x: size.width - 11, y: size.height - 11, width: 11, height: 11)
        let image = NSImage(size: size, flipped: true) { _ in
            let arrows = symbol("arrow.up.arrow.down", NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            arrows?.draw(in: NSRect(origin: .zero, size: arrows?.size ?? .zero), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: badge).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            if let pause = symbol("pause.circle.fill", NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)) {
                let rect = NSRect(x: badge.midX - pause.size.width / 2, y: badge.midY - pause.size.height / 2, width: pause.size.width, height: pause.size.height)
                pause.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    nonisolated private static func symbol(_ name: String, _ configuration: NSImage.SymbolConfiguration) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}

/// Fixed column widths, measured from the widest value each unit can produce, so the label never changes width.
@MainActor
private enum Layout {
    private static var stackedCache: [RateUnit: CGFloat] = [:]
    private static var lineCache: [RateUnit: (down: CGFloat, gap: CGFloat)] = [:]
    private static let numbers = ["888", "88.8", "8.88"]

    static func stacked(_ unit: RateUnit) -> CGFloat {
        if let cached = stackedCache[unit] { return cached }
        let font = MenuBarLabel.stackedFont
        let values = numbers.flatMap { number in ["", "K", "M", "G", "T"].map { number + $0 } }
        let column = (width("↑", font) + 2 + values.map { width($0, font) }.max()!).rounded(.up)
        stackedCache[unit] = column
        return column
    }

    static func line(_ unit: RateUnit) -> (down: CGFloat, gap: CGFloat) {
        if let cached = lineCache[unit] { return cached }
        let font = MenuBarLabel.lineFont
        let suffixes = unit == .bitsPerSecond ? ["bps", "Kbps", "Mbps", "Gbps", "Tbps"] : ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        let values = numbers.flatMap { number in suffixes.map { "\(number) \($0)" } }
        let column = (width("↓ ", font) + values.map { width($0, font) }.max()!).rounded(.up)
        let result = (column, width("  ", font).rounded(.up))
        lineCache[unit] = result
        return result
    }

    private static func width(_ string: String, _ font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }
}
