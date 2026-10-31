import Foundation

public enum CapInput {
    public static func limitBytes(fromGB text: String, locale: Locale = .current) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(trimmed.contains(",") && trimmed.contains(".")) else { return nil }
        let grouping = locale.groupingSeparator ?? ","
        let decimal = locale.decimalSeparator ?? "."
        if trimmed.contains(grouping), grouping != decimal { return nil }
        guard let gb = parse(trimmed, locale: locale) ?? parse(trimmed, locale: Locale(identifier: "en_US_POSIX")),
              gb.isFinite, gb > 0 else { return nil }
        let bytes = (gb * 1e9).rounded()
        guard bytes >= 1, bytes < 9e18 else { return nil }
        return UInt64(bytes)
    }

    public static func text(forBytes bytes: UInt64, locale: Locale = .current) -> String {
        guard bytes > 0 else { return "" }
        let format = NumberFormatter()
        format.locale = locale
        format.numberStyle = .decimal
        format.usesGroupingSeparator = false
        format.maximumFractionDigits = 3
        return format.string(from: NSNumber(value: Double(bytes) / 1e9)) ?? ""
    }

    private static func parse(_ text: String, locale: Locale) -> Double? {
        let format = NumberFormatter()
        format.locale = locale
        format.numberStyle = .decimal
        format.usesGroupingSeparator = false
        if locale.identifier == "en_US_POSIX" {
            return Double(text)
        }
        return format.number(from: text)?.doubleValue
    }
}
