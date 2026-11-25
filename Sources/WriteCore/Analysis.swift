import Foundation

public struct WordToken: Hashable, Sendable {
    public let key: String
    public let surface: String
}

public enum WordTokenizer {
    private static let keptContractions: Set<String> = [
        "it's", "that's", "he's", "she's", "what's", "there's", "here's", "who's", "let's", "how's", "where's",
        "when's", "why's",
    ]

    /// Splits text into words. Possessives count toward the name, so "Theo's" counts as "Theo".
    public static func tokens(in text: String) -> [WordToken] {
        let cleaned = text
            .replacingOccurrences(of: "[illegible]", with: " ")
            .replacingOccurrences(of: "###", with: " ")
            .replacingOccurrences(of: "’", with: "'")
        var tokens: [WordToken] = []
        var current = String.UnicodeScalarView()

        func flush() {
            guard !current.isEmpty else { return }
            var word = String(current)
            current = String.UnicodeScalarView()
            while word.hasSuffix("'") { word.removeLast() }
            while word.hasPrefix("'") { word.removeFirst() }
            guard !word.isEmpty, !word.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) else { return }
            let lower = word.lowercased()
            if lower.hasSuffix("'s"), !keptContractions.contains(lower) { word.removeLast(2) }
            guard !word.isEmpty else { return }
            tokens.append(WordToken(key: key(word), surface: word))
        }

        for scalar in cleaned.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    public static func key(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}

/// Finds a word or phrase in page text, wherever the handwriting's lines happen to break.
public enum TextSearch {
    /// Case, accents, curly apostrophes, and runs of spaces or line breaks don't matter, and part of a word
    /// still matches ("walk" finds "walked").
    public static func contains(_ text: String, _ query: String) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return false }
        return normalized(text).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Where the query appears in the text, matched the way `contains` matches, as ranges of the text itself
    /// (UTF-16, for `NSString` and text views).
    public static func ranges(of query: String, in text: String) -> [NSRange] {
        let needle = fold(normalized(query))
        guard !needle.isEmpty else { return [] }
        // The text folded the same way, with each folded unit pointing back to the character it came from.
        var folded = ""
        var origins: [NSRange] = []
        var lastWasSpace = false
        var offset = 0
        for character in text {
            let length = String(character).utf16.count
            let source = NSRange(location: offset, length: length)
            offset += length
            if character.isWhitespace || character.isNewline {
                if !lastWasSpace {
                    folded += " "
                    origins.append(source)
                }
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            let piece = fold(character == "’" ? "'" : String(character))
            folded += piece
            origins.append(contentsOf: Array(repeating: source, count: piece.utf16.count))
        }
        let haystack = folded as NSString
        var found: [NSRange] = []
        var start = 0
        while start < haystack.length {
            let hit = haystack.range(of: needle, options: .literal, range: NSRange(location: start, length: haystack.length - start))
            guard hit.location != NSNotFound, hit.length > 0 else { break }
            let first = origins[hit.location], last = origins[NSMaxRange(hit) - 1]
            found.append(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
            start = NSMaxRange(hit)
        }
        return found
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}

public enum CommonWords {
    public static let all: Set<String> = Set("""
        a about above after again against all also am an and any are aren't as at be because been before being below \
        between both but by can can't cannot could couldn't did didn't do does doesn't doing don't down during each \
        even ever every few for from further get gets getting go goes going gone got had hadn't has hasn't have \
        haven't having he he'd he'll he's her here here's hers herself him himself his how how's i i'd i'll i'm i've \
        if in into is isn't it it's its itself just know let let's like made make many may me might more most much \
        must mustn't my myself no nor not now of off on once one only or other ought our ours ourselves out over own \
        really said same say says see she she'd she'll she's should shouldn't so some still such than that that's \
        the their theirs them themselves then there there's these they they'd they'll they're they've thing things \
        think this those though through to too two under until up us very was wasn't we we'd we'll we're we've well \
        went were weren't what what's when when's where where's which while who who's whom why why's will with won't \
        would wouldn't yes yet you you'd you'll you're you've your yours yourself yourselves
        """.split(separator: " ").map(String.init))
}

/// Parses page lists such as "1-40, 52, 60-". Blank means every page.
public struct PageSelection: Equatable, Sendable {
    public let ranges: [ClosedRange<Int>]

    public static func parse(_ text: String) -> PageSelection? {
        let pieces = text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "–", with: "-") }
            .filter { !$0.isEmpty }
        var ranges: [ClosedRange<Int>] = []
        for piece in pieces {
            if let single = Int(piece), single >= 1 {
                ranges.append(single...single)
                continue
            }
            let ends = piece.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard ends.count == 2, !(ends[0].isEmpty && ends[1].isEmpty) else { return nil }
            let low = ends[0].isEmpty ? 1 : Int(ends[0])
            let high = ends[1].isEmpty ? Vault.maximumPageNumber : Int(ends[1])
            guard let low, let high, low >= 1, low <= high else { return nil }
            ranges.append(low...high)
        }
        return PageSelection(ranges: ranges)
    }

    public func contains(_ number: Int) -> Bool {
        ranges.isEmpty || ranges.contains { $0.contains(number) }
    }
}

public struct WordStat: Identifiable, Hashable, Sendable {
    public let key: String
    public let display: String
    public let count: Int
    public let pageCount: Int

