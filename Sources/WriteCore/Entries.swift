import CryptoKit
import Foundation

/// A date heading that starts a journal entry. Date parts are only what was written.
public struct EntryMarker: Codable, Hashable, Sendable {
    public var headingLine: String
    public var weekday: String?
    public var year: Int?
    public var month: Int?
    public var day: Int?
    public var time: String?

    public init(headingLine: String, weekday: String? = nil, year: Int? = nil, month: Int? = nil,
                day: Int? = nil, time: String? = nil) {
        self.headingLine = headingLine
        self.weekday = weekday
        self.year = year
        self.month = month
        self.day = day
        self.time = time
    }
}

/// What Claude found on a page. The page text remains the source of truth, so edits keep working.
public struct PageStructure: Codable, Hashable, Sendable {
    public var markers: [EntryMarker]
    public var names: [String]
    public var textDigest: String

    public init(markers: [EntryMarker], names: [String], text: String) {
        self.markers = markers
        self.names = names
        textDigest = Self.digest(text)
    }

    func describes(_ text: String) -> Bool {
        textDigest == Self.digest(text)
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Recognizes a line that is only a date, with an optional weekday and time.
public enum DateHeadingParser {
    private static let weekdayPattern =
        "monday|tuesday|wednesday|thursday|friday|saturday|sunday|tues|tue|weds|wed|thurs|thur|thu|mon|fri|sat|sun"
    private static let monthPattern =
        "january|february|march|april|may|june|july|august|september|october|november|december|sept|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec"
    private static let monthPrefixes = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let weekdayNames = ["mon": "Monday", "tue": "Tuesday", "wed": "Wednesday", "thu": "Thursday",
                                       "fri": "Friday", "sat": "Saturday", "sun": "Sunday"]

    private static let expression: NSRegularExpression = {
        let ordinal = "(?:st|nd|rd|th)?"
        let pattern = #"^\s*(?:(?<weekday>"# + weekdayPattern + #")\.?[\s,\-–—:|]*)?(?:"#
            + #"(?<monthName>"# + monthPattern + #")\.?\s*(?<monthDay>\d{1,2})"# + ordinal
            + #"(?:[\s,]+(?<monthYear>\d{4}|'\d{2})(?![:\d]))?"#
            + #"|(?<dayFirst>\d{1,2})"# + ordinal + #"\s+(?<dayMonth>"# + monthPattern + #")\.?(?:[\s,]+(?<dayYear>\d{4}))?"#
            + #"|(?<isoYear>\d{4})-(?<isoMonth>\d{1,2})-(?<isoDay>\d{1,2})"#
            + #"|(?<numMonth>\d{1,2})[/.\-](?<numDay>\d{1,2})(?:[/.\-](?<numYear>\d{4}|\d{2}))?"#
            + #")(?:[\s,\-–—:|@]*(?:at\s*)?(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<meridiem>a\.?m\.?|p\.?m\.?)?)?"#
            + #"[\s.,;:\-–—]*$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    public static func parse(_ line: String) -> EntryMarker? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard (3...64).contains(text.count),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        func group(_ name: String) -> String? {
            let range = match.range(withName: name)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        func monthNumber(_ name: String?) -> Int? {
            guard let name else { return nil }
            return monthPrefixes.firstIndex(of: String(name.lowercased().prefix(3))).map { $0 + 1 }
        }

        let weekday = group("weekday").flatMap { weekdayNames[String($0.lowercased().prefix(3))] }
        var month: Int?
        var day: Int?
        var yearText: String?
        if let name = group("monthName") {
            month = monthNumber(name)
            day = group("monthDay").flatMap(Int.init)
            yearText = group("monthYear")
        } else if let first = group("dayFirst") {
            day = Int(first)
            month = monthNumber(group("dayMonth"))
            yearText = group("dayYear")
        } else if let iso = group("isoYear") {
            yearText = iso
            month = group("isoMonth").flatMap(Int.init)
            day = group("isoDay").flatMap(Int.init)
        } else {
            month = group("numMonth").flatMap(Int.init)
            day = group("numDay").flatMap(Int.init)
            yearText = group("numYear")
            // A bare "3/4" could be a fraction, so it needs a year or weekday to count as a date.
            guard yearText != nil || weekday != nil else { return nil }
        }

        var year: Int?
        if let yearText {
            let digits = yearText.filter(\.isNumber)
            guard let value = Int(digits) else { return nil }
            year = digits.count == 2 ? 2000 + value : value
        }
        guard let month, let day, isValid(month: month, day: day, year: year) else { return nil }

        var time: String?
        if let hourText = group("hour"), var hour = Int(hourText) {
            let minute = group("minute").flatMap(Int.init)
            let meridiem = group("meridiem")?.lowercased()
            // A lone trailing number is not clearly a time, so the line isn't treated as a heading.
            guard minute != nil || meridiem != nil, (minute ?? 0) < 60 else { return nil }
            if let meridiem {
                guard (1...12).contains(hour) else { return nil }
                hour = hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0)
            }
            guard hour < 24 else { return nil }
            time = String(format: "%02d:%02d", hour, minute ?? 0)
        }
        return EntryMarker(headingLine: text, weekday: weekday, year: year, month: month, day: day, time: time)
    }

    static func isValid(month: Int, day: Int, year: Int?) -> Bool {
        guard (1...12).contains(month), day >= 1 else { return false }
        var days = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        if let year, !(year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) { days[1] = 28 }
        return day <= days[month - 1]
    }
}

/// One stretch of an entry on a single page.
public struct EntryPart: Identifiable, Hashable, Sendable {
    public let pageID: UUID
    public let pageNumber: Int
    public let startLine: Int
    public let heading: String?
    public let body: String

