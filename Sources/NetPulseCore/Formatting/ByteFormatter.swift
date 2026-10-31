import Foundation

public enum RateUnit: Sendable {
    case bytesPerSecond
    case bitsPerSecond
}

public enum ByteFormatter {
    public static func bytes(_ n: UInt64) -> String {
        let (number, index) = scaled(Double(n))
        return "\(number) \(["B", "KB", "MB", "GB", "TB"][index])"
    }

    public static func rate(_ bytesPerSecond: Double, unit: RateUnit) -> String {
        let (number, index) = scaled(value(bytesPerSecond, unit: unit))
        let suffixes: [String]
        switch unit {
        case .bytesPerSecond: suffixes = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        case .bitsPerSecond: suffixes = ["bps", "Kbps", "Mbps", "Gbps", "Tbps"]
        }
        return "\(number) \(suffixes[index])"
    }

    /// Menu bar form: number plus a bare magnitude letter ("8.4M"); the base unit has no suffix.
    public static func compactRate(_ bytesPerSecond: Double, unit: RateUnit) -> String {
        let (number, index) = scaled(value(bytesPerSecond, unit: unit))
        return "\(number)\(["", "K", "M", "G", "T"][index])"
    }

    private static func value(_ bytesPerSecond: Double, unit: RateUnit) -> Double {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return 0 }
        return unit == .bitsPerSecond ? bytesPerSecond * 8 : bytesPerSecond
    }

    /// Three significant digits, decimal (1,000) steps. A value that rounds up to 1000 moves to the next unit.
    private static func scaled(_ base: Double) -> (String, Int) {
        var value = base
        var index = 0
        while index < 4 {
            if value < 1_000, text(value, base: index == 0) != "1000" { break }
            value /= 1_000
            index += 1
        }
        return (text(value, base: index == 0), index)
    }

    private static func text(_ v: Double, base: Bool) -> String {
        if base || v >= 99.95 { return String(Int(v.rounded())) }
        if v >= 9.995 { return trimmed(String(format: "%.1f", v)) }
        return trimmed(String(format: "%.2f", v))
    }

    private static func trimmed(_ s: String) -> String {
        guard s.hasSuffix("0"), s.contains(".") else { return s }
        let cut = String(s.dropLast())
        return cut.hasSuffix(".") ? s : cut
    }
}
