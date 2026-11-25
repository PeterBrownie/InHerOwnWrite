import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import SwiftUI
import UniformTypeIdentifiers
import WriteApp
import WriteCore

// Runs without Xcode: `swift run WriteCheck`. Uses only synthetic pages and a stubbed network.

nonisolated(unsafe) var failures = 0

func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
    do {
        if try condition() {
            print("  ok    \(name)")
        } else {
            failures += 1
            print("  FAIL  \(name)")
        }
    } catch {
        failures += 1
        print("  FAIL  \(name): \(error)")
    }
}

func throwsError<E: Error & Equatable>(_ expected: E, _ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch let error as E {
        return error == expected
    } catch {
        return false
    }
}

func syntheticPhoto(width: Int = 1200, height: Int = 1600, gps: Bool = false, orientation: Int? = nil) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.97, green: 0.94, blue: 0.86, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setStrokeColor(CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1))
    context.setLineWidth(3)
    for line in stride(from: 80, to: height - 80, by: 60) {
        context.move(to: CGPoint(x: 80, y: line))
        context.addLine(to: CGPoint(x: width - 80, y: line))
    }
    context.strokePath()

    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [:]
    if gps {
        properties[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: 32.7790, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 96.8084, kCGImagePropertyGPSLongitudeRef: "W",
        ]
        properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFModel: "CanaryCamera"]
    }
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return output as Data
}

func fileContains(_ url: URL, _ needle: Data) -> Bool {
    guard let data = try? Data(contentsOf: url) else { return false }
    return data.range(of: needle) != nil
}

// MARK: - Stubbed Anthropic API