    public var id: String { "\(pageID.uuidString)#\(startLine)" }
}

/// An entry can be shorter than a page or run across several.
public struct JournalEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let journalID: UUID
    public let heading: String?
    public let weekday: String?
    public internal(set) var year: Int?
    public let month: Int?
    public let day: Int?
    public let time: String?
    public internal(set) var yearWasInferred = false
    public internal(set) var parts: [EntryPart]

    public var isDated: Bool { month != nil && day != nil }
    public var firstPage: Int { parts.first?.pageNumber ?? 0 }
    public var lastPage: Int { parts.last?.pageNumber ?? 0 }
    public var bodyText: String { parts.map(\.body).joined(separator: "\n") }

    public var pageLabel: String {
        firstPage == lastPage ? "p. \(firstPage)" : "pp. \(firstPage)–\(lastPage)"
    }

    public var title: String {
        guard let month, let day else {
            return heading == nil ? "Continued from an earlier page" : "Undated entry"
        }
        let name = DateFormatter.monthName(month)
        let date = year.map { "\(name) \(day), \($0)" } ?? "\(name) \(day)"
        return weekday.map { "\($0), \(date)" } ?? date
    }

    public var timeLabel: String? {
        guard let time else { return nil }
        let pieces = time.split(separator: ":").compactMap { Int($0) }
        guard pieces.count == 2 else { return nil }
        let hour = pieces[0] % 12 == 0 ? 12 : pieces[0] % 12
        return String(format: "%d:%02d %@", hour, pieces[1], pieces[0] < 12 ? "AM" : "PM")
    }
}

extension DateFormatter {
    static func monthName(_ month: Int) -> String {
        let names = ["January", "February", "March", "April", "May", "June", "July", "August",
                     "September", "October", "November", "December"]
        return names.indices.contains(month - 1) ? names[month - 1] : ""
    }
}

public enum EntryBuilder {
    public static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// Uses Claude's headings while they still match the text. After an edit, it also recognizes
    /// date lines she has typed or corrected.
    public static func headings(in text: String, structure: PageStructure?) -> [(line: Int, marker: EntryMarker)] {
        let lines = lines(of: text)
        var found: [Int: EntryMarker] = [:]
        var cursor = 0
        for marker in structure?.markers ?? [] {
            let target = comparable(marker.headingLine)
            guard !target.isEmpty, cursor < lines.count,
                  let index = lines[cursor...].firstIndex(where: { comparable($0) == target })
            else { continue }
            found[index] = marker
            cursor = index + 1
        }
        if structure?.describes(text) != true {
            for (index, line) in lines.enumerated() where found[index] == nil {
                if let parsed = DateHeadingParser.parse(line) { found[index] = parsed }
            }
        }
        return found.keys.sorted().map { ($0, found[$0]!) }
    }

