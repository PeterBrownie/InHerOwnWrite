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
    /// Words a reading on this Mac changed or wasn't sure of. Missing on other readings.
    public var wordNotes: [WordNote]?
    /// Who a name on this page means, when she said ("Hannah" → "Hannah K."), by `PeopleDirectory.key`.
    public var people: [String: String]?

    public init(markers: [EntryMarker], names: [String], text: String, wordNotes: [WordNote]? = nil) {
        self.markers = markers
        self.names = names
        textDigest = Self.digest(text)
        self.wordNotes = wordNotes
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

/// A line that is only a time of day, "9:30 pm" or "21:15", starting a later entry on the same day.
public enum TimeHeadingParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"^\s*(?:at\s*)?(?<hour>\d{1,2})(?::(?<minute>\d{2}))?\s*(?<meridiem>a\.?m\.?|p\.?m\.?)?[\s.,;:\-–—]*$"#,
        options: [.caseInsensitive])

    public static func parse(_ line: String) -> EntryMarker? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard (3...16).contains(text.count),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        func group(_ name: String) -> String? {
            let range = match.range(withName: name)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        guard var hour = group("hour").flatMap(Int.init) else { return nil }
        let minute = group("minute").flatMap(Int.init)
        let meridiem = group("meridiem")?.lowercased()
        // A bare number is a page number or a count, not a time.
        guard minute != nil || meridiem != nil, (minute ?? 0) < 60 else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0)
        }
        guard hour < 24 else { return nil }
        return EntryMarker(headingLine: text, time: String(format: "%02d:%02d", hour, minute ?? 0))
    }
}

public enum EntryBuilder {
    /// A date line as the app writes it when a date is set by hand: "Thursday, March 5, 2026 9:30 pm".
    public static func headingLine(year: Int, month: Int, day: Int, hour: Int? = nil, minute: Int = 0) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
        let weekday = date.map { weekdays[calendar.component(.weekday, from: $0) - 1] + ", " } ?? ""
        var line = "\(weekday)\(DateFormatter.monthName(month)) \(day), \(year)"
        if let hour {
            let shown = hour % 12 == 0 ? 12 : hour % 12
            line += String(format: " %d:%02d %@", shown, minute, hour < 12 ? "am" : "pm")
        }
        return line
    }

    /// The page text with an entry part's date line replaced, or added above the part when it has none.
    public static func settingHeading(_ line: String, of part: EntryPart, in text: String) -> String {
        var lines = lines(of: text)
        if part.heading != nil, lines.indices.contains(part.startLine) {
            lines[part.startLine] = line
        } else {
            // The part's writing starts at its first non-blank line.
            let start = lines.indices.first { $0 >= part.startLine && !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
                ?? part.startLine
            lines.insert(line, at: min(start, lines.count))
        }
        return lines.joined(separator: "\n")
    }

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
        // A time alone starts an entry only when it stands apart: first on the page or after a blank line.
        for (index, line) in lines.enumerated() where found[index] == nil {
            guard index == 0 || lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty,
                  let parsed = TimeHeadingParser.parse(line) else { continue }
            found[index] = parsed
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
                var marker = heading.marker
                // A time alone takes its day from the entry before.
                if marker.month == nil, marker.time != nil, let previous = entries.last {
                    (marker.weekday, marker.year, marker.month, marker.day) = (previous.weekday, previous.year,
                                                                               previous.month, previous.day)
                }
                entries.append(JournalEntry(
                    id: part.id, journalID: journalID, heading: headingText, weekday: marker.weekday,
                    year: marker.year, month: marker.month, day: marker.day,
                    time: marker.time, parts: [part]
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
        mapped(text, headingLines: headingLines).text
    }

    /// Flowing text that remembers where each of its characters came from, so an edit made to it can be
    /// made to the text as written, keeping her line breaks.
    public struct Flowed: Sendable {
        public let text: String
        /// For each UTF-16 unit of `text`, its offset in the written text, or -1 for a joining space or a
        /// paragraph break the flow added.
        let sources: [Int]

        /// The written text's range for a range of the flowing text, for replacing it.
        public func writtenRange(for range: NSRange) -> NSRange {
            let start: Int
            if range.location < sources.count, sources[range.location] >= 0 {
                start = sources[range.location]
            } else {
                // At a joining space: the end of the line before it.
                start = (sources[..<min(range.location, sources.count)].last { $0 >= 0 }).map { $0 + 1 } ?? 0
            }
            let end = sources[range.location..<min(NSMaxRange(range), sources.count)].filter { $0 >= 0 }.max().map { $0 + 1 }
            return NSRange(location: start, length: max((end ?? start) - start, 0))
        }

        /// Where a range of the written text appears in the flowing text, if all of it does.
        public func flowedRange(for written: NSRange) -> NSRange? {
            guard written.length > 0,
                  let first = sources.firstIndex(of: written.location),
                  let last = sources.firstIndex(of: NSMaxRange(written) - 1), last >= first
            else { return nil }
            return NSRange(location: first, length: last - first + 1)
        }

        /// The written text after an edit to the flowing text, which changed it from `text` to `edited`.
        public func applying(_ edited: String, to written: String) -> String {
            let old = text as NSString, new = edited as NSString
            var prefix = 0
            while prefix < old.length, prefix < new.length, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < old.length - prefix, suffix < new.length - prefix,
                  old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
            let replaced = NSRange(location: prefix, length: old.length - prefix - suffix)
            let inserted = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
            return (written as NSString).replacingCharacters(in: writtenRange(for: replaced), with: inserted)
        }
    }

    public static func mapped(_ text: String, headingLines: Set<Int> = []) -> Flowed {
        let written = text as NSString
        var paragraphs: [(units: [unichar], sources: [Int])] = []
        var current: (units: [unichar], sources: [Int]) = ([], [])

        func finish() {
            if !current.units.isEmpty { paragraphs.append(current) }
            current = ([], [])
        }

        var lineStart = 0
        var index = 0
        while lineStart <= written.length {
            let rest = NSRange(location: lineStart, length: written.length - lineStart)
            let newline = written.range(of: "\n", options: [], range: rest)
            let lineEnd = newline.location == NSNotFound ? written.length : newline.location
            // The line without surrounding spaces, tabs, or a carriage return.
            var first = lineStart, last = lineEnd
            func isBlank(_ unit: unichar) -> Bool { unit == 32 || unit == 9 || unit == 13 }
            while first < last, isBlank(written.character(at: first)) { first += 1 }
            while last > first, isBlank(written.character(at: last - 1)) { last -= 1 }
            let units = (first..<last).map { written.character(at: $0) }
            let sources = Array(first..<last)

            if units.isEmpty {
                finish()
            } else if headingLines.contains(index) {
                finish()
                paragraphs.append((units, sources))
            } else if current.units.isEmpty {
                current = (units, sources)
            } else if current.units.last == 45, !(current.units.count >= 2 && current.units[current.units.count - 2] == 32) {
                // A word hyphenated across lines joins without a space.
                current.units += units
                current.sources += sources
            } else {
                current.units += [32] + units
                current.sources += [-1] + sources
            }
            index += 1
            if newline.location == NSNotFound { break }
            lineStart = lineEnd + 1
        }
        finish()

        var units: [unichar] = [], sources: [Int] = []
        for (number, paragraph) in paragraphs.enumerated() {
            if number > 0 {
                units += [10, 10]
                sources += [-1, -1]
            }
            units += paragraph.units
            sources += paragraph.sources
        }
        return Flowed(text: String(utf16CodeUnits: units, count: units.count), sources: sources)
    }
}