    public var id: String { key }
}

public enum TimelineAxis: String, CaseIterable, Identifiable, Sendable {
    case date
    case pages

    public var id: String { rawValue }
}

public struct TimelineBin: Identifiable, Hashable, Sendable {
    public let id: Int
    public let label: String
    public let shortLabel: String
    public let count: Int
    public let pageCount: Int
    /// The entries counted in this bin, by `JournalEntry.id`; only charts of entries fill it in.
    public var entryIDs: [String] = []
}

/// A running figure as it stood at the end of one month or week, counting only entries dated up to then.
public struct TrendPoint: Identifiable, Hashable, Sendable {
    public let id: Int
    public let label: String
    public let shortLabel: String
    /// Nil while there's nothing to go on yet. For times, minutes after midnight, kept within 12 hours of the
    /// overall usual time so a line through midnight doesn't jump from one edge of the chart to the other.
    public let value: Double?
    /// The value as the tile shows it: "1.5" or "9:40 PM".
    public let display: String
}

/// How often entries were written, from their dates.
public struct EntryRhythm: Sendable {
    /// The longest stretch between two entries written on different days.
    public struct Gap: Sendable, Equatable {
        public let days: Int
        public let from: String
        public let to: String

        public init(days: Int, from: String, to: String) {
            self.days = days
            self.from = from
            self.to = to
        }
    }

    public let entryCount: Int
    public let datedCount: Int
    /// Every month from the first dated entry to the last, empty ones included.
    public let byMonth: [TimelineBin]
    /// Every week, Monday to Sunday, from the first dated entry to the last.
    public let byWeek: [TimelineBin]
    /// Dated entries divided by the months, or weeks, from the first to the last; nil with none dated.
    public let perMonth: Double?
    public let perWeek: Double?
    public let longestGap: Gap?
    public let first: String?
    public let last: String?
    /// Dated entries by day of the week, Monday first.
    public var byWeekday: [TimelineBin] = []
    /// The longest run of consecutive days with an entry, as days and its first and last day.
    public var longestStreak: Gap?
    /// The run that ends today or yesterday; 0 when the last entry is older than that.
    public var currentStreak = 0
    /// Entries with a time in their heading, in three-hour blocks from midnight.
    public var byTimeOfDay: [TimelineBin] = []
    public var timedCount = 0
    /// The usual time of writing, "9:40 PM", averaged around the clock so 11 PM and 1 AM give midnight.
    public var averageTime: String?
    /// The average per month and per week as they stood at the end of each month and week.
    public var perMonthTrend: [TrendPoint] = []
    public var perWeekTrend: [TrendPoint] = []
    /// The usual time as it stood at the end of each month and week, from dated entries with a time.
    public var timeTrendByMonth: [TrendPoint] = []
    public var timeTrendByWeek: [TrendPoint] = []
}

public struct TermResult: Sendable {
    public let display: String
    public let total: Int
    public let pageCount: Int
    public let entryCount: Int
    public let undatedMentions: Int
    public let byDate: [TimelineBin]
    public let byPage: [TimelineBin]
}

/// One place a looked-up word appears: part of an entry on one page.
public struct TermMatch: Identifiable, Hashable, Sendable {
    public let id: String
    public let pageID: UUID
    public let pageNumber: Int
    /// The journal's name, only when the chosen pages come from more than one journal.
    public let journalName: String?
    /// The entry's date, or nil for undated writing.
    public let date: String?
    public let count: Int
    /// Text around the first mention, about two lines' worth, with "…" where it was cut.
    public let snippet: String
    /// Where the first mention sits in `snippet`, for highlighting.
    public let highlight: Range<Int>?