    /// Builds entries in journal order, then page order.
    public static func build(pages: [PageInfo], journalOrder: [UUID], text: (UUID) -> String) -> [JournalEntry] {
        journalOrder.flatMap { journalID -> [JournalEntry] in
            let journalPages = pages.filter { $0.journalID == journalID }.sorted { $0.number < $1.number }
            return inferYears(buildJournal(journalID: journalID, pages: journalPages, text: text))
        }
    }

    private static func buildJournal(journalID: UUID, pages: [PageInfo], text: (UUID) -> String) -> [JournalEntry] {
        var entries: [JournalEntry] = []
        var previousNumber: Int?

        for page in pages {
            let content = text(page.id)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let lines = lines(of: content)
            let headings = headings(in: content, structure: page.structure)
            let firstHeading = headings.first?.line ?? lines.count
            let leading = trimmed(lines[0..<firstHeading])

            if !leading.isEmpty {
                let part = EntryPart(pageID: page.id, pageNumber: page.number, startLine: 0, heading: nil, body: leading)
                if let previousNumber, previousNumber + 1 == page.number, !entries.isEmpty {
                    entries[entries.count - 1].parts.append(part)
                } else {
                    entries.append(JournalEntry(id: part.id, journalID: journalID, heading: nil, weekday: nil,
                                                year: nil, month: nil, day: nil, time: nil, parts: [part]))
                }
            }

            for (offset, heading) in headings.enumerated() {
                let end = offset + 1 < headings.count ? headings[offset + 1].line : lines.count
                let bodyStart = min(heading.line + 1, end)
                let headingText = lines[heading.line].trimmingCharacters(in: .whitespaces)
                let part = EntryPart(pageID: page.id, pageNumber: page.number, startLine: heading.line,
                                     heading: headingText, body: trimmed(lines[bodyStart..<end]))
                entries.append(JournalEntry(
                    id: part.id, journalID: journalID, heading: headingText, weekday: heading.marker.weekday,
                    year: heading.marker.year, month: heading.marker.month, day: heading.marker.day,
                    time: heading.marker.time, parts: [part]
                ))
            }
            previousNumber = page.number
        }
        return entries
    }

    /// Fills in a missing year from nearby entries, moving forward a year when the months wrap around.
    private static func inferYears(_ source: [JournalEntry]) -> [JournalEntry] {
        var entries = source
        var lastYear: Int?
        var lastMonth: Int?
        for index in entries.indices {
            guard let month = entries[index].month else { continue }
            if let year = entries[index].year {
                (lastYear, lastMonth) = (year, month)
            } else if let year = lastYear, let previous = lastMonth {
                let inferred = month < previous ? year + 1 : year
                entries[index].year = inferred
                entries[index].yearWasInferred = true
                (lastYear, lastMonth) = (inferred, month)
            }
        }
        var nextYear: Int?
        var nextMonth: Int?
        for index in entries.indices.reversed() {
            guard let month = entries[index].month else { continue }
            if let year = entries[index].year {
                (nextYear, nextMonth) = (year, month)
            } else if let year = nextYear, let following = nextMonth {
                let inferred = month > following ? year - 1 : year
                entries[index].year = inferred
                entries[index].yearWasInferred = true
                (nextYear, nextMonth) = (inferred, month)
            }
        }
        return entries
    }

    private static func comparable(_ line: String) -> String {
        line.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func trimmed(_ lines: ArraySlice<String>) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum LineFlow {
    /// Joins handwritten line wraps into paragraphs, keeping blank lines and date headings.
    public static func reflow(_ text: String, headingLines: Set<Int> = []) -> String {
        var paragraphs: [String] = []
        var current = ""

        func finish() {
            if !current.isEmpty { paragraphs.append(current) }
            current = ""
        }

        for (index, raw) in EntryBuilder.lines(of: text).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                finish()
            } else if headingLines.contains(index) {
                finish()
                paragraphs.append(line)
            } else if current.isEmpty {
                current = line
            } else if current.hasSuffix("-"), !current.hasSuffix(" -") {
                current += line
            } else {
                current += " " + line
            }
        }
        finish()
        return paragraphs.joined(separator: "\n\n")
    }
}
