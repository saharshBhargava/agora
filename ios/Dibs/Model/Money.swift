import Foundation

/// Money is integer cents everywhere. The app only formats numbers the server computed.
public enum Money {
    /// 436 -> "$4.36", -100 -> "-$1.00", 123456 -> "$1234.56". Mirrors `formatCents` in web/lib/money.ts.
    public static func format(_ cents: Int) -> String {
        let magnitude = cents.magnitude
        let rest = magnitude % 100
        let frac = rest < 10 ? "0\(rest)" : "\(rest)"
        return "\(cents < 0 ? "-" : "")$\(magnitude / 100).\(frac)"
    }

    /// "$40" for whole dollars, "$40.50" otherwise: for hero numbers and buttons. Mirrors `wholeCents`.
    public static func whole(_ cents: Int) -> String {
        cents % 100 == 0 ? "\(cents < 0 ? "-" : "")$\(cents.magnitude / 100)" : format(cents)
    }

    /// "8.72", "$8", "8.5" to integer cents, or nil when it is not a price. No floats.
    /// Mirrors `parseCents` in web/lib/props.ts.
    public static func parse(_ text: String) -> Int? {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.hasPrefix("$") { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let whole = parts[0]
        guard (1...6).contains(whole.count), whole.allSatisfy(\.isASCIIDigit), let w = Int(whole) else { return nil }
        var cents = w * 100
        if parts.count == 2 {
            let frac = parts[1]
            guard (1...2).contains(frac.count), frac.allSatisfy(\.isASCIIDigit), let f = Int(frac) else { return nil }
            cents += frac.count == 1 ? f * 10 : f
        }
        return cents
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
