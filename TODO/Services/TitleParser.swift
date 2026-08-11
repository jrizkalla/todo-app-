import Foundation

/// A property the parser found inside a title, offered to the user as a chip.
struct ParsedSuggestion: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Set `assignedDate` — "schedule tomorrow".
        case schedule(Date, hasTime: Bool)
        /// Set `dueDate` — "deadline tomorrow".
        case deadline(Date, hasTime: Bool)
        /// Set `duration` — "5m".
        case duration(TimeInterval)
        /// File under an existing project, matched by name.
        case project(name: String, uuid: UUID)
    }

    var id: String { "\(kind)-\(matchedRange.location)-\(matchedRange.length)" }

    let kind: Kind
    /// The substring that produced this suggestion, removed from the title when
    /// the user accepts it.
    let matchedText: String
    let matchedRange: NSRange

    var label: String {
        switch kind {
        case .schedule(let date, let hasTime):
            "Schedule \(Self.describe(date, hasTime: hasTime))"
        case .deadline(let date, let hasTime):
            "Deadline \(Self.describe(date, hasTime: hasTime))"
        case .duration(let seconds):
            "Duration \(Self.describe(duration: seconds))"
        case .project(let name, _):
            "Move to \(name)"
        }
    }

    var symbolName: String {
        switch kind {
        case .schedule: "calendar"
        case .deadline: "target"
        case .duration: "clock"
        case .project: "folder"
        }
    }

    static func describe(_ date: Date, hasTime: Bool) -> String {
        let calendar = Calendar.current
        let dayText: String
        if calendar.isDateInToday(date) {
            dayText = "today"
        } else if calendar.isDateInTomorrow(date) {
            dayText = "tomorrow"
        } else if calendar.isDateInYesterday(date) {
            dayText = "yesterday"
        } else {
            dayText = date.formatted(.dateTime.weekday(.wide).month().day())
        }

        guard hasTime else { return dayText }
        return "\(dayText) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    static func describe(duration seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}

/// Scans a title for dates, durations, and project names as the user types.
///
/// Dates come from `DatePhraseParser`, which wraps `NSDataDetector` for fluent
/// phrasing and adds the clipped forms people type ("weds", "aug 10", "8/10").
/// Durations and project names are matched separately, since neither engine
/// covers them.
struct TitleParser {
    /// Names of existing projects to match against, paired with their ids.
    var projectNames: [(name: String, uuid: UUID)] = []
    var referenceDate: Date = Date()
    var calendar: Calendar = .current

    /// `5m`, `5 min`, `1.5 hours`, `2h`. Requires a word boundary so "5m" in
    /// "5mm bolt" does not match.
    private static let durationPattern = #"\b(\d+(?:\.\d+)?)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours)\b"#

    private static let durationRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: durationPattern, options: [.caseInsensitive])
    }()

    /// All suggestions for `title`, ordered by where they appear.
    ///
    /// A date match yields two chips — schedule and deadline — because the
    /// phrase alone cannot say which the user meant; the spec's example ("Clean
    /// car tomorrow") calls for exactly that pair.
    func suggestions(for title: String) -> [ParsedSuggestion] {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var results: [ParsedSuggestion] = []
        results.append(contentsOf: dateSuggestions(in: title))
        results.append(contentsOf: durationSuggestions(in: title))
        results.append(contentsOf: projectSuggestions(in: title))
        return results
    }

    // MARK: Dates

    private func dateSuggestions(in title: String) -> [ParsedSuggestion] {
        let parser = DatePhraseParser(referenceDate: referenceDate, calendar: calendar)

        return parser.matches(in: title).flatMap { match in
            [
                ParsedSuggestion(kind: .schedule(match.date, hasTime: match.hasTime),
                                 matchedText: match.matchedText, matchedRange: match.matchedRange),
                ParsedSuggestion(kind: .deadline(match.date, hasTime: match.hasTime),
                                 matchedText: match.matchedText, matchedRange: match.matchedRange),
            ]
        }
    }

    // MARK: Durations

    private func durationSuggestions(in title: String) -> [ParsedSuggestion] {
        guard let regex = Self.durationRegex else { return [] }
        let nsTitle = title as NSString
        let range = NSRange(location: 0, length: nsTitle.length)

        return regex.matches(in: title, options: [], range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let value = Double(nsTitle.substring(with: match.range(at: 1)))
            else { return nil }

            let unit = nsTitle.substring(with: match.range(at: 2)).lowercased()
            let seconds = unit.hasPrefix("h") ? value * 3600 : value * 60

            return ParsedSuggestion(
                kind: .duration(seconds),
                matchedText: nsTitle.substring(with: match.range),
                matchedRange: match.range
            )
        }
    }

    // MARK: Projects

    /// Match a project by name, case-insensitively, on whole words only.
    private func projectSuggestions(in title: String) -> [ParsedSuggestion] {
        projectNames.compactMap { project in
            let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return nil }

            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: trimmed))\\b"
            guard let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive])
            else { return nil }

            return ParsedSuggestion(
                kind: .project(name: trimmed, uuid: project.uuid),
                matchedText: String(title[range]),
                matchedRange: NSRange(range, in: title)
            )
        }
        .sorted { $0.matchedRange.location < $1.matchedRange.location }
        .prefix(1)
        .map { $0 }
    }

    // MARK: Applying

    /// Remove an accepted suggestion's text from the title and tidy whitespace.
    ///
    /// The spec: accepting "schedule tomorrow" clears the word "tomorrow" from
    /// the title.
    static func removing(_ suggestion: ParsedSuggestion, from title: String) -> String {
        let nsTitle = title as NSString
        guard suggestion.matchedRange.location != NSNotFound,
              NSMaxRange(suggestion.matchedRange) <= nsTitle.length
        else { return title }

        let stripped = nsTitle.replacingCharacters(in: suggestion.matchedRange, with: " ")
        return stripped
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