    /// The mention as written, such as "Hannah" for a lookup of "Hannah K.".
    public var highlightedText: String? {
        guard let highlight, highlight.upperBound <= snippet.count else { return nil }
        return String(Array(snippet)[highlight])
    }
}

/// A prepared copy of the chosen pages, safe to compute away from the main thread.
public struct AnalysisSnapshot: Sendable {
    struct Unit: Sendable {
        let journalID: UUID
        let pageID: UUID
        let pageNumber: Int
        let entryID: String
        let year: Int?
        let month: Int?
        let day: Int?
        let date: String?
        let time: String?
        let body: String
        let keys: [String]
    }

    private static let maxPageBins = 30
    private static let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// One person's mentions: how many in each unit, and the names as written there, for highlighting.
    struct PersonCounts: Sendable {
        var display: String
        var perUnit: [Int]
        var written: [Int: [String]]
    }

    let units: [Unit]
    private let journalNames: [UUID: String]
    private let nameList: [String]
    /// The people the names mean, by `PeopleDirectory.key` of their label ("Hannah K.", "Hannah (unsure which)").
    private let persons: [String: PersonCounts]
    public let pageCount: Int
    public let entryCount: Int
    public let datedEntryCount: Int
    public let wordTotal: Int
    public let words: [WordStat]

    /// `people` says who each name means on each page; without it, each name counts as written.
    public init(entries: [JournalEntry], includedPages: Set<UUID>, names: [String], people: PeopleDirectory? = nil,
                journalNames: [UUID: String]) {
        var units: [Unit] = []
        var counts: [String: Int] = [:]
        var surfaces: [String: [String: Int]] = [:]
        var pagesByWord: [String: Set<UUID>] = [:]
        var entryIDs = Set<String>()
        var datedIDs = Set<String>()

        for entry in entries {
            for part in entry.parts where includedPages.contains(part.pageID) {
                let tokens = WordTokenizer.tokens(in: part.body)
                units.append(Unit(journalID: entry.journalID, pageID: part.pageID, pageNumber: part.pageNumber,
                                  entryID: entry.id, year: entry.year, month: entry.month, day: entry.day,
                                  date: entry.isDated ? entry.title : nil, time: entry.time, body: part.body,
                                  keys: tokens.map(\.key)))
                entryIDs.insert(entry.id)
                if entry.isDated && entry.year != nil { datedIDs.insert(entry.id) }
                for token in tokens {
                    counts[token.key, default: 0] += 1
                    surfaces[token.key, default: [:]][token.surface, default: 0] += 1
                    pagesByWord[token.key, default: []].insert(part.pageID)
                }
            }
        }

        self.units = units
        self.journalNames = journalNames
        nameList = names
        persons = Self.countPersons(names: names, units: units, people: people)
        pageCount = Set(units.map(\.pageID)).count
        entryCount = entryIDs.count
        datedEntryCount = datedIDs.count
        wordTotal = counts.values.reduce(0, +)
        words = counts.map { key, count in
            let forms = surfaces[key] ?? [:]
            let display = forms.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? key
            return WordStat(key: key, display: display, count: count, pageCount: pagesByWord[key]?.count ?? 0)
        }
        .sorted { ($1.count, $0.key) < ($0.count, $1.key) }
    }

    public func visibleWords(hidden: Set<String>, includeCommon: Bool) -> [WordStat] {
        words.filter { !hidden.contains($0.key) && (includeCommon || !CommonWords.all.contains($0.key)) }
    }