final class StubAPI: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [(Int, [String: String], String)] = []
    nonisolated(unsafe) static var requests: [(URLRequest, Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        Self.requests.append((request, body))
        let (status, headers, text) = Self.replies.isEmpty ? (500, [:], "{}") : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

func stubbedTranscriber() -> Transcriber {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubAPI.self]
    return Transcriber(apiKey: "sk-test-canary", session: URLSession(configuration: configuration), retryDelay: 0.01)
}

func reply(text: String, stop: String = "end_turn", entries: [[String: Any]] = [], names: [String] = []) -> String {
    let page: [String: Any] = ["transcription": text, "entries": entries, "names": names]
    let json = String(data: try! JSONSerialization.data(withJSONObject: page), encoding: .utf8)!
    return rawReply(json, stop: stop)
}

func rawReply(_ text: String, stop: String = "end_turn") -> String {
    let body: [String: Any] = [
        "stop_reason": stop,
        "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
}

/// Every object must forbid extra keys and require each of its properties.
func schemaIsStrict(_ node: Any) -> Bool {
    if let list = node as? [Any] { return list.allSatisfy(schemaIsStrict) }
    guard let object = node as? [String: Any] else { return true }
    if object["type"] as? String == "object" {
        let properties = Set((object["properties"] as? [String: Any] ?? [:]).keys)
        guard object["additionalProperties"] as? Bool == false,
              Set(object["required"] as? [String] ?? []) == properties
        else { return false }
    }
    for forbidden in ["minimum", "maximum", "minLength", "maxLength", "pattern"] where object[forbidden] != nil {
        return false
    }
    return object.values.allSatisfy(schemaIsStrict)
}

func transcribeError(_ transcriber: Transcriber, _ jpeg: Data) async -> TranscriberError? {
    do {
        _ = try await transcriber.transcribe(jpeg: jpeg)
        return nil
    } catch {
        return error as? TranscriberError
    }
}

// MARK: - Vault checks

func runVaultChecks(in directory: URL) throws {
    print("Vault")
    let password = "correct horse battery"
    check("rejects a short password", throwsError(VaultError.weakPassword) {
        _ = try Vault.create(in: directory, password: "short")
    })

    let created = try Vault.create(in: directory, password: password)
    let vault = created.vault
    check("refuses to overwrite an existing vault", throwsError(VaultError.alreadyExists) {
        _ = try Vault.create(in: directory, password: password)
    })

    let journalCanary = "CANARYJOURNALNAME"
    let textCanary = "CANARYPAGETEXTVALUE"
    let keyCanary = "sk-ant-CANARYAPIKEY"
    let photo = try PagePhoto.prepare(syntheticPhoto())
    let journal = try vault.createJournal(name: journalCanary)
    let second = try vault.createJournal(name: "Second")
    let page = try vault.addPage(journalID: journal.id, number: 61, jpeg: photo)
    let other = try vault.addPage(journalID: journal.id, number: 62, jpeg: photo)
    try vault.setText(pageID: page.id, text: textCanary, status: .done, wasCutOff: false)
    try vault.setText(pageID: other.id, text: "other page", status: .done, wasCutOff: false)
    try vault.setAPIKey(keyCanary)

    check("round-trips text", try vault.text(pageID: page.id) == textCanary)
    check("round-trips photo", try vault.image(pageID: page.id) == photo)
    check("round-trips API key", try vault.apiKey() == keyCanary)
    check("rejects a duplicate page number", throwsError(VaultError.duplicatePage) {
        try vault.addPage(journalID: journal.id, number: 61, jpeg: photo)
    })
    check("same number is allowed in another journal",
          (try? vault.addPage(journalID: second.id, number: 61, jpeg: photo)) != nil)
    check("rejects page number 0", throwsError(VaultError.invalidPageNumber) {
        try vault.addPage(journalID: journal.id, number: 0, jpeg: photo)
    })
    check("rejects moving onto a used page", throwsError(VaultError.duplicatePage) {
        try vault.movePage(id: other.id, toJournal: journal.id, number: 61)
    })
    try vault.movePage(id: other.id, toJournal: journal.id, number: 200)
    check("moves a page", try vault.pages().first { $0.id == other.id }?.number == 200)
    check("frees the old number after a move", try !vault.pageExists(journalID: journal.id, number: 62))

    let url = Vault.databaseURL(in: directory)
    let jpegSample = photo.subdata(in: 2000..<2064)
    for (label, needle) in [("journal name", Data(journalCanary.utf8)), ("page text", Data(textCanary.utf8)),
                            ("API key", Data(keyCanary.utf8)), ("photo bytes", jpegSample),
                            ("JPEG header", Data([0xFF, 0xD8, 0xFF]) + photo.subdata(in: 3..<16))] {
        check("no plaintext \(label) on disk", !fileContains(url, needle))
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    check("database is owner-only", (attributes[.posixPermissions] as? Int) == 0o600)
    check("folder is owner-only", (directoryAttributes[.posixPermissions] as? Int) == 0o700)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != url.lastPathComponent }
    check("no journal or WAL files left behind", leftovers.isEmpty)

    check("wrong password fails", throwsError(VaultError.wrongPassword) {
        _ = try Vault.unlock(in: directory, password: "not the password")
    })
    check("wrong recovery key fails", throwsError(VaultError.wrongRecoveryKey) {
        _ = try Vault.unlock(in: directory, recoveryKey: String(repeating: "A", count: 32))
    })
    let reopened = try Vault.unlock(in: directory, password: password)
    check("password reopens the vault", try reopened.text(pageID: page.id) == textCanary)
    let lowercase = created.recoveryKey.lowercased().replacingOccurrences(of: "-", with: " ")
    let recovered = try Vault.unlock(in: directory, recoveryKey: lowercase)
    check("recovery key reopens the vault", try recovered.apiKey() == keyCanary)

    try recovered.changePassword(to: "a brand new password")
    check("old password stops working", throwsError(VaultError.wrongPassword) {
        _ = try Vault.unlock(in: directory, password: password)
    })
    check("new password works", (try? Vault.unlock(in: directory, password: "a brand new password")) != nil)
    check("recovery key survives a password change",
          (try? Vault.unlock(in: directory, recoveryKey: created.recoveryKey)) != nil)

    reopened.lock()
    check("locked vault refuses reads", throwsError(VaultError.locked) { _ = try reopened.text(pageID: page.id) })

    // Swap two ciphertexts directly in SQLite. Authentication must catch it.
    var raw: OpaquePointer?
    sqlite3_open(url.path, &raw)
    let swap = """
        UPDATE pages SET body = (SELECT body FROM pages WHERE id = '\(other.id.uuidString.lowercased())')
        WHERE id = '\(page.id.uuidString.lowercased())'
        """
    sqlite3_exec(raw, swap, nil, nil, nil)
    sqlite3_close(raw)
    let afterSwap = try Vault.unlock(in: directory, password: "a brand new password")
    check("detects ciphertext swapped between pages", throwsError(VaultError.corrupted) {
        _ = try afterSwap.text(pageID: page.id)
    })

    try afterSwap.deleteJournal(id: second.id)
    check("deleting a journal removes its pages", try !afterSwap.pages().contains { $0.journalID == second.id })

    let structure = PageStructure(markers: [EntryMarker(headingLine: "Monday, May 4", month: 5, day: 4)],
                                  names: ["CANARYNAME"], text: "Monday, May 4\nhello")
    try afterSwap.saveReading(pageID: other.id, transcription: Transcription(
        text: "Monday, May 4\nhello", wasCutOff: false, structure: structure))
    check("saves entries and names with the page", try afterSwap.pages().first { $0.id == other.id }?.structure == structure)
    try afterSwap.setHiddenWords(["CANARYHIDDEN"])
    check("round-trips hidden words", try afterSwap.hiddenWords() == ["CANARYHIDDEN"])
    check("API key survives hiding words", try afterSwap.apiKey() == keyCanary)
    check("no plaintext names on disk", !fileContains(url, Data("CANARYNAME".utf8)))
    check("no plaintext hidden words on disk", !fileContains(url, Data("CANARYHIDDEN".utf8)))

    // Pages saved before this update have no structure field.
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as! [String: Any]
    legacy["structure"] = nil
    let decoded = try? JSONDecoder().decode(PageInfo.self, from: JSONSerialization.data(withJSONObject: legacy))
    check("older pages still open", decoded?.id == page.id && decoded?.structure == nil)
}

// MARK: - Entry and analysis checks

func runEntryChecks() {
    print("Entries")
    let full = DateHeadingParser.parse("Friday - January 16, 2026 - 8:59 pm")
    check("parses weekday, date, and time", full?.weekday == "Friday" && full?.year == 2026 && full?.month == 1
          && full?.day == 16 && full?.time == "20:59")
    let noYear = DateHeadingParser.parse("Thursday, March 5")
    check("parses a date with no year", noYear?.year == nil && noYear?.month == 3 && noYear?.day == 5)
    check("parses short numeric dates", DateHeadingParser.parse("1/16/26")?.year == 2026)
    check("parses ordinals", DateHeadingParser.parse("Jan 16th")?.day == 16)
    check("parses ISO dates", DateHeadingParser.parse("2026-01-16")?.month == 1)
    check("parses a 24-hour time", DateHeadingParser.parse("March 3, 2026 21:05")?.time == "21:05")
    check("ignores a bare fraction", DateHeadingParser.parse("3/4") == nil)
    check("ignores dates inside sentences", DateHeadingParser.parse("We went out on January 16, 2026") == nil)
    check("ignores a stray trailing number", DateHeadingParser.parse("January 16 10") == nil)
    check("rejects impossible dates", DateHeadingParser.parse("February 30, 2026") == nil)

    let journal = UUID()
    func page(_ number: Int) -> PageInfo {
        PageInfo(id: UUID(), journalID: journal, number: number, status: .done, problem: nil, wasCutOff: false,
                 createdAt: Date(), updatedAt: Date())
    }
    let pages = [page(1), page(2), page(4)]
    let texts = [
        pages[0].id: "tail of an older entry\n\nMonday, Jan 5, 2026\nbody a\n\nJan 6\nbody b starts",
        pages[1].id: "and body b continues\nJan 7\nbody c",
        pages[2].id: "orphan text after a missing page",
    ]
    let entries = EntryBuilder.build(pages: pages, journalOrder: [journal]) { texts[$0] ?? "" }
    check("splits pages into entries", entries.count == 5)
    check("starts with the unfinished entry", entries.first?.heading == nil && entries.first?.parts.count == 1)
    check("an entry can span pages", entries[safe: 2]?.parts.count == 2 && entries[safe: 2]?.pageLabel == "pp. 1–2")
    check("infers a missing year", entries[safe: 2]?.year == 2026 && entries[safe: 2]?.yearWasInferred == true)
    check("a gap in pages starts a new undated entry", entries.last?.title == "Continued from an earlier page")
    check("keeps the heading out of the body", entries[safe: 1]?.parts.first?.body == "body a")

    let rollover = [page(1)]
    let rolloverText = [rollover[0].id: "December 30, 2025\nlate\nJanuary 2\nearly"]
    let rolled = EntryBuilder.build(pages: rollover, journalOrder: [journal]) { rolloverText[$0] ?? "" }
    check("rolls into the next year", rolled.last?.year == 2026)

    let text = "intro\nOur Spot Day\nbody"
    let marked = PageStructure(markers: [EntryMarker(headingLine: "Our Spot Day", month: 6, day: 1)], names: [], text: text)
    check("uses Claude's headings", EntryBuilder.headings(in: text, structure: marked).map(\.line) == [1])
    let edited = "intro\nJune 2, 2026\nbody"
    check("finds a date she typed in after editing",
          EntryBuilder.headings(in: edited, structure: marked).first?.marker.day == 2)
    let unchanged = "a line\nMarch 3, 2026\nmore"
    let noHeadings = PageStructure(markers: [], names: [], text: unchanged)
    check("trusts Claude when the text is unedited", EntryBuilder.headings(in: unchanged, structure: noHeadings).isEmpty)

    check("reflows line wraps", LineFlow.reflow("one\ntwo well-\nknown\n\nthree") == "one two well-known\n\nthree")
    check("keeps headings on their own line",
          LineFlow.reflow("June 1\nbody\ntext", headingLines: [0]) == "June 1\n\nbody text")

    print("Analysis")
    check("parses page lists", PageSelection.parse("1-3, 7, 10-")?.contains(12) == true
          && PageSelection.parse("1-3, 7")?.contains(5) == false)
    check("blank page list means all pages", PageSelection.parse("")?.contains(99) == true)
    check("rejects a malformed page list", PageSelection.parse("5-2") == nil && PageSelection.parse("abc") == nil)
    let tokens = WordTokenizer.tokens(in: "Theo's café, it's 6th ### [illegible] José!").map(\.key)
    check("tokenizes words", tokens == ["theo", "cafe", "it's", "jose"])

    let snapshot = AnalysisSnapshot(entries: entries, includedPages: Set(pages.map(\.id)),
                                    names: ["Body", "Nobody Here"], journalNames: [journal: "Test"])
    check("counts words", snapshot.words.first { $0.key == "body" }?.count == 4)
    check("leaves headings out of word counts", !snapshot.words.contains { $0.key == "jan" })
    check("hides words", !snapshot.visibleWords(hidden: ["body"], includeCommon: true).contains { $0.key == "body" })
    check("hides common words by default", !snapshot.visibleWords(hidden: [], includeCommon: false).contains { $0.key == "and" })
    let term = snapshot.term("Body B")
    check("counts phrases", term?.total == 2 && term?.entryCount == 1)
    check("charts by page", term?.byPage.map(\.count).reduce(0, +) == 2)
    check("charts by date", term?.byDate.map(\.count).reduce(0, +) == 2 && (term?.byDate.count ?? 0) >= 1)
    let found = snapshot.matches("Body B")
    check("lists where a phrase appears", found.map(\.pageNumber) == [1, 2]
          && found.allSatisfy { $0.count == 1 && $0.journalName == nil })
    check("highlights the phrase in its snippet", found.first.map { match in
        match.highlight.map { range in
            let characters = Array(match.snippet)
            return String(characters[range]).lowercased() == "body b"
        } ?? false
    } == true)
    let (cut, cutRange) = AnalysisSnapshot.snippet(of: ["needle"], in: String(repeating: "hay ", count: 60) + "needle"
                                                   + String(repeating: " straw", count: 60))
    check("cuts long snippets around the word", cut.hasPrefix("…") && cut.hasSuffix("…") && cut.count < 200
          && cutRange.map { String(Array(cut)[$0]) } == "needle")
    check("searches for a phrase across a line break", TextSearch.contains("we went\nhome early", "Went  home")
          && TextSearch.contains("Theo’s cafe", "theo's café") && !TextSearch.contains("went out", "went home")
          && !TextSearch.contains("anything", "  "))
    check("looks up a phrase across lines and punctuation", snapshot.matches("body, b").count == 2)
    check("compares several words", snapshot.terms("body, Body B, ").map(\.total) == [4, 2])
    check("names only count when present", snapshot.nameStats(hidden: []).map(\.key) == ["body"])
    let onlyPage4 = AnalysisSnapshot(entries: entries, includedPages: [pages[2].id], names: [], journalNames: [:])
    check("limits analysis to chosen pages", onlyPage4.pageCount == 1 && onlyPage4.term("body")?.total == 0)

    let rhythm = snapshot.entryRhythm()
    check("counts entries, dated or not", rhythm.entryCount == 5 && rhythm.datedCount == 3)
    check("an entry over two pages counts once", rhythm.byMonth.map(\.count) == [3])
    check("reads a time alone", TimeHeadingParser.parse("9:30 pm")?.time == "21:30"
          && TimeHeadingParser.parse("at 7am")?.time == "07:00" && TimeHeadingParser.parse("42") == nil
          && TimeHeadingParser.parse("13:75") == nil)
    let timed = [page(1)]
    let timedText = "March 5, 2026\nmorning words\n\n9:30 pm\nnight words\nsaid 10:15 pm\nstill night"
    let timedEntries = EntryBuilder.build(pages: timed, journalOrder: [journal]) { _ in timedText }
    let nightText = "March 5, 2026 11:00 pm\nlate\n\nMarch 6, 2026 1:00 am\nlater\n\nMarch 7, 2026\nno time"
    let night = AnalysisSnapshot(entries: EntryBuilder.build(pages: timed, journalOrder: [journal]) { _ in nightText },
                                 includedPages: [timed[0].id], names: [], journalNames: [:]).entryRhythm()
    check("averages times around midnight", night.averageTime == "12:00 AM" && night.timedCount == 2
          && night.byTimeOfDay.map(\.count) == [1, 0, 0, 0, 0, 0, 0, 1])
    check("a time alone starts an entry on the same day", timedEntries.count == 2
          && timedEntries[1].day == 5 && timedEntries[1].month == 3 && timedEntries[1].time == "21:30"
          && timedEntries[1].bodyText.contains("still night"))
    let line = EntryBuilder.headingLine(year: 2026, month: 3, day: 5, hour: 21, minute: 30)
    check("writes a date line it can read back", line == "Thursday, March 5, 2026 9:30 pm"
          && DateHeadingParser.parse(line)?.time == "21:30" && DateHeadingParser.parse(line)?.weekday == "Thursday")
    let rewritten = EntryBuilder.settingHeading(line, of: timedEntries[0].parts[0], in: timedText)
    check("rewrites an entry's date line", rewritten.hasPrefix(line + "\nmorning words"))
    let continued = EntryBuilder.build(pages: timed, journalOrder: [journal]) { _ in "\nfirst words" }[0].parts[0]
    check("adds a date line where there was none",
          EntryBuilder.settingHeading(line, of: continued, in: "\nfirst words") == "\n" + line + "\nfirst words")
    let spaced = [page(1), page(2)]
    let spacedText = [
        spaced[0].id: "Monday, January 5, 2026\nfirst\n\nJanuary 6, 2026\nsecond\n\nJanuary 20, 2026\nthird",
        spaced[1].id: "March 2, 2026\nfourth\n\nMarch 3, 2026\nfifth",
    ]
    let spacedEntries = EntryBuilder.build(pages: spaced, journalOrder: [journal]) { spacedText[$0] ?? "" }
    let months = AnalysisSnapshot(entries: spacedEntries, includedPages: Set(spaced.map(\.id)), names: [], journalNames: [:])
        .entryRhythm()
    // January 5 and March 2, 2026 are Mondays; January 6 and March 3 are Tuesdays; January 20 a Tuesday.
    check("counts entries by weekday", months.byWeekday.map(\.count) == [2, 3, 0, 0, 0, 0, 0])
    check("finds the longest streak", months.longestStreak?.days == 2 && months.longestStreak?.from == "Jan 5, 2026")
    check("an old streak isn't current", months.currentStreak == 0)
    check("counts entries per month, empty months included", months.byMonth.map(\.count) == [3, 0, 2])
    check("counts entries per week from Monday", months.byWeek.count == 9 && months.byWeek.map(\.count) == [2, 0, 1, 0, 0, 0, 0, 0, 2]
          && months.byWeek.first?.label == "Week of Jan 5, 2026")
    check("averages over the whole span", abs((months.perMonth ?? 0) - 5.0 / 3) < 1e-9 && abs((months.perWeek ?? 0) - 5.0 / 9) < 1e-9)
    check("finds the longest gap", months.longestGap == EntryRhythm.Gap(days: 41, from: "Jan 20, 2026", to: "Mar 2, 2026"))
    let undated = AnalysisSnapshot(entries: entries, includedPages: [pages[2].id], names: [], journalNames: [:]).entryRhythm()
    check("undated entries have no averages", undated.entryCount == 1 && undated.perMonth == nil && undated.longestGap == nil)
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Photo checks

func runPhotoChecks() throws {
    print("Photos")
    let source = syntheticPhoto(width: 4000, height: 3000, gps: true, orientation: 6)
    check("test photo really has GPS", fileHasGPS(source))
    let prepared = try PagePhoto.prepare(source)
    check("strips GPS", !fileHasGPS(prepared))
    check("strips camera model", prepared.range(of: Data("CanaryCamera".utf8)) == nil)
    let imageSource = CGImageSourceCreateWithData(prepared as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as! [CFString: Any]
    let width = properties[kCGImagePropertyPixelWidth] as! Int
    let height = properties[kCGImagePropertyPixelHeight] as! Int
    check("applies camera rotation", height > width)
    check("limits the long edge", max(width, height) <= 2400)
    check("fits the API image limit", prepared.base64EncodedString().utf8.count < 5_000_000)
    check("rejects a non-image", (try? PagePhoto.prepare(Data("not an image".utf8))) == nil)
}

func fileHasGPS(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return false }
    return properties[kCGImagePropertyGPSDictionary] != nil
}

// MARK: - API checks

func runAPIChecks() async throws {
    print("Anthropic request handling (stubbed network)")
    let transcriber = stubbedTranscriber()
    let jpeg = try PagePhoto.prepare(syntheticPhoto())

    StubAPI.replies = [(200, [:], reply(text: "Dear diary\n### line two\n"))]
    let result = try await transcriber.transcribe(jpeg: jpeg)
    check("returns only the text blocks", result.text == "Dear diary\n### line two")
    check("not marked as cut off", !result.wasCutOff)

    let (request, body) = StubAPI.requests.last!
    let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let content = ((json["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
    let source = content[0]["source"] as! [String: String]
    check("calls the Messages endpoint", request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    check("sends the API key header", request.value(forHTTPHeaderField: "x-api-key") == "sk-test-canary")
    check("sends the API version", request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
    check("uses Claude Opus 5.5", json["model"] as? String == "claude-opus-5-5")
    check("sets no unsupported thinking config", json["thinking"] == nil && json["temperature"] == nil)
    check("sends the exact photo", Data(base64Encoded: source["data"]!) == jpeg)
    let format = (json["output_config"] as? [String: Any])?["format"] as? [String: Any]
    check("asks for structured output", format?["type"] as? String == "json_schema")
    check("schema follows structured output rules", format.map { schemaIsStrict($0["schema"]!) } ?? false)

    StubAPI.replies = [(200, [:], reply(
        text: "end of an old entry\nFriday - January 16, 2026 - 8:59 pm\nTheo and Theo's dog",
        entries: [
            ["heading_line": "Friday - January 16, 2026 - 8:59 pm", "weekday": "Friday", "year": 2026,
             "month": 1, "day": 16, "time": "20:59"],
            ["heading_line": "Bad date", "weekday": NSNull(), "year": 2026, "month": 2, "day": 31, "time": "99:00"],
        ],
        names: ["Theo", " theo ", "Marguerite"]
    ))]
    let structured = try await transcriber.transcribe(jpeg: jpeg)
    let firstMarker = structured.structure.markers.first
    check("reads entry headings", firstMarker?.month == 1 && firstMarker?.day == 16 && firstMarker?.time == "20:59")
    check("drops impossible dates and times", structured.structure.markers.last?.day == nil
          && structured.structure.markers.last?.time == nil)
    check("dedupes names", structured.structure.names == ["Theo", "Marguerite"])

    StubAPI.replies = [(200, [:], reply(text: "partial", stop: "max_tokens"))]
    let cutOff = try await transcriber.transcribe(jpeg: jpeg)
    check("flags a cut-off reading", cutOff.wasCutOff)

    StubAPI.replies = [(200, [:], rawReply(#"{"transcription": "unfinish"#, stop: "max_tokens"))]
    let truncated = await transcribeError(transcriber, jpeg)
    check("reports truncated JSON as too long", truncated == .tooLong)

    StubAPI.replies = [(200, [:], rawReply("not json"))]
    let malformed = await transcribeError(transcriber, jpeg)
    check("reports an unreadable reply", malformed == .malformedReply)

    StubAPI.replies = [(200, [:], reply(text: "", stop: "refusal"))]
    let refusal = await transcribeError(transcriber, jpeg)
    check("reports a refusal", refusal == .declined)

    StubAPI.replies = [(401, [:], "{}")]
    let badKey = await transcribeError(transcriber, jpeg)
    check("reports a bad key", badKey == .invalidKey)

    StubAPI.replies = [(400, [:], #"{"error":{"message":"Your credit balance is too low"}}"#)]
    let noCredit = await transcribeError(transcriber, jpeg)
    check("reports no credit", noCredit == .noCredit)

    StubAPI.requests = []
    StubAPI.replies = [(429, ["retry-after": "0"], "{}"), (529, [:], "{}"), (200, [:], reply(text: "recovered"))]
    let recovered = try await transcriber.transcribe(jpeg: jpeg)
    check("retries overloads and rate limits", recovered.text == "recovered")
    check("retried the expected number of times", StubAPI.requests.count == 3)

    StubAPI.requests = []
    StubAPI.replies = [(500, ["x-should-retry": "false"], "{}")]
    let noRetry = await transcribeError(transcriber, jpeg)
    check("honors x-should-retry", noRetry == .serviceUnavailable)
    check("did not retry", StubAPI.requests.count == 1)
}

// MARK: - Rendering

@MainActor
func render<V: View>(_ view: V, size: CGSize, to url: URL, dark: Bool = false, wait: Double = 1.2) async {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
    // Behind every other app's windows, so rendering doesn't cover what the person is doing.
    window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    window.orderBack(nil)
    // Suspending lets SwiftUI's main-actor work, such as loading the page photo, finish.
    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    hosting.layoutSubtreeIfNeeded()
    if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
    window.orderOut(nil)
    window.close()
}

@MainActor
func runRender(output: URL, sample: URL?) async throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = AppModel(directory: directory)
    var updater = Updater.preview(.idle)
    await render(RootView().environmentObject(model).environmentObject(updater), size: CGSize(width: 1100, height: 720),
                 to: output.appendingPathComponent("1-create.png"))

    await model.createVault(password: "synthetic password")
    await render(RootView().environmentObject(model).environmentObject(updater), size: CGSize(width: 1100, height: 720),
                 to: output.appendingPathComponent("2-recovery-dark.png"), dark: true)
    model.lock()
    check("sleep can't dismiss the recovery key", { if case .showRecoveryKey = model.screen { return true }; return false }())
    model.confirmRecoveryKeySaved()
    model.showSettings = false
    await render(UploadSheet().environmentObject(model), size: CGSize(width: 820, height: 600),
                 to: output.appendingPathComponent("4a-upload-first-journal.png"))
    await render(UpdateBanner(updater: .preview(.preparing)).frame(width: 1000), size: CGSize(width: 1000, height: 70),
                 to: output.appendingPathComponent("12-update-preparing.png"))
    await render(UpdateBanner(updater: .preview(.ready)).frame(width: 1000), size: CGSize(width: 1000, height: 70),
                 to: output.appendingPathComponent("12-update-ready-dark.png"), dark: true)
    await render(UpdateBanner(updater: .preview(.failed("The new version didn't build."))).frame(width: 1000),
                 size: CGSize(width: 1000, height: 70), to: output.appendingPathComponent("12-update-failed.png"))
    let spread = twoPageSpread()
    let spreadScan = await PageScan.analyze(jpeg: spread)
    await render(CropEditor(image: NSImage(data: spread)!, crop: .constant(spreadScan.crop)).padding(10),
                 size: CGSize(width: 520, height: 460), to: output.appendingPathComponent("4c-crop.png"))
    await render(CropEditor(image: NSImage(data: spread)!, crop: .constant(spreadScan.crop), angle: 6).padding(10),
                 size: CGSize(width: 520, height: 460), to: output.appendingPathComponent("4c-crop-turned.png"))
    _ = model.createJournal(name: "Spread Test")
    await render(UploadSheet(preloaded: spread).environmentObject(model), size: CGSize(width: 820, height: 600),
                 to: output.appendingPathComponent("4d-upload-with-photo.png"))
    // Both pages, photographed sideways: the sheet turns the photo upright and splits it at the fold.
    UserDefaults.standard.set(true, forKey: "bothPages")
    let sideways = try PagePhoto.rotated(openJournal(), degrees: 90)
    await render(CropEditor(image: NSImage(data: openJournal())!, crop: .constant(CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)),
                            angle: 3, split: .constant(0.52)).padding(10),
                 size: CGSize(width: 520, height: 460), to: output.appendingPathComponent("4e-crop-both-pages.png"))
    await render(UploadSheet(preloaded: sideways).environmentObject(model), size: CGSize(width: 820, height: 600),
                 to: output.appendingPathComponent("4f-upload-both-pages.png"), wait: 4)
    if let sample {
        await render(UploadSheet(preloaded: try PagePhoto.prepare(try Data(contentsOf: sample))).environmentObject(model),
                     size: CGSize(width: 820, height: 600), to: output.appendingPathComponent("4g-upload-sample-both-pages.png"), wait: 4)
    }
    UserDefaults.standard.removeObject(forKey: "bothPages")
    if let made = model.journals.first(where: { $0.name == "Spread Test" }) { model.deleteJournal(id: made.id) }

    let photo = try sample.map { try PagePhoto.prepare(try Data(contentsOf: $0)) }
        ?? PagePhoto.prepare(handwrittenPage())
    let journal = model.createJournal(name: "Green Notebook")!
    _ = model.createJournal(name: "Travel Journal")
    model.selectedJournalID = journal.id
    for number in 1...3 {
        model.addPage(journalID: journal.id, number: number, jpeg: photo, replacing: false)
    }
    // Invented text, so entries and analysis have something to show.
    let samples = [
        "and the rain finally stopped by noon.\n\nTuesday - March 3, 2026 - 7:42 pm\nThe bakery on Elm Street finally\nreopened today. Marguerite said,\n\"You can't keep a good loaf down.\"\nWe bought two rye loaves and a\n### lemon tart for the walk home.",
        "Theo was there too, and he\ncarried the bread the whole way.\n\nThursday, March 5\nTheo called about the cabin trip.\nMarguerite wants to drive up early.",
        "Saturday, April 11, 2026\nFinally at the cabin with Theo.\nThe lake was still half frozen.",
    ]
    for (page, text) in zip(model.pages, samples) { model.editText(text, pageID: page.id) }
    model.flushEdits()
    model.selectedPageID = model.pages.first?.id
    let size = CGSize(width: 1240, height: 800)
    await render(RootView().environmentObject(model).environmentObject(updater), size: size, to: output.appendingPathComponent("3-library.png"))
    await render(RootView().environmentObject(model).environmentObject(updater), size: size,
                 to: output.appendingPathComponent("3-library-dark.png"), dark: true)
    updater = .preview(.preparing)
    await render(RootView().environmentObject(model).environmentObject(updater), size: size,
                 to: output.appendingPathComponent("12-update-in-library-dark.png"), dark: true)
    updater = .preview(.idle)
    model.twoPageSpread = true
    await render(RootView().environmentObject(model).environmentObject(updater), size: CGSize(width: 1440, height: 860),
                 to: output.appendingPathComponent("3b-two-pages.png"))
    model.showPhoto = false
    model.accurateLineBreaks = false
    await render(RootView().environmentObject(model).environmentObject(updater), size: size,
                 to: output.appendingPathComponent("3c-two-pages-no-photo-reflowed.png"))
    model.twoPageSpread = false
    model.showPhoto = true
    model.accurateLineBreaks = true
    model.setLibraryMode(.entries)
    model.selectedEntryID = model.entries.first { $0.parts.count > 1 }?.id
    await render(RootView().environmentObject(model).environmentObject(updater), size: size, to: output.appendingPathComponent("3d-entries.png"))
    model.showingAnalysis = true
    await render(RootView().environmentObject(model).environmentObject(updater), size: size, to: output.appendingPathComponent("8-analysis.png"))
    model.analysisTerm = "Theo"
    await render(AnalysisDetail().environmentObject(model), size: CGSize(width: 900, height: 1100),
                 to: output.appendingPathComponent("9-analysis-term.png"))
    model.analysisTerm = "Theo, park"
    model.accent = .blue
    await render(AnalysisDetail().environmentObject(model), size: CGSize(width: 900, height: 1100),
                 to: output.appendingPathComponent("9-analysis-terms-dark.png"), dark: true)
    model.accent = .clay
    model.analysisTerm = ""
    model.showingAnalysis = false
    model.setLibraryMode(.pages)
    await render(UploadSheet().environmentObject(model), size: CGSize(width: 760, height: 560),
                 to: output.appendingPathComponent("4-upload.png"))
    await render(UploadSheet().environmentObject(model), size: CGSize(width: 760, height: 560),
                 to: output.appendingPathComponent("5-upload-dark.png"), dark: true)
    await render(SettingsSheet().environmentObject(model), size: CGSize(width: 480, height: 520),
                 to: output.appendingPathComponent("7-settings-dark.png"), dark: true)
    model.readsLocally = true
    await render(UploadSheet().environmentObject(model), size: CGSize(width: 760, height: 560),
                 to: output.appendingPathComponent("4b-upload-local.png"))
    model.readsLocally = false
    await render(LocalReaderWindow().environmentObject(model), size: CGSize(width: 1100, height: 700),
                 to: output.appendingPathComponent("10-local-setup.png"))
    let session = try await sampleLocalSession(photo: photo)
    await render(LocalSessionView(session: session).environmentObject(model), size: CGSize(width: 1320, height: 840),
                 to: output.appendingPathComponent("11-local-live.png"))
    await render(LocalSessionView(session: session).environmentObject(model), size: CGSize(width: 1320, height: 840),
                 to: output.appendingPathComponent("11-local-live-dark.png"), dark: true)
    // A word removed and another clicked, shown on the page.
    session.edit(line: 2, word: 3, to: "")
    session.selected = .init(line: 2, word: 2)
    await render(LocalSessionView(session: session).environmentObject(model), size: CGSize(width: 1320, height: 840),
                 to: output.appendingPathComponent("11b-local-removed-selected.png"))

    // A page read on this Mac, with a changed word and a close call colored on the photo, and one outlined.
    if let first = model.pages.first {
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(photo as CFData, nil)!, 0, nil)!
        let (layout, _) = try await PageLayoutFinder.read(image)
        let text = layout.lines.map { $0.words.map(\.text).joined(separator: " ") }.joined(separator: "\n")
        var notes: [WordNote] = []
        for (lineIndex, wordIndex, changed) in [(1, 1, true), (3, 2, false), (4, 0, false)]
        where layout.lines.indices.contains(lineIndex) && layout.lines[lineIndex].words.indices.contains(wordIndex) {
            let word = layout.lines[lineIndex].words[wordIndex]
            notes.append(WordNote(line: lineIndex, word: wordIndex, text: word.text, read: changed ? word.text + "x" : word.text,
                                  options: ["other"], confidence: changed ? 0.7 : 0.45,
                                  outline: layout.photoOutline(of: word.box)))
        }
        try model.saveLocalReading(LocalReadResult(text: text, notes: notes), pageID: first.id)
        model.selectedPageID = first.id
        model.showConfidence = true
        model.focusWord(notes.last, pageID: first.id)
        await render(RootView().environmentObject(model).environmentObject(updater), size: CGSize(width: 1240, height: 800),
                     to: output.appendingPathComponent("3e-confidence-on-photo.png"))
    }
    model.lock()
    await render(RootView().environmentObject(model).environmentObject(updater), size: CGSize(width: 1100, height: 720),
                 to: output.appendingPathComponent("6-locked-dark.png"), dark: true)
    print("Rendered to \(output.path)")
}

// MARK: - Live API check

/// An invented page, drawn in a handwriting font. It contains no real journal content.
let handwrittenLines = [
    "and the rain finally stopped by noon.",
    "",
    "Tuesday - March 3, 2026 - 7:42 pm",
    "The bakery on Elm Street finally",
    "reopened today. Marguerite said,",
    "\"You can't keep a good loaf down.\"",
    "We bought two rye loaves and a",
    "plum lemon tart for the walk home.",
    "",
    "Thursday, March 5",
    "Theo called about the cabin trip.",
]

func handwrittenPage() -> Data {
    let width = 1500, height = 2000
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.97, green: 0.95, blue: 0.88, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setStrokeColor(CGColor(red: 0.72, green: 0.76, blue: 0.82, alpha: 1))
    context.setLineWidth(2)
    for y in stride(from: 120, to: height - 120, by: 130) {
        context.move(to: CGPoint(x: 70, y: y))
        context.addLine(to: CGPoint(x: width - 70, y: y))
    }
    context.strokePath()

    let font = NSFont(name: "Bradley Hand", size: 74) ?? NSFont(name: "Noteworthy", size: 70) ?? .systemFont(ofSize: 66)
    let ink = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.16, alpha: 1)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for (index, line) in handwrittenLines.enumerated() {
        let baseline = CGFloat(height - 260 - index * 130) + 12
        guard !line.isEmpty else { continue }
        NSAttributedString(string: line, attributes: attributes).draw(at: CGPoint(x: 100, y: baseline))
        if line.hasPrefix("plum ") {
            let wordWidth = NSAttributedString(string: "plum", attributes: attributes).size().width
            context.setStrokeColor(ink.cgColor)
            context.setLineWidth(7)
            for offset in stride(from: 12, through: 52, by: 8) {
                context.move(to: CGPoint(x: 92, y: Int(baseline) + offset))
                context.addLine(to: CGPoint(x: 108 + wordWidth, y: baseline + CGFloat(offset) + 7))
            }
            context.strokePath()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

func runLiveCheck() async -> Bool {
    let key = (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
        print("Set ANTHROPIC_API_KEY to run the live check.")
        return false
    }
    do {
        let transcriber = Transcriber(apiKey: key)
        try await transcriber.verifyKey()
        print("  ok    Anthropic accepted the key")
        let jpeg = try PagePhoto.prepare(handwrittenPage())
        let started = Date()
        let result = try await transcriber.transcribe(jpeg: jpeg)
        print("  ok    read the invented page in \(Int(Date().timeIntervalSince(started))) seconds")
        let expected = expectedLines
        let actual = normalizedLines(result.text)
        let matches = zip(expected, actual).filter { $0 == $1 }.count
        print("  \(actual == expected ? "ok  " : "DIFF")  \(matches) of \(expected.count) lines matched exactly")
        print("\n--- transcription of the invented page ---\n\(result.text)\n---")
        let markers = result.structure.markers
        print("  entries: \(markers.map { "\($0.headingLine) → \($0.weekday ?? "-") \($0.year.map(String.init) ?? "-")-\($0.month ?? 0)-\($0.day ?? 0) \($0.time ?? "-")" })")
        print("  names: \(result.structure.names)")
        let before = failures
        check("found both entry headings", markers.count == 2)
        check("read the first date and time", markers.first.map {
            $0.weekday == "Tuesday" && $0.year == 2026 && $0.month == 3 && $0.day == 3 && $0.time == "19:42"
        } ?? false)
        check("left the unwritten year empty", markers.last.map { $0.year == nil && $0.month == 3 && $0.day == 5 } ?? false)
        check("found the names", Set(result.structure.names) == ["Marguerite", "Theo"])
        guard actual == expected, !result.wasCutOff, failures == before else { return false }
        return await runLiveAppCheck(key: key)
    } catch {
        print("  FAIL  \(error.localizedDescription)")
        return false
    }
}

var expectedLines: [String] {
    handwrittenLines
        .map { $0.hasPrefix("plum ") ? "### lemon tart for the walk home." : $0 }
        .filter { !$0.isEmpty }
}

func normalizedLines(_ text: String) -> [String] {
    text.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        .replacingOccurrences(of: "’", with: "'")
        .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Runs the app's real path: save encrypted, queue, read through the API, store, lock, reopen.
@MainActor
func runLiveAppCheck(key: String) async -> Bool {
    print("App upload path (live)")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("in-her-own-write-live-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let password = "synthetic password"
    let before = failures

    let model = AppModel(directory: directory)
    await model.createVault(password: password)
    model.confirmRecoveryKeySaved()
    model.showSettings = false
    let keySaved = await model.saveAPIKey(key)
    check("app verifies and saves the key", keySaved)

    guard keySaved, let journal = model.createJournal(name: "Live Test Journal"),
          let jpeg = try? PagePhoto.prepare(handwrittenPage()),
          model.addPage(journalID: journal.id, number: 12, jpeg: jpeg, replacing: false),
          let pageID = model.pages.first?.id
    else {
        print("  FAIL  could not add the page: \(model.errorMessage ?? "unknown")")
        return false
    }

    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline, let page = model.pages.first(where: { $0.id == pageID }),
          page.status == .reading || page.status == .waiting {
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
    let page = model.pages.first { $0.id == pageID }
    check("page finishes reading", page?.status == .done)
    if let problem = page?.problem { print("        \(problem)") }
    check("page keeps its journal and number", page?.journalID == journal.id && page?.number == 12)
    check("app shows the correct text", normalizedLines(model.texts[pageID] ?? "") == expectedLines)
    let entries = model.entries
    check("app splits the page into three entries", entries.count == 3)
    check("app fills in the unwritten year", entries.last?.year == 2026 && entries.last?.yearWasInferred == true)
    let snapshot = await model.makeAnalysisSnapshot()
    check("analysis finds both names", Set(snapshot.nameStats(hidden: []).map(\.display)) == ["Marguerite", "Theo"])

    model.lock()
    check("lock clears decrypted text from the app", model.texts.isEmpty && model.pages.isEmpty)
    let url = Vault.databaseURL(in: directory)
    check("transcription is not readable on disk", !fileContains(url, Data("lemon tart".utf8)))
    check("API key is not readable on disk", !fileContains(url, Data(key.utf8)))
    do {
        let reopened = try Vault.unlock(in: directory, password: password)
        check("text survives lock and reopen", normalizedLines(try reopened.text(pageID: pageID)) == expectedLines)
        check("photo survives lock and reopen", try reopened.image(pageID: pageID) == jpeg)
        check("key survives lock and reopen", try reopened.apiKey() == key)
    } catch {
        check("vault reopens", false)
    }
    return failures == before
}

// MARK: - Entry point

let arguments = CommandLine.arguments
if arguments.contains("--local") {
    Task {
        let passed = await runLocalModelCheck()
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
} else if arguments.contains("--live") {
    Task {
        let passed = await runLiveCheck()
        exit(passed ? 0 : 1)
    }
    RunLoop.main.run()
} else if let index = arguments.firstIndex(of: "--render"), arguments.count > index + 1 {
    let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    let sample = arguments.count > index + 2 ? URL(fileURLWithPath: arguments[index + 2]) : nil
    Task { @MainActor in
        do {
            try await runRender(output: output, sample: sample)
            exit(0)
        } catch {
            print("Render failed: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else {
    Task {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("in-her-own-write-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try runVaultChecks(in: directory)
            runEntryChecks()
            try runPhotoChecks()
            try await runAPIChecks()
            try await runLocalReadingChecks()
            runSwitchRuleChecks()
            try runEditingChecks(in: directory)
            try await runScribbleChecks()
            await MainActor.run { runBannerChecks() }
            try await runRotationChecks()
            try runTiltedCropChecks()
            try await runWordPlacementChecks()
            try await runPageScanChecks()
            try await runSpreadChecks()
            try runPhotoOrderChecks()
            try await runFlattenChecks()
            runUpdaterChecks()
            runReleaseUpdateChecks()
            await runMissingRuntimeChecks()
        } catch {
            failures += 1
            print("  FAIL  stopped early: \(error)")
        }
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}
