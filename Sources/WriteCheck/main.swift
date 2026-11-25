import AppKit
import CoreGraphics
import CryptoKit
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

/// How long each group of checks took, in the order they ran.
nonisolated(unsafe) var timings: [(name: String, seconds: Double)] = []

func timed(_ name: String, _ body: () async throws -> Void) async rethrows {
    let start = Date()
    defer { timings.append((name, Date().timeIntervalSince(start))) }
    try await body()
}

/// The slowest groups first, so it's clear where the time goes.
func printTimings() {
    guard !timings.isEmpty else { return }
    let total = timings.reduce(0) { $0 + $1.seconds }
    print("\nTime taken (\(String(format: "%.1f", total)) s in all):")
    for item in timings.sorted(by: { $0.seconds > $1.seconds }) {
        print(String(format: "  %6.1f s  %4.0f%%  ", item.seconds, item.seconds / total * 100) + item.name)
    }
}

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
        _ = try await transcriber.transcribe(photo: jpeg)
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
    let page = try vault.addPage(journalID: journal.id, number: 61, photo: photo)
    let other = try vault.addPage(journalID: journal.id, number: 62, photo: photo)
    try vault.setText(pageID: page.id, text: textCanary, status: .done, wasCutOff: false)
    try vault.setText(pageID: other.id, text: "other page", status: .done, wasCutOff: false)
    try vault.setAPIKey(keyCanary)

    check("round-trips text", try vault.text(pageID: page.id) == textCanary)
    let stored = try vault.image(pageID: page.id)
    check("keeps the photo as HEIC, same size in pixels",
          PagePhoto.isHEIC(stored) && pixelSize(stored) == pixelSize(photo))
    check("round-trips API key", try vault.apiKey() == keyCanary)
    check("rejects a duplicate page number", throwsError(VaultError.duplicatePage) {
        try vault.addPage(journalID: journal.id, number: 61, photo: photo)
    })
    check("same number is allowed in another journal",
          (try? vault.addPage(journalID: second.id, number: 61, photo: photo)) != nil)
    check("rejects page number 0", throwsError(VaultError.invalidPageNumber) {
        try vault.addPage(journalID: journal.id, number: 0, photo: photo)
    })
    check("rejects moving onto a used page", throwsError(VaultError.duplicatePage) {
        try vault.movePage(id: other.id, toJournal: journal.id, number: 61)
    })
    try vault.movePage(id: other.id, toJournal: journal.id, number: 200)
    check("moves a page", try vault.pages().first { $0.id == other.id }?.number == 200)
    check("frees the old number after a move", try !vault.pageExists(journalID: journal.id, number: 62))
    let storagePages = try vault.pages()
    let sizes = try vault.storage(journalOf: Dictionary(uniqueKeysWithValues: storagePages.map { ($0.id, $0.journalID) }))
    // The first journal has two photos and the second one; each is stored encrypted, a little larger.
    check("measures each journal's storage, photos included",
          (sizes[journal.id] ?? 0) > 2 * stored.count && (sizes[second.id] ?? 0) > stored.count
          && (sizes[second.id] ?? 0) < (sizes[journal.id] ?? 0))

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

    // Touch ID and Apple Watch: a software key stands in for the Secure Enclave key.
    let deviceKey = P256.KeyAgreement.PrivateKey()
    let storedKey = Data("stand-in for the enclave's key handle".utf8)
    check("unlocking without the password starts off", Vault.deviceUnlockKey(in: directory) == nil)
    check("device unlock refused while it's off", throwsError(VaultError.deviceUnlockOff) {
        _ = try Vault.unlock(in: directory) { _ in deviceKey }
    })
    try recovered.enableDeviceUnlock(storedKey: storedKey, agreement: deviceKey)
    check("device unlock keeps the key handle", Vault.deviceUnlockKey(in: directory) == storedKey)
    var handedBack: Data?
    let byDevice = try Vault.unlock(in: directory) { handedBack = $0; return deviceKey }
    check("device key opens the vault", try byDevice.text(pageID: page.id) == textCanary && handedBack == storedKey)
    check("another key can't open it", throwsError(VaultError.deviceUnlockFailed) {
        _ = try Vault.unlock(in: directory) { _ in P256.KeyAgreement.PrivateKey() }
    })
    try byDevice.changePassword(to: "a brand new password")
    check("device unlock survives a password change", (try? Vault.unlock(in: directory) { _ in deviceKey }) != nil)
    try byDevice.disableDeviceUnlock()
    check("turning it off deletes the copy", Vault.deviceUnlockKey(in: directory) == nil
          && throwsError(VaultError.deviceUnlockOff) { _ = try Vault.unlock(in: directory) { _ in deviceKey } })

    reopened.lock()
    check("locked vault refuses reads", throwsError(VaultError.locked) { _ = try reopened.text(pageID: page.id) })
    check("a locked vault can't turn device unlock on", throwsError(VaultError.locked) {
        try reopened.enableDeviceUnlock(storedKey: storedKey, agreement: deviceKey)
    })

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
    let starredPages = try afterSwap.pages()
    let starredEntry = EntryBuilder.build(pages: starredPages, journalOrder: [journal.id]) {
        $0 == other.id ? "Monday, May 4\nhello" : ""
    }.first
    let starred = starredEntry.map { [StarredEntry($0)] } ?? []
    try afterSwap.setStarredEntries(starred)
    check("round-trips starred entries", try !starred.isEmpty && afterSwap.starredEntries() == starred)
    check("hidden words survive starring", try afterSwap.hiddenWords() == ["CANARYHIDDEN"])
    try afterSwap.setFollowsOn(pageID: other.id, true)
    check("saves a page that follows on", try afterSwap.pages().first { $0.id == other.id }?.followsOn == true)
    try afterSwap.movePage(id: other.id, toJournal: journal.id, number: 201)
    check("moving a page forgets that it followed on", try afterSwap.pages().first { $0.id == other.id }?.followsOn == nil)

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

    // Merge with Previous Entry: the page after a gap continues the entry before it.
    var joined = pages
    joined[2].followsOn = true
    let merged = EntryBuilder.build(pages: joined, journalOrder: [journal]) { texts[$0] ?? "" }
    check("a page marked as following on joins the entry before", merged.count == 4
          && merged.last?.parts.count == 2 && merged.last?.pageLabel == "pp. 2–4")
    var leading = pages
    leading[0].followsOn = true
    check("the first page has nothing to join",
          EntryBuilder.build(pages: leading, journalOrder: [journal]) { texts[$0] ?? "" }.count == 5)

    // Sorting.
    let words: (JournalEntry) -> Int = { WordTokenizer.tokens(in: $0.bodyText).count }
    let titles = { (list: [JournalEntry]) in list.map(\.title) }
    let oldest = EntrySort.date.sorted(entries, ascending: true, wordCount: words)
    check("date order keeps undated entries by the entry before", titles(oldest) == titles(entries))
    let newest = EntrySort.date.sorted(entries, ascending: false, wordCount: words)
    check("newest first reverses it", titles(newest) == titles(entries.reversed()))
    let outOfOrder = [page(1)]
    let outOfOrderText = [outOfOrder[0].id: "March 3, 2026\nlater\nJanuary 9, 2026\nearlier"]
    let shuffled = EntryBuilder.build(pages: outOfOrder, journalOrder: [journal]) { outOfOrderText[$0] ?? "" }
    check("sorts by the date written, not the page",
          EntrySort.date.sorted(shuffled, ascending: true, wordCount: words).first?.month == 1)
    let longest = EntrySort.length.sorted(entries, ascending: false, wordCount: words)
    check("longest first", longest.map(words) == entries.map(words).sorted(by: >))
    let shortest = EntrySort.length.sorted(entries, ascending: true, wordCount: words)
    check("shortest first, ties in written order", shortest.map(words) == entries.map(words).sorted()
          && shortest.first?.id == entries.first { words($0) == shortest.map(words).first }?.id)
    let noDates = UUID()
    let undatedPage = PageInfo(id: UUID(), journalID: noDates, number: 1, status: .done, problem: nil,
                               wasCutOff: false, createdAt: Date(), updatedAt: Date())
    let mixed = EntryBuilder.build(pages: [undatedPage] + pages, journalOrder: [noDates, journal]) {
        $0 == undatedPage.id ? "no dates here" : texts[$0] ?? ""
    }
    check("a journal with no dates goes last either way",
          EntrySort.date.sorted(mixed, ascending: true, wordCount: words).last?.journalID == noDates
          && EntrySort.date.sorted(mixed, ascending: false, wordCount: words).last?.journalID == noDates)

    // Stars find their entry again after edits.
    let jan6 = entries[2]
    let star = StarredEntry(jan6)
    let allPages = Set(pages.map(\.id))
    var shiftedTexts = texts
    shiftedTexts[pages[0].id] = "an added line\n" + texts[pages[0].id]!
    let shifted = EntryBuilder.build(pages: pages, journalOrder: [journal]) { shiftedTexts[$0] ?? "" }
    let moved = EntryStars.reconcile([star], entries: shifted, pageIDs: allPages)
    check("a star follows its entry when lines are added above",
          moved.first?.id != star.id && moved.first?.id == shifted.first { $0.heading == "Jan 6" }?.id)
    var redatedTexts = texts
    redatedTexts[pages[0].id] = texts[pages[0].id]!.replacingOccurrences(of: "Jan 6", with: "January 8, 2026")
    let redated = EntryBuilder.build(pages: pages, journalOrder: [journal]) { redatedTexts[$0] ?? "" }
    let renamed = EntryStars.reconcile([star], entries: redated, pageIDs: allPages)
    check("a star stays when the date is changed", renamed.first?.id == star.id && renamed.first?.heading == "January 8, 2026")
    check("a star waits while its page has no text", EntryStars.reconcile([star], entries: [], pageIDs: allPages) == [star])
    check("a star on a deleted page is dropped", EntryStars.reconcile([star], entries: [], pageIDs: []).isEmpty)

    // Chart hover details never cover their bar.
    let plot = CGRect(x: 36, y: 10, width: 600, height: 146)
    let bounds = CGSize(width: 636, height: 180)
    let tip = CGSize(width: 170, height: 40)
    let short = CGRect(x: 300, y: 120, width: 20, height: 36)
    let tall = CGRect(x: 300, y: 12, width: 20, height: 144)
    let tallAtRight = CGRect(x: 610, y: 12, width: 20, height: 144)
    func box(_ center: CGPoint) -> CGRect {
        CGRect(x: center.x - tip.width / 2, y: center.y - tip.height / 2, width: tip.width, height: tip.height)
    }
    let overShort = box(ChartTooltip.spot(size: tip, bar: short, plot: plot, bounds: bounds))
    check("details go above a short bar", !overShort.intersects(short) && overShort.maxY <= short.minY)
    let besideTall = box(ChartTooltip.spot(size: tip, bar: tall, plot: plot, bounds: bounds))
    check("details go beside a tall bar", !besideTall.intersects(tall) && besideTall.minX >= tall.maxX)
    let leftOfTall = box(ChartTooltip.spot(size: tip, bar: tallAtRight, plot: plot, bounds: bounds))
    check("details go to the left of a tall bar at the right edge", !leftOfTall.intersects(tallAtRight)
          && leftOfTall.maxX <= tallAtRight.minX && leftOfTall.minX >= 0)

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
    let foundText = "We went\nhome. José’s café, then home again."
    check("finds where a search appears, across lines, accents, and apostrophes",
          TextSearch.ranges(of: "went  home", in: foundText).map { (foundText as NSString).substring(with: $0) } == ["went\nhome"]
          && TextSearch.ranges(of: "jose's cafe", in: foundText).map { (foundText as NSString).substring(with: $0) } == ["José’s café"]
          && TextSearch.ranges(of: "HOME", in: foundText).count == 2 && TextSearch.ranges(of: " ", in: foundText).isEmpty)
    check("looks up a phrase across lines and punctuation", snapshot.matches("body, b").count == 2)
    check("compares several words", snapshot.terms("body, Body B, ").map(\.total) == [4, 2])
    let nameCounts = snapshot.nameStats(hidden: [])
    check("every name found is listed, counting only its mentions",
          nameCounts.map(\.key) == ["body", "nobody here"] && nameCounts.map(\.count) == [4, 0])

    // Two people with one first name: a page that only says "Wren" is unsure until she says which.
    func namedPage(_ names: [String], people: [String: String]? = nil) -> PageInfo {
        var structure = PageStructure(markers: [], names: names, text: "")
        structure.people = people
        return PageInfo(id: UUID(), journalID: UUID(), number: 1, status: .done, problem: nil, wasCutOff: false,
                        createdAt: Date(), updatedAt: Date(), structure: structure)
    }
    let plainWren = namedPage(["Wren"])
    let oneWren = PeopleDirectory(pages: [plainWren, namedPage(["Wren"], people: ["wren": "Wren K."])])
    check("one known Wren leaves the others alone", oneWren.resolve("Wren", onPage: plainWren.id) == .person("Wren"))
    let twoWrens = PeopleDirectory(pages: [plainWren, namedPage(["Wren"], people: ["wren": "Wren K."]),
                                           namedPage(["Wren Ames", "Wren's"])])
    check("two Wrens make a bare Wren unsure",
          twoWrens.resolve("Wren", onPage: plainWren.id) == .unsure(written: "Wren", choices: ["Wren Ames", "Wren K."])
          && twoWrens.people(on: plainWren).count == 1)
    check("a full name is its own person", twoWrens.resolve("Wren Ames", onPage: plainWren.id) == .person("Wren Ames"))

    // Analysis counts people through those choices, not the name as written.
    let peopleJournal = UUID()
    let peopleTexts = ["Monday, May 4\nWren came over, and Wren Ames too.", "Tuesday, May 5\nWren called.",
                       "Wednesday, May 6\nSaw Wren at the market."]
    let peoplePages = [(["Wren", "Wren Ames"], nil), (["Wren"], ["wren": "Wren K."]), (["Wren"], nil)]
        .enumerated().map { index, item -> PageInfo in
            var structure = PageStructure(markers: [], names: item.0, text: peopleTexts[index])
            structure.people = item.1
            return PageInfo(id: UUID(), journalID: peopleJournal, number: index + 1, status: .done, problem: nil,
                            wasCutOff: false, createdAt: Date(), updatedAt: Date(), structure: structure)
        }
    let byPerson = AnalysisSnapshot(
        entries: EntryBuilder.build(pages: peoplePages, journalOrder: [peopleJournal]) { id in
            peopleTexts[peoplePages.firstIndex { $0.id == id } ?? 0]
        },
        includedPages: Set(peoplePages.map(\.id)), names: peoplePages.flatMap { $0.structure?.names ?? [] },
        people: PeopleDirectory(pages: peoplePages), journalNames: [:])
    let personCounts = Dictionary(uniqueKeysWithValues: byPerson.nameStats(hidden: []).map { ($0.display, $0.count) })
    check("names count as the person they mean on each page",
          personCounts == ["Wren K.": 1, "Wren Ames": 1, "Wren (unsure which)": 2])
    check("looking up a person counts their mentions", byPerson.term("Wren K.")?.total == 1
          && byPerson.term("Wren (unsure which)")?.pageCount == 2)
    let chosenMatches = byPerson.matches("Wren K.")
    check("a person's mentions are found under the name written", chosenMatches.map(\.pageNumber) == [2]
          && chosenMatches.first.map { match in
              match.highlight.map { String(Array(match.snippet)[$0]) } == "Wren"
          } == true)
    check("typing the first name still finds every mention", byPerson.term("Wren")?.total == 4)
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
    check("finds the longest gap", months.longestGap?.days == 41 && months.longestGap?.from == "Jan 20, 2026"
          && months.longestGap?.to == "Mar 2, 2026")
    let byID = Dictionary(uniqueKeysWithValues: spacedEntries.map { ($0.id, $0) })
    check("the longest gap lists the entries either side",
          months.longestGap?.entryIDs.compactMap { byID[$0]?.day } == [20, 2])
    check("the longest streak lists its entries", months.longestStreak?.entryIDs.compactMap { byID[$0]?.day } == [5, 6])
    check("each weekday lists its entries", months.byWeekday[0].entryIDs.count == 2 && months.byWeekday[1].entryIDs.count == 3)
    // Rolling: weeks of 2, 0, 1, 0, 0, 0, 0, 0, 2 entries over 4 weeks.
    let rollingWeeks = months.rollingCounts(byWeek: true, window: 4).compactMap(\.value)
    check("a rolling average covers the weeks ending at each point",
          rollingWeeks == [2, 1, 1, 0.75, 0.25, 0.25, 0, 0, 0.5])
    check("a rolling average per month", months.rollingCounts(byWeek: false, window: 2).map(\.display) == ["3.0", "1.5", "1.0"])
    check("tracks the average per month as it stood each month",
          months.perMonthTrend.map(\.display) == ["3.0", "1.5", "1.7"] && months.perWeekTrend.count == 9
          && abs((months.perWeekTrend.last?.value ?? 0) - 5.0 / 9) < 1e-9)
    let lateText = "January 10, 2026 11:00 pm\nfirst\n\nFebruary 3, 2026 1:00 am\nsecond\n\nMarch 2, 2026 1:00 am\nthird"
    let late = AnalysisSnapshot(entries: EntryBuilder.build(pages: timed, journalOrder: [journal]) { _ in lateText },
                                includedPages: [timed[0].id], names: [], journalNames: [:]).entryRhythm()
    check("tracks the usual time across midnight without jumping",
          late.timeTrendByMonth.map(\.display) == ["11:00 PM", "12:00 AM", "12:20 AM"]
          && late.timeTrendByMonth.map(\.value) == [-60, 0, 20] && late.averageTime == "12:20 AM")
    check("a rolling usual time forgets older months",
          late.rollingTimes(byWeek: false, window: 1).map(\.display) == ["11:00 PM", "1:00 AM", "1:00 AM"])
    check("each time of day lists its entries", night.byTimeOfDay[0].entryIDs.count == 1 && night.byTimeOfDay[7].entryIDs.count == 1)
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
    let result = try await transcriber.transcribe(photo: jpeg)
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
    let structured = try await transcriber.transcribe(photo: jpeg)
    let firstMarker = structured.structure.markers.first
    check("reads entry headings", firstMarker?.month == 1 && firstMarker?.day == 16 && firstMarker?.time == "20:59")
    check("drops impossible dates and times", structured.structure.markers.last?.day == nil
          && structured.structure.markers.last?.time == nil)
    check("dedupes names", structured.structure.names == ["Theo", "Marguerite"])

    StubAPI.replies = [(200, [:], reply(text: "partial", stop: "max_tokens"))]
    let cutOff = try await transcriber.transcribe(photo: jpeg)
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
    let recovered = try await transcriber.transcribe(photo: jpeg)
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
    await render(CropEditor(image: NSImage(data: spread)!, crop: .constant(spreadScan.crop), angle: .constant(6)).padding(10),
                 size: CGSize(width: 520, height: 460), to: output.appendingPathComponent("4c-crop-turned.png"))
    _ = model.createJournal(name: "Spread Test")
    await render(UploadSheet(preloaded: spread).environmentObject(model), size: CGSize(width: 820, height: 600),
                 to: output.appendingPathComponent("4d-upload-with-photo.png"))
    // Both pages, photographed sideways: the sheet turns the photo upright and splits it at the fold.
    UserDefaults.standard.set(true, forKey: "bothPages")
    let sideways = try PagePhoto.rotated(openJournal(), degrees: 90)
    await render(CropEditor(image: NSImage(data: openJournal())!, crop: .constant(CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)),
                            angle: .constant(3), split: .constant(0.52)).padding(10),
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
        model.addPage(journalID: journal.id, number: number, photo: photo, replacing: false)
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
    model.searchText = "the bread"
    await render(RootView().environmentObject(model).environmentObject(updater), size: size, to: output.appendingPathComponent("3d-entries-search.png"))
    model.searchText = ""
    // Stars, sorting by length, and a page after a gap whose entry can be merged with the one before.
    if let entry = model.selectedEntry { model.toggleStar(entry) }
    model.addPage(journalID: journal.id, number: 5, photo: photo, replacing: false)
    let gapPage = model.pages.first { $0.journalID == journal.id && $0.number == 5 }
    if let gapPage {
        model.editText("and the drive home took all afternoon.", pageID: gapPage.id)
        model.flushEdits()
    }
    model.entrySort = .length
    model.entrySortAscending = false
    await render(RootView().environmentObject(model).environmentObject(updater), size: size,
                 to: output.appendingPathComponent("3e-entries-longest-starred.png"))
    let continued = model.entries.first { $0.parts.first?.pageID == gapPage?.id }
    check("a continued entry after a gap can be merged", continued.map(model.canMergeWithPrevious) == true)
    check("the first entry in a journal can't be merged", model.entries.first.map(model.canMergeWithPrevious) == false)
    if let continued { model.mergeWithPrevious(continued) }
    let mergedEntry = model.entries.first { $0.parts.contains { $0.pageID == gapPage?.id } }
    check("merging joins the page onto the entry before", mergedEntry?.parts.count == 2
          && mergedEntry.map(model.joinedParts(of:))?.count == 1)
    if let mergedEntry, let part = model.joinedParts(of: mergedEntry).first { model.split(mergedEntry, at: part) }
    check("splitting undoes it", model.entries.contains { $0.parts.first?.pageID == gapPage?.id })
    model.showsStarredOnly = true
    model.entrySort = .date
    model.entrySortAscending = true
    await render(RootView().environmentObject(model).environmentObject(updater), size: size,
                 to: output.appendingPathComponent("3e-entries-starred-dark.png"), dark: true)
    check("starred shows only starred entries", model.visibleEntries.count == 1)
    model.showsStarredOnly = false
    if let entry = model.selectedEntry { model.toggleStar(entry) }
    if let gapPage { model.deletePage(id: gapPage.id) }
    model.showingAnalysis = true
    await render(RootView().environmentObject(model).environmentObject(updater), size: size, to: output.appendingPathComponent("8-analysis.png"))
    // Clicking a week in Analysis lists just that week's entries.
    let rhythm = AnalysisSnapshot(entries: model.entries, includedPages: Set(model.pages.map(\.id)), names: [],
                                  journalNames: [:]).entryRhythm()
    if let week = rhythm.byWeek.first(where: { $0.count > 0 }) {
        model.showEntries(week.entryIDs, label: week.label)
        check("clicking a week shows its entries", !model.showingAnalysis && model.libraryMode == .entries
              && Set(model.visibleEntries.map(\.id)) == Set(week.entryIDs) && model.selectedEntryID != nil)
        await render(RootView().environmentObject(model).environmentObject(updater), size: size,
                     to: output.appendingPathComponent("8d-week-entries.png"))
        check("entries opened from Analysis can go back to it", model.canReturnToAnalysis)
        if let journal = model.selectedJournalID { model.selectJournal(journal) }
        check("choosing a journal clears the week", model.entryFilter == nil)
        model.showingAnalysis = true
        check("being back in Analysis drops the way back", !model.canReturnToAnalysis)
        if let page = model.pages.first {
            model.openPage(page.id, highlight: nil)
            check("a page opened from Analysis can go back to it", model.canReturnToAnalysis && !model.showingAnalysis)
            await render(RootView().environmentObject(model).environmentObject(updater), size: size,
                         to: output.appendingPathComponent("8e-page-back-to-analysis.png"))
            model.returnToAnalysis()
            check("going back shows Analysis again", model.showingAnalysis && !model.canReturnToAnalysis)
            model.showingAnalysis = false
            model.openPage(page.id, highlight: nil)
            check("a page opened from elsewhere has no way back to Analysis", !model.canReturnToAnalysis)
            model.showingAnalysis = true
        }
    } else {
        check("clicking a week shows its entries", false)
    }
    await render(AnalysisDetail(showingTrend: .perMonth).environmentObject(model), size: CGSize(width: 900, height: 900),
                 to: output.appendingPathComponent("8b-analysis-trend.png"))
    await render(AnalysisDetail(showingTrend: .time).environmentObject(model), size: CGSize(width: 900, height: 900),
                 to: output.appendingPathComponent("8c-analysis-time-trend-dark.png"), dark: true)
    model.analysisTerm = "Theo"
    await render(AnalysisDetail().environmentObject(model), size: CGSize(width: 900, height: 1100),
                 to: output.appendingPathComponent("9-analysis-term.png"))
    model.hidesEntryText = true
    await render(AnalysisDetail().environmentObject(model), size: CGSize(width: 900, height: 1100),
                 to: output.appendingPathComponent("9-analysis-term-hidden.png"))
    model.showingAnalysis = false
    await render(RootView().environmentObject(model).environmentObject(updater), size: size,
                 to: output.appendingPathComponent("9-page-hidden.png"))
    model.showingAnalysis = true
    model.hidesEntryText = false
    model.analysisTerm = "Theo, park"
    model.accent = .blue
    await render(AnalysisDetail().environmentObject(model), size: CGSize(width: 900, height: 1100),
                 to: output.appendingPathComponent("9-analysis-terms-dark.png"), dark: true)
    model.accent = .clay
    model.analysisTerm = ""
    let walks = CustomStat(name: "Park Walks", question: "How often did I go to the park?", criteria: "",
                           method: .words, words: ["park", "walk*"], unit: "walks")
    model.saveStat(walks)
    await render(AnalysisDetail(showingStat: walks.id).environmentObject(model), size: CGSize(width: 900, height: 1300),
                 to: output.appendingPathComponent("9b-analysis-custom-stat.png"))
    await render(StatEditorSheet(existing: walks) { _ in }.environmentObject(model), size: CGSize(width: 520, height: 600),
                 to: output.appendingPathComponent("9c-stat-editor.png"))
    let walkSnapshot = await model.makeAnalysisSnapshot()
    if let match = walkSnapshot.result(for: walks, findings: [:]).matches.first {
        model.exclude(match, from: walks.id, reason: "Walking to the car doesn't count")
        await render(AnalysisDetail(showingStat: walks.id).environmentObject(model), size: CGSize(width: 900, height: 1300),
                     to: output.appendingPathComponent("9d-analysis-stat-left-out.png"))
        await render(ExcludeReasonSheetPreview(stat: walks, match: match).environmentObject(model),
                     size: CGSize(width: 480, height: 360), to: output.appendingPathComponent("9e-exclude-reason.png"))
    }
    var talks = CustomStat(name: "Friend Talk", question: "How often did I talk about friends?",
                           criteria: "Each time I describe talking with a friend.", method: .reading, words: [],
                           notes: ["Theo is my brother"])
    talks.recountSuggested = true
    model.saveStat(talks)
    await render(AnalysisDetail(showingStat: talks.id).environmentObject(model), size: CGSize(width: 900, height: 700),
                 to: output.appendingPathComponent("9f-analysis-stat-notes-dark.png"), dark: true)
    await render(StatEditorSheet(existing: talks) { _ in }.environmentObject(model), size: CGSize(width: 520, height: 700),
                 to: output.appendingPathComponent("9g-stat-editor-notes.png"))
    model.deleteStat(talks.id)
    model.deleteStat(walks.id)
    model.analysisDateRange = model.datedEntrySpan
    await render(AnalysisScopeColumn().environmentObject(model), size: CGSize(width: 280, height: 520),
                 to: output.appendingPathComponent("9h-analysis-dates.png"))
    check("a date range can start from the entries' dates", model.analysisDateRange != nil)
    model.analysisDateRange = nil
    model.showingAnalysis = false
    // The people on a page, with one first name shared by two people.
    func namedPage(_ names: [String], people: [String: String]? = nil) -> PageInfo {
        var structure = PageStructure(markers: [], names: names, text: "")
        structure.people = people
        return PageInfo(id: UUID(), journalID: UUID(), number: 12, status: .done, problem: nil, wasCutOff: false,
                        createdAt: Date(), updatedAt: Date(), structure: structure)
    }
    let shown = namedPage(["Wren", "Theo", "Marguerite"])
    let knownPeople = PeopleDirectory(pages: [shown, namedPage(["Wren"], people: ["wren": "Wren K."]),
                                            namedPage(["Wren Abbott"])])
    await render(PeopleOnPage(page: shown, people: knownPeople).environmentObject(model), size: CGSize(width: 380, height: 300),
                 to: output.appendingPathComponent("3e-people-on-page.png"))
    model.setLibraryMode(.pages)
    await render(UploadSheet().environmentObject(model), size: CGSize(width: 760, height: 560),
                 to: output.appendingPathComponent("4-upload.png"))
    await render(UploadSheet().environmentObject(model), size: CGSize(width: 760, height: 560),
                 to: output.appendingPathComponent("5-upload-dark.png"), dark: true)
    await render(SettingsSheet().environmentObject(model), size: CGSize(width: 480, height: 760),
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
        let result = try await transcriber.transcribe(photo: jpeg)
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
          model.addPage(journalID: journal.id, number: 12, photo: jpeg, replacing: false),
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
        check("photo survives lock and reopen", try pixelSize(reopened.image(pageID: pageID)) == pixelSize(jpeg))
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
            try await timed("Vault") { try runVaultChecks(in: directory) }
            await timed("Entry") { runEntryChecks() }
            try await timed("Photo") { try runPhotoChecks() }
            try await timed("Photo storage") { try await runPhotoStorageChecks() }
            try await timed("API") { try await runAPIChecks() }
            try await timed("Queue") { try await runQueueChecks() }
            try await timed("Custom stat") { try await runCustomStatChecks() }
            try await timed("Stat counting") { try await runStatCountingChecks() }
            try await timed("Duplicate") { try await runDuplicateChecks() }
            try await timed("Local reading") { try await runLocalReadingChecks() }
            await timed("Switch rule") { runSwitchRuleChecks() }
            try await timed("Editing") { try runEditingChecks(in: directory) }
            try await timed("Scribble") { try await runScribbleChecks() }
            await timed("Banner") { await MainActor.run { runBannerChecks() } }
            try await timed("Rotation") { try await runRotationChecks() }
            try await timed("Tilted crop") { try runTiltedCropChecks() }
            try await timed("Word placement") { try await runWordPlacementChecks() }
            try await timed("Page scan") { try await runPageScanChecks() }
            try await timed("Spread") { try await runSpreadChecks() }
            try await timed("Photo order") { try runPhotoOrderChecks() }
            try await timed("Flatten") { try await runFlattenChecks() }
            await timed("Updater") { runUpdaterChecks() }
            await timed("Release update") { runReleaseUpdateChecks() }
            await timed("Missing runtime") { await runMissingRuntimeChecks() }
        } catch {
            failures += 1
            print("  FAIL  stopped early: \(error)")
        }
        printTimings()
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
    RunLoop.main.run()
}