    /// People named in the chosen pages, counted wherever their names appear. A name counts as the person it
    /// means on that page ("Hannah" as "Hannah K." where she said so), and a first name that's part of a fuller
    /// name written there ("Hannah Kim") counts once, as the fuller name.
    public func nameStats(hidden: Set<String>) -> [WordStat] {
        persons.compactMap { key, person -> WordStat? in
            let count = person.perUnit.reduce(0, +)
            guard !hidden.contains(key) else { return nil }
            let pages = Set(zip(units, person.perUnit).filter { $0.1 > 0 }.map(\.0.pageID)).count
            return WordStat(key: key, display: person.display, count: count, pageCount: pages)
        }
        .sorted { ($1.count, $0.key) < ($0.count, $1.key) }
    }

    private static func countPersons(names: [String], units: [Unit], people: PeopleDirectory?) -> [String: PersonCounts] {
        // Each name once, longest first, so a fuller name claims its words before a first name can.
        var seen = Set<String>()
        let written = names.compactMap { name -> (name: String, keys: [String])? in
            let keys = WordTokenizer.tokens(in: name).map(\.key)
            guard !keys.isEmpty, seen.insert(keys.joined(separator: " ")).inserted else { return nil }
            return (name, keys)
        }
        .sorted { ($0.keys.count, $1.name) > ($1.keys.count, $0.name) }
        var persons: [String: PersonCounts] = [:]
        for (index, unit) in units.enumerated() {
            var taken = [Bool](repeating: false, count: unit.keys.count)
            for name in written {
                var count = 0
                var position = 0
                while position + name.keys.count <= unit.keys.count {
                    let span = position..<(position + name.keys.count)
                    if Array(unit.keys[span]) == name.keys, !span.contains(where: { taken[$0] }) {
                        span.forEach { taken[$0] = true }
                        count += 1
                        position += name.keys.count
                    } else {
                        position += 1
                    }
                }
                guard count > 0 else { continue }
                let label = people?.resolve(name.name, onPage: unit.pageID).label ?? name.name
                let key = PeopleDirectory.key(label)
                guard !key.isEmpty else { continue }
                persons[key, default: PersonCounts(display: label, perUnit: [Int](repeating: 0, count: units.count),
                                                   written: [:])].perUnit[index] += count
                persons[key]?.written[index, default: []].append(name.keys.joined(separator: " "))
            }
        }
        // Every name found stays in the list, even one with no mention in the entries' text, such as a name
        // only in a heading.
        let mentioned = Set(persons.values.flatMap { $0.written.values.flatMap { $0 } })
        for name in written where !mentioned.contains(name.keys.joined(separator: " ")) {
            let key = PeopleDirectory.key(name.name)
            guard persons[key] == nil else { continue }
            persons[key] = PersonCounts(display: name.name, perUnit: [Int](repeating: 0, count: units.count), written: [:])
        }
        return persons
    }

    /// The person a looked-up term names, when it's one of the labels in the Names list.
    private func person(_ text: String) -> PersonCounts? {
        persons[PeopleDirectory.key(text)]
    }

    /// A word, phrase, or person: a label from the Names list ("Hannah K.") counts that person's mentions, under
    /// whatever name was written.
    public func term(_ text: String) -> TermResult? {
        let tokens = WordTokenizer.tokens(in: text)
        guard !tokens.isEmpty else { return nil }
        let keys = tokens.map(\.key)
        let person = person(text)
        let perUnit = person?.perUnit ?? units.map { Self.occurrences(of: keys, in: $0.keys) }
        let hits = zip(units, perUnit).filter { $0.1 > 0 }
        let undated = zip(units, perUnit).reduce(0) { total, pair in
            total + (Self.dayNumber(pair.0) == nil ? pair.1 : 0)
        }
        return TermResult(
            display: person?.display ?? tokens.map(\.surface).joined(separator: " "),
            total: perUnit.reduce(0, +),
            pageCount: Set(hits.map(\.0.pageID)).count,
            entryCount: Set(hits.map(\.0.entryID)).count,
            undatedMentions: undated,
            byDate: dateBins(perUnit),
            byPage: pageBins(perUnit)
        )
    }

    /// Several words or names to compare, separated by commas. Empty parts are skipped.
    public func terms(_ text: String) -> [TermResult] {
        Self.splitTerms(text).compactMap(term)
    }

