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
        let keys: [String]
    }

    private static let maxPageBins = 30
    private static let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    let units: [Unit]
    private let journalNames: [UUID: String]
    private let nameList: [String]
    public let pageCount: Int
    public let entryCount: Int
    public let datedEntryCount: Int
    public let wordTotal: Int
    public let words: [WordStat]

    public init(entries: [JournalEntry], includedPages: Set<UUID>, names: [String], journalNames: [UUID: String]) {
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

    /// Names Claude found, counted wherever they appear in the chosen pages.
    public func nameStats(hidden: Set<String>) -> [WordStat] {
        var seen = Set<String>()
        var stats: [WordStat] = []
        for name in nameList {
            let tokens = WordTokenizer.tokens(in: name)
            let key = tokens.map(\.key).joined(separator: " ")
            guard !key.isEmpty, seen.insert(key).inserted, !hidden.contains(key) else { continue }
            let perUnit = units.map { Self.occurrences(of: tokens.map(\.key), in: $0.keys) }
            let count = perUnit.reduce(0, +)
            guard count > 0 else { continue }
            let pages = Set(zip(units, perUnit).filter { $0.1 > 0 }.map(\.0.pageID)).count
            stats.append(WordStat(key: key, display: tokens.map(\.surface).joined(separator: " "),
                                  count: count, pageCount: pages))
        }
        return stats.sorted { ($1.count, $0.key) < ($0.count, $1.key) }
    }

    public func term(_ text: String) -> TermResult? {
        let tokens = WordTokenizer.tokens(in: text)
        guard !tokens.isEmpty else { return nil }
        let keys = tokens.map(\.key)
        let perUnit = units.map { Self.occurrences(of: keys, in: $0.keys) }
        let hits = zip(units, perUnit).filter { $0.1 > 0 }
        let undated = zip(units, perUnit).reduce(0) { total, pair in
            total + (Self.dayNumber(pair.0) == nil ? pair.1 : 0)
        }
        return TermResult(
            display: tokens.map(\.surface).joined(separator: " "),
            total: perUnit.reduce(0, +),
            pageCount: Set(hits.map(\.0.pageID)).count,
            entryCount: Set(hits.map(\.0.entryID)).count,
            undatedMentions: undated,
            byDate: dateBins(perUnit),
            byPage: pageBins(perUnit)
        )
    }

    static func occurrences(of phrase: [String], in keys: [String]) -> Int {
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

    private static func components(day: Int) -> (year: Int, month: Int, day: Int) {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(day) * 86_400))
        return (parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}
