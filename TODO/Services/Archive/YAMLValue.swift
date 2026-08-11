import Foundation

/// A parsed YAML value, plus the lenient readers the importer uses.
///
/// The importer's forgiveness rule is that *reading a field never fails* — it
/// either produces a value of the requested type or answers nil, and the caller
/// substitutes a default. That rule is implemented here rather than at each of
/// the several dozen call sites, so no field can accidentally be strict.
///
/// The coercions are intentionally loose in one direction only: a value is
/// reinterpreted (the string `"3"` reads as the number 3), never invented. A
/// field that holds something genuinely unrelated reads as nil and the record
/// keeps its default.
indirect enum YAMLValue: Equatable {
    case scalar(String)
    case list([YAMLValue])
    case mapping([String: YAMLValue])
    /// An explicit `null`/`~`/empty value. Distinct from "key absent", which the
    /// importer treats identically — both mean "no opinion, use the default".
    case null
}

// MARK: - Lenient reads

extension YAMLValue {

    var stringValue: String? {
        switch self {
        case .scalar(let text): text
        case .null: nil
        // A field that was a string in one schema version and became a list in
        // another still yields something usable rather than nothing.
        case .list(let items): items.compactMap(\.stringValue).joined(separator: "\n")
        case .mapping: nil
        }
    }

    var intValue: Int? {
        guard let text = stringValue?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let exact = Int(text) { return exact }
        // A value written as `3.0` — by another exporter, or by a field that
        // used to be a Double — still reads as an integer.
        if let rounded = Double(text), rounded.isFinite { return Int(rounded) }
        return nil
    }

    var doubleValue: Double? {
        guard let text = stringValue?.trimmingCharacters(in: .whitespaces) else { return nil }
        return Double(text)
    }

    /// Accepts every spelling YAML 1.1 and 1.2 allow, plus `1`/`0`.
    var boolValue: Bool? {
        guard let text = stringValue?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return nil
        }
        switch text {
        case "true", "yes", "on", "y", "1": return true
        case "false", "no", "off", "n", "0": return false
        default: return nil
        }
    }

    var uuidValue: UUID? {
        guard let text = stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        if let exact = UUID(uuidString: text) { return exact }
        // Accept a UUID that lost its hyphens somewhere along the way.
        let bare = text.replacingOccurrences(of: "-", with: "")
        guard bare.count == 32 else { return nil }
        let hyphenated = [
            bare.prefix(8),
            bare.dropFirst(8).prefix(4),
            bare.dropFirst(12).prefix(4),
            bare.dropFirst(16).prefix(4),
            bare.dropFirst(20).prefix(12),
        ].joined(separator: "-")
        return UUID(uuidString: hyphenated)
    }

    /// Dates are exported as ISO 8601, but a hand-edited or third-party file may
    /// carry any of several common spellings — each is tried before giving up.
    var dateValue: Date? {
        guard let text = stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        return YAMLDateFormats.parse(text)
    }

    var listValue: [YAMLValue] {
        switch self {
        case .list(let items): items
        case .null: []
        // A scalar where a list was expected reads as a single-element list, so
        // a field that became repeatable between versions still imports.
        case .scalar: [self]
        case .mapping: [self]
        }
    }

    var stringList: [String] {
        listValue.compactMap(\.stringValue)
    }

    var mappingValue: [String: YAMLValue]? {
        if case .mapping(let pairs) = self { return pairs }
        return nil
    }

    /// Look a key up case- and separator-insensitively.
    ///
    /// A field renamed from `dueDate` to `due_date` between versions still
    /// resolves, which is a common enough kind of drift to absorb rather than
    /// report.
    func value(forKey key: String) -> YAMLValue? {
        guard let pairs = mappingValue else { return nil }
        if let exact = pairs[key] { return exact }

        let target = Self.normalizeKey(key)
        for (candidate, value) in pairs where Self.normalizeKey(candidate) == target {
            return value
        }
        return nil
    }

    /// The first present value among several accepted spellings of a field.
    ///
    /// This is how a renamed field keeps importing: the reader lists the old
    /// name alongside the new one.
    func value(forAnyKey keys: [String]) -> YAMLValue? {
        for key in keys {
            if let found = value(forKey: key), found != .null { return found }
        }
        return nil
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Date formats

enum YAMLDateFormats {

    /// What the exporter writes: fractional-second ISO 8601, which round-trips a
    /// `Date` without losing precision.
    static let canonical: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Formats accepted on the way in but never written.
    private static let fallbacks: [DateFormatter] = {
        ["yyyy-MM-dd'T'HH:mm:ssZ",
         "yyyy-MM-dd'T'HH:mm:ss",
         "yyyy-MM-dd HH:mm:ss Z",
         "yyyy-MM-dd HH:mm:ss",
         "yyyy-MM-dd HH:mm",
         "yyyy-MM-dd",
         "yyyy/MM/dd"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()

    static func string(from date: Date) -> String {
        canonical.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        if let date = canonical.date(from: text) { return date }
        if let date = plainISO.date(from: text) { return date }

        for formatter in fallbacks {
            if let date = formatter.date(from: text) { return date }
        }

        // A bare number is a Unix timestamp — what a JSON-derived export or a
        // debugging dump tends to contain.
        if let seconds = Double(text), seconds > 0, seconds < 4_102_444_800 {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