    public static func splitTerms(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Every entry part that mentions the word or phrase, in journal order, with text around the first mention.
    public func matches(_ text: String) -> [TermMatch] {
        let keys = WordTokenizer.tokens(in: text).map(\.key)
        guard !keys.isEmpty else { return [] }
        let multipleJournals = Set(units.map(\.journalID)).count > 1
        let person = person(text)
        return units.enumerated().compactMap { index, unit in
            let count = person?.perUnit[index] ?? Self.occurrences(of: keys, in: unit.keys)
            guard count > 0 else { return nil }
            // A person is highlighted under the name written here.
            let shown = person?.written[index]?.first.map { $0.split(separator: " ").map(String.init) } ?? keys
            let (snippet, highlight) = Self.snippet(of: shown, in: unit.body)
            return TermMatch(id: "\(index)", pageID: unit.pageID, pageNumber: unit.pageNumber,
                             journalName: multipleJournals ? journalNames[unit.journalID] : nil,
                             date: unit.date, count: count, snippet: snippet, highlight: highlight)
        }
    }

    /// About two lines of text around the first place the words appear, on one line.
    public static func snippet(of keys: [String], in body: String, before: Int = 70, after: Int = 110) -> (String, Range<Int>?) {
        let flat = body.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        // Find words with their positions, matched the way the tokenizer keys them.
        var words: [(key: String, range: Range<String.Index>)] = []
        var start: String.Index?
        var index = flat.startIndex
        func close(_ end: String.Index) {
            guard let from = start else { return }
            start = nil
            let tokens = WordTokenizer.tokens(in: String(flat[from..<end]))
            if let token = tokens.first, tokens.count == 1 { words.append((token.key, from..<end)) }
        }
        while index < flat.endIndex {
            let character = flat[index]
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                if start == nil { start = index }
            } else {
                close(index)
            }
            index = flat.index(after: index)
        }
        close(flat.endIndex)

        var found: Range<String.Index>?
        if words.count >= keys.count {
            for position in 0...(words.count - keys.count)
            where zip(words[position..<(position + keys.count)], keys).allSatisfy({ $0.0.key == $0.1 }) {
                found = words[position].range.lowerBound..<words[position + keys.count - 1].range.upperBound
                break
            }
        }
        guard let found else {
            let text = String(flat.prefix(before + after))
            return (text.count < flat.count ? text + "…" : text, nil)
        }
        var from = flat.index(found.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        var to = flat.index(found.upperBound, offsetBy: after, limitedBy: flat.endIndex) ?? flat.endIndex
        // Cut at spaces so words aren't split.
        if from > flat.startIndex, let space = flat[from..<found.lowerBound].firstIndex(of: " ") {
            from = flat.index(after: space)
        }
        if to < flat.endIndex, let space = flat[found.upperBound..<to].lastIndex(of: " ") { to = space }
        let prefix = from > flat.startIndex ? "…" : ""
        let suffix = to < flat.endIndex ? "…" : ""
        let lower = prefix.count + flat.distance(from: from, to: found.lowerBound)
        let upper = lower + flat.distance(from: found.lowerBound, to: found.upperBound)
        return (prefix + flat[from..<to] + suffix, lower..<upper)
    }

    /// Entries per month and per week, the averages over the whole span, and the longest gap. An entry that
    /// runs over several pages counts once, on its date.
    public func entryRhythm() -> EntryRhythm {
        var days: [String: Int] = [:]
        var pages: [String: Set<UUID>] = [:]
        for unit in units {
            pages[unit.entryID, default: []].insert(unit.pageID)
            if let day = Self.dayNumber(unit) { days[unit.entryID] = day }
        }
        let dated = days.map { (entry: $0.key, day: $0.value) }
        guard let firstDay = dated.map(\.day).min(), let lastDay = dated.map(\.day).max() else {
            return EntryRhythm(entryCount: entryCount, datedCount: 0, byMonth: [], byWeek: [], perMonth: nil,
                               perWeek: nil, longestGap: nil, first: nil, last: nil)
        }

        func bins(index: (Int) -> Int, count: Int, label: (Int) -> (full: String, short: String)) -> [TimelineBin] {
            var entries = [[String]](repeating: [], count: count)
            var binPages = [Set<UUID>](repeating: [], count: count)
            for item in dated {
                let bin = index(item.day)
                entries[bin].append(item.entry)
                binPages[bin].formUnion(pages[item.entry] ?? [])
            }
            return (0..<count).map { bin in
                let names = label(bin)
                return TimelineBin(id: bin, label: names.full, shortLabel: names.short, count: entries[bin].count,
                                   pageCount: binPages[bin].count, entryIDs: entries[bin])
            }
        }

        let origin = Self.components(day: firstDay)
        let originMonth = origin.year * 12 + origin.month - 1
        let month = { (day: Int) -> Int in
            let date = Self.components(day: day)
            return date.year * 12 + date.month - 1 - originMonth
        }
        let months = month(lastDay) + 1
        let byMonth = bins(index: month, count: months) { index in
            let total = originMonth + index
            let name = Self.shortMonths[total % 12]
            return ("\(name) \(total / 12)", "\(name) \(String(total / 12).suffix(2))")
        }

        // Day 0, January 1, 1970, was a Thursday, so weeks counted from day -3 start on Mondays.
        let week = { (day: Int) -> Int in Int((Double(day + 3) / 7).rounded(.down)) }
        let firstWeek = week(firstDay)
        let weeks = week(lastDay) - firstWeek + 1
        let byWeek = bins(index: { week($0) - firstWeek }, count: weeks) { index in
            let monday = (firstWeek + index) * 7 - 3
            return ("Week of \(Self.label(day: monday))", Self.label(day: monday, withYear: false))
        }

        let distinct = Array(Set(dated.map(\.day))).sorted()
        let gap = zip(distinct, distinct.dropFirst()).max { ($0.1 - $0.0) < ($1.1 - $1.0) }

        let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        let weekday = { (day: Int) -> Int in ((day + 3) % 7 + 7) % 7 }
        let byWeekday = bins(index: weekday, count: 7) { (weekdayNames[$0], String(weekdayNames[$0].prefix(3))) }

        var runs: [(start: Int, end: Int)] = []
        for day in distinct {
            if let last = runs.last, last.end == day - 1 { runs[runs.count - 1].end = day } else { runs.append((day, day)) }
        }
        let longest = runs.max { ($0.end - $0.start) < ($1.end - $1.start) }
        let today = Self.dayNumber(Date())
        let current = runs.last.map { $0.end >= today - 1 && $0.end <= today ? $0.end - $0.start + 1 : 0 } ?? 0
        var rhythm = EntryRhythm(
            entryCount: entryCount,
            datedCount: dated.count,
            byMonth: byMonth,
            byWeek: byWeek,
            perMonth: Double(dated.count) / Double(months),
            perWeek: Double(dated.count) / Double(weeks),
            longestGap: gap.map { EntryRhythm.Gap(days: $0.1 - $0.0, from: Self.label(day: $0.0), to: Self.label(day: $0.1)) },
            first: Self.label(day: firstDay),
            last: Self.label(day: lastDay)
        )
        rhythm.byWeekday = byWeekday
        rhythm.longestStreak = longest.map {
            EntryRhythm.Gap(days: $0.end - $0.start + 1, from: Self.label(day: $0.start), to: Self.label(day: $0.end))
        }
        rhythm.currentStreak = current
        (rhythm.byTimeOfDay, rhythm.timedCount, rhythm.averageTime) = timeOfDay(pages: pages)

        func running(_ bins: [TimelineBin]) -> [TrendPoint] {
            var total = 0
            return bins.enumerated().map { index, bin in
                total += bin.count
                let value = Double(total) / Double(index + 1)
                return TrendPoint(id: index, label: bin.label, shortLabel: bin.shortLabel, value: value,
                                  display: value.formatted(.number.precision(.fractionLength(1))))
            }
        }
        rhythm.perMonthTrend = running(byMonth)
        rhythm.perWeekTrend = running(byWeek)

        let minutes = entryMinutes()
        let timed = dated.compactMap { item in minutes[item.entry].map { (day: item.day, minute: $0) } }
        if let overall = Self.usualMinute(timed.map(\.minute)) {
            func runningTime(_ bins: [TimelineBin], index: (Int) -> Int) -> [TrendPoint] {
                var sorted = [[Int]](repeating: [], count: bins.count)
                for item in timed { sorted[index(item.day)].append(item.minute) }
                var sofar: [Int] = []
                return bins.enumerated().map { bin, info in
                    sofar += sorted[bin]
                    guard let minute = Self.usualMinute(sofar) else {
                        return TrendPoint(id: bin, label: info.label, shortLabel: info.shortLabel, value: nil, display: "")
                    }
                    var unwrapped = minute
                    while unwrapped < overall - 720 { unwrapped += 1440 }
                    while unwrapped >= overall + 720 { unwrapped -= 1440 }
                    return TrendPoint(id: bin, label: info.label, shortLabel: info.shortLabel, value: Double(unwrapped),
                                      display: Self.clock(minute))
                }
            }
            rhythm.timeTrendByMonth = runningTime(byMonth, index: month)
            rhythm.timeTrendByWeek = runningTime(byWeek) { week($0) - firstWeek }
        }
        return rhythm
    }

    /// "Feb 9, 2026", or "Feb 9".
    private static func label(day: Int, withYear: Bool = true) -> String {
        let date = components(day: day)
        let short = "\(shortMonths[date.month - 1]) \(date.day)"
        return withYear ? "\(short), \(date.year)" : short
    }

    public static func occurrences(of phrase: [String], in keys: [String]) -> Int {
        guard !phrase.isEmpty, keys.count >= phrase.count else { return 0 }
        if phrase.count == 1 { return keys.reduce(0) { $0 + ($1 == phrase[0] ? 1 : 0) } }
        var count = 0
        var index = 0
        while index <= keys.count - phrase.count {
            if Array(keys[index..<(index + phrase.count)]) == phrase {
                count += 1
                index += phrase.count
            } else {
                index += 1
            }
        }
        return count
    }

    // MARK: - Timelines

    private func pageBins(_ perUnit: [Int]) -> [TimelineBin] {
        var ordered: [(journal: UUID, page: UUID, number: Int)] = []
        var positions: [UUID: Int] = [:]
        for unit in units where positions[unit.pageID] == nil {
            positions[unit.pageID] = ordered.count
            ordered.append((unit.journalID, unit.pageID, unit.pageNumber))
        }
        guard !ordered.isEmpty else { return [] }

        let size = max(1, Int((Double(ordered.count) / Double(Self.maxPageBins)).rounded(.up)))
        let binCount = Int((Double(ordered.count) / Double(size)).rounded(.up))
        var counts = [Int](repeating: 0, count: binCount)
        for (unit, count) in zip(units, perUnit) {
            if let position = positions[unit.pageID] { counts[position / size] += count }
        }
        let multipleJournals = Set(ordered.map(\.journal)).count > 1
        return (0..<binCount).map { bin in
            let first = ordered[bin * size]
            let last = ordered[min((bin + 1) * size, ordered.count) - 1]
            let range = first.number == last.number || first.journal != last.journal
                ? (first.journal == last.journal ? "p. \(first.number)" : "p. \(first.number) to \(last.number)")
                : "pp. \(first.number)–\(last.number)"
            let name = multipleJournals ? "\(journalNames[first.journal] ?? "Journal"), " : ""
            let pages = min((bin + 1) * size, ordered.count) - bin * size
            return TimelineBin(id: bin, label: name + range, shortLabel: "p. \(first.number)",
                               count: counts[bin], pageCount: pages)
        }
    }

    private func dateBins(_ perUnit: [Int]) -> [TimelineBin] {
        let dated = zip(units, perUnit).compactMap { unit, count -> (unit: Unit, day: Int, count: Int)? in
            Self.dayNumber(unit).map { (unit, $0, count) }
        }
        guard let first = dated.map(\.day).min(), let last = dated.map(\.day).max() else { return [] }
        let span = last - first

        struct Key: Hashable { let value: Int }
        let bucket: (Int) -> Int
        let label: (Int) -> (full: String, short: String)
        if span <= 120 {
            bucket = { ($0 - first) / 7 }
            label = { index in
                let start = Self.components(day: first + index * 7)
                let end = Self.components(day: first + index * 7 + 6)
                let short = "\(Self.shortMonths[start.month - 1]) \(start.day)"
                return ("\(short) – \(Self.shortMonths[end.month - 1]) \(end.day), \(end.year)", short)
            }
        } else if span <= 365 * 6 {
            let origin = Self.components(day: first)
            let originMonth = origin.year * 12 + origin.month - 1
            bucket = { day in
                let date = Self.components(day: day)
                return date.year * 12 + date.month - 1 - originMonth
            }
            label = { index in
                let total = originMonth + index
                let name = Self.shortMonths[total % 12]
                return ("\(name) \(total / 12)", "\(name) \(String(total / 12).suffix(2))")
            }
        } else {
            let originYear = Self.components(day: first).year
            bucket = { Self.components(day: $0).year - originYear }
            label = { ("\(originYear + $0)", "\(originYear + $0)") }
        }

        let binCount = bucket(last) + 1
        var counts = [Int](repeating: 0, count: binCount)
        var pages = [Set<UUID>](repeating: [], count: binCount)
        for item in dated {
            let index = bucket(item.day)
            counts[index] += item.count
            pages[index].insert(item.unit.pageID)
        }
        return (0..<binCount).map { index in
            let names = label(index)
            return TimelineBin(id: index, label: names.full, shortLabel: names.short,
                               count: counts[index], pageCount: pages[index].count)
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func dayNumber(_ unit: Unit) -> Int? {
        guard let year = unit.year, let month = unit.month, let day = unit.day,
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        return Int(date.timeIntervalSince1970 / 86_400)
    }

    /// Entries by the time in their headings, in three-hour blocks, and their average time.
    /// Minutes after midnight for each entry with a time in its heading.
    private func entryMinutes() -> [String: Int] {
        var minutes: [String: Int] = [:]
        for unit in units where minutes[unit.entryID] == nil {
            let parts = unit.time?.split(separator: ":").compactMap { Int($0) } ?? []
            if parts.count == 2 { minutes[unit.entryID] = parts[0] * 60 + parts[1] }
        }
        return minutes
    }

    func timeOfDay(pages: [String: Set<UUID>]) -> ([TimelineBin], Int, String?) {
        let minutes = entryMinutes()
        guard !minutes.isEmpty else { return ([], 0, nil) }
        var counts = [Int](repeating: 0, count: 8)
        var binPages = [Set<UUID>](repeating: [], count: 8)
        for (entry, minute) in minutes {
            counts[minute / 180] += 1
            binPages[minute / 180].formUnion(pages[entry] ?? [])
        }
        let short = ["12a", "3a", "6a", "9a", "12p", "3p", "6p", "9p"]
        let bins = (0..<8).map { index in
            TimelineBin(id: index, label: "\(Self.clock(index * 180)) to \(Self.clock(index * 180 + 179))", shortLabel: short[index],
                        count: counts[index], pageCount: binPages[index].count)
        }
        return (bins, minutes.count, Self.usualMinute(Array(minutes.values)).map(Self.clock))
    }

    /// The usual time, averaged around the clock so 11 PM and 1 AM give midnight, to the nearest five minutes.
    /// Nil when there are no times, or they're spread so evenly around the clock that no average means much.
    static func usualMinute(_ minutes: [Int]) -> Int? {
        guard !minutes.isEmpty else { return nil }
        var x = 0.0, y = 0.0
        for minute in minutes {
            let angle = Double(minute) / 1440 * 2 * .pi
            x += cos(angle)
            y += sin(angle)
        }
        guard (x * x + y * y).squareRoot() / Double(minutes.count) > 0.3 else { return nil }
        var angle = atan2(y, x)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle / (2 * .pi) * 1440).rounded()) % 1440 / 5 * 5
    }

    /// "9:40 PM" for minutes after midnight; any whole number of days either way is ignored.
    public static func clock(_ minute: Int) -> String {
        let wrapped = (minute % 1440 + 1440) % 1440
        let hour = wrapped / 60
        let shown = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", shown, wrapped % 60, hour < 12 ? "AM" : "PM")
    }

    /// Today, counted like entry dates.
    static func dayNumber(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let start = calendar.date(from: parts) else { return 0 }
        return Int(start.timeIntervalSince1970 / 86_400)
    }

    private static func components(day: Int) -> (year: Int, month: Int, day: Int) {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(day) * 86_400))
        return (parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
