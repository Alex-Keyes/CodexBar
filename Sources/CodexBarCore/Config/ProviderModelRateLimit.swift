import Foundation

public struct ProviderModelRateLimit: Codable, Sendable, Equatable {
    public var model: String
    public var tokensPerMinute: Int
    public var requestsPerMinute: Int?

    public init(model: String, tokensPerMinute: Int, requestsPerMinute: Int? = nil) {
        self.model = model
        self.tokensPerMinute = tokensPerMinute
        self.requestsPerMinute = requestsPerMinute
    }

    public static func validated(_ rows: [Self]) -> [Self] {
        var seen: Set<String> = []
        return rows.reversed().compactMap { row in
            let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, row.tokensPerMinute > 0, seen.insert(model).inserted else { return nil }
            return Self(
                model: model,
                tokensPerMinute: row.tokensPerMinute,
                requestsPerMinute: row.requestsPerMinute.flatMap { $0 > 0 ? $0 : nil })
        }.reversed()
    }
}

public enum ProviderRateLimitNumber {
    /// Accepts grouped integers and decimal k/M suffixes, but never rounds fractional counts.
    public static func parse(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = text.wholeMatch(of: /([0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(\.[0-9]+)?([kKmM])?/) else {
            return nil
        }
        guard match.2 == nil || match.3 != nil else { return nil }
        let numeric = String(match.1).replacingOccurrences(of: ",", with: "") + (match.2.map(String.init) ?? "")
        guard var value = Decimal(string: numeric, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        switch match.3?.lowercased() {
        case "k": value *= 1000
        case "m": value *= 1_000_000
        default: break
        }
        guard value > 0, value <= Decimal(Int.max) else { return nil }
        let number = NSDecimalNumber(decimal: value)
        let integer = number.int64Value
        guard Decimal(integer) == value else { return nil }
        return Int(exactly: integer)
    }

    public static func format(_ value: Int) -> String {
        // Only shorten exactly representable values, so opening Settings cannot change a limit.
        for (divisor, suffix) in [(1_000_000, "M"), (1000, "K")] where value >= divisor {
            if value % (divisor / 10) == 0 {
                return NSDecimalNumber(decimal: Decimal(value) / Decimal(divisor)).stringValue + suffix
            }
        }
        return String(value)
    }
}
