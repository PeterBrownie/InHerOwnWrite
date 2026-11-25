import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WriteApp
import WriteCore

/// Custom stats: counting words, placing Claude's quotes, the requests sent, and what the vault keeps.
func runCustomStatChecks() async throws {
    print("Custom stats")
    let journal = UUID()
    func page(_ number: Int) -> PageInfo {
        PageInfo(id: UUID(), journalID: journal, number: number, status: .done, problem: nil, wasCutOff: false,
                 createdAt: Date(), updatedAt: Date())
    }
    let pages = [page(1), page(2)]
    let texts = [
        pages[0].id: "Jan 5, 2026\nI cried at lunch and the tears kept coming.\n\nJan 9, 2026\nA calm day at the park.",
        pages[1].id: "Feb 2, 2026\nI broke down after the call and cried again.\nCrying is tiring.",
    ]
    let entries = EntryBuilder.build(pages: pages, journalOrder: [journal]) { texts[$0] ?? "" }
    let snapshot = AnalysisSnapshot(entries: entries, includedPages: Set(pages.map(\.id)), names: [], journalNames: [:])

    let words = CustomStat(name: "Cry Count", question: "How many times did I cry?", criteria: "", method: .words,
                           words: ["cried", "cry*", "broke down"])
    let counted = snapshot.result(for: words, findings: [:])
    // "cried" twice, "crying" once through cry*, and "broke down" once.
    check("counts words, prefixes, and phrases", counted.term.total == 4)
    check("counts the entries they're in", counted.term.entryCount == 2 && counted.term.pageCount == 2)
    check("charts word counts by date", counted.term.byDate.reduce(0) { $0 + $1.count } == 4)
    check("each bar of a stat's chart lists its entries",
          counted.term.byDate.filter { $0.count > 0 }.allSatisfy { !$0.entryIDs.isEmpty }
          && Set(counted.term.byDate.flatMap(\.entryIDs)) == Set(counted.matches.compactMap(\.entryID))
          && Set(counted.term.byPage.flatMap(\.entryIDs)) == Set(counted.matches.compactMap(\.entryID)))
    check("lists where words were found", counted.matches.count == 2 && counted.matches.allSatisfy { $0.highlight != nil })
    check("a prefix keeps its star", AnalysisSnapshot.pattern("Cry*") == ["cry*"]
          && AnalysisSnapshot.pattern("broke down") == ["broke", "down"])

    let reading = CustomStat(name: "Cry Count", question: "How many times did I cry?",
                             criteria: "Each time I cried.", method: .reading, words: [])
    let found = snapshot.result(for: reading, findings: [
        pages[0].id: ["I cried at lunch"],
        pages[1].id: ["broke down after the call", "a quote that isn't on the page"],
    ])
    check("counts each quote Claude found", found.term.total == 3)
    check("places a quote in the entry that holds it",
          found.matches.first { $0.pageID == pages[0].id }?.snippet.contains("cried at lunch") == true
          && found.matches.filter { $0.pageID == pages[0].id }.count == 1)
    check("a quote not on the page still counts on that page",
          found.matches.first { $0.pageID == pages[1].id }?.count == 2)

    // A page whose only quote isn't written there word for word (a quote across two entries, say) still
    // lists where it was found.
    let unmatched = snapshot.result(for: reading, findings: [pages[0].id: ["cried, and the next day"]])
    check("a page whose quote isn't on it still lists the page",
          unmatched.term.total == 1 && unmatched.matches.count == 1 && unmatched.matches[0].highlight == nil)
    check("a snippet with no words to find shows the start", AnalysisSnapshot.snippet(of: [], in: "Some words.").1 == nil
          && AnalysisSnapshot.snippet(of: [], in: "").0.isEmpty)

    // Leaving an entry out, and notes for Claude.
    var trimmed = reading
    let firstMatch = found.matches.first { $0.pageID == pages[0].id }!
    trimmed.exclusions = [StatExclusion(pageID: firstMatch.pageID, entryID: firstMatch.entryID!, pageNumber: 1,
                                        date: firstMatch.date, snippet: firstMatch.snippet, reason: "Not about me")]
    let left = snapshot.result(for: trimmed, findings: [
        pages[0].id: ["I cried at lunch"],
        pages[1].id: ["broke down after the call", "a quote that isn't on the page"],
    ])
    check("an excluded entry isn't counted", left.term.total == 2 && left.excludedCount == 1
          && !left.matches.contains { $0.pageID == pages[0].id })
    let worded = snapshot.result(for: CustomStat(name: "Cry Count", question: "", criteria: "", method: .words,
                                                 words: ["cried"]), findings: [:])
    var wordsLeft = CustomStat(name: "Cry Count", question: "", criteria: "", method: .words, words: ["cried"])
    wordsLeft.exclusions = [StatExclusion(pageID: worded.matches[0].pageID, entryID: worded.matches[0].entryID!,
                                          pageNumber: 1, date: nil, snippet: "", reason: nil)]
    check("an excluded entry isn't counted by words either",
          snapshot.result(for: wordsLeft, findings: [:]).term.total == worded.term.total - worded.matches[0].count)
    let old = #"{"id":"\#(UUID().uuidString)","name":"Old","question":"q","criteria":"c","method":"reading","words":[],"unit":"times"}"#
    let decoded = try? JSONDecoder().decode(CustomStat.self, from: Data(old.utf8))
    check("a stat saved before notes still opens", decoded?.notes == [] && decoded?.exclusions == [] && decoded?.recountSuggested == false)
    var noted = reading
    noted.notes = ["Sam is my brother"]
    check("notes go along with the criteria", noted.criteriaWithNotes == "Each time I cried. Notes from the writer: Sam is my brother.")

    // Only entries in a date range.
    let january = AnalysisSnapshot.dayNumber(year: 2026, month: 1, day: 1)!...AnalysisSnapshot.dayNumber(year: 2026, month: 1, day: 31)!
    let dated = AnalysisSnapshot(entries: entries, includedPages: Set(pages.map(\.id)), names: [], journalNames: [:], days: january)
    check("a date range keeps only entries dated in it", dated.result(for: words, findings: [:]).term.total == 1
          && dated.result(for: words, findings: [:]).matches.allSatisfy { $0.pageID == pages[0].id })

    let finding = StatFinding(quotes: ["x"], text: "page text")
    check("a finding knows the text it was counted on", finding.matches("page text") && !finding.matches("page text, edited"))

    // Batches: about `batchCharacters` each, with the page before as context.
    let long = String(repeating: "word ", count: StatCounter.batchCharacters / 10)
    let list = (1...5).map { StatPageText(pageID: UUID(), label: "Page \($0)", text: long + long + long, context: false) }
    let batches = StatCounter.batches(list)
    check("splits long text into batches", batches.count > 1)
    check("every page is counted once", batches.flatMap { $0.filter { !$0.context } }.map(\.pageID) == list.map(\.pageID))
    check("later batches start with the page before as context",
          batches.dropFirst().allSatisfy { $0.first?.context == true })

    // Requests (stubbed network).
    let transcriber = stubbedTranscriber()
    let counter = StatCounter(transcriber: transcriber)
    StubAPI.requests = []
    StubAPI.replies = [(200, [:], rawReply(#"{"name":"Cry Count","unit":"Times","criteria":"Each time I cried.","words":["Cried","cry*"],"method":"words"}"#))]
    let plan = try await counter.plan(question: "How many times did I cry?")
    check("plans a stat from the question", plan.name == "Cry Count" && plan.method == .words && plan.words == ["cried", "cry*"])
    if let body = StubAPI.requests.last?.1, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
        let messages = json["messages"] as? [[String: Any]] ?? []
        check("planning uses Sonnet", json["model"] as? String == "claude-sonnet-5-5")
        check("planning sends only the question", messages.count == 1 && messages[0]["content"] as? String == "How many times did I cry?")
        let format = (json["output_config"] as? [String: Any])?["format"] as? [String: Any]
        check("the plan schema follows structured output rules", format.map { schemaIsStrict($0["schema"]!) } ?? false)
    }

    let context = StatPageText(pageID: UUID(), label: "Page 1", text: "before", context: true)
    let target = StatPageText(pageID: UUID(), label: "Page 2", text: "I cried.", context: false)
    let quiet = StatPageText(pageID: UUID(), label: "Page 3", text: "Nothing much.", context: false)
    StubAPI.requests = []
    StubAPI.replies = [(200, [:], rawReply(#"{"pages":[{"page":"P1","instances":[{"quote":"before"}]},{"page":"P2","instances":[{"quote":"I cried"}]}]}"#))]
    let result = try await counter.count(reading, pages: [context, target, quiet])
    check("counts only pages that aren't context", result[context.pageID] == nil && result[target.pageID] == ["I cried"])
    check("pages with nothing found are counted as none", result[quiet.pageID] == [])
    if let body = StubAPI.requests.last?.1, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
        let content = (json["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        check("counting uses Sonnet", json["model"] as? String == "claude-sonnet-5-5")
        check("counting sends text, not photos", content.contains("[P2] Page 2") && content.contains("(context only)")
              && !String(data: body, encoding: .utf8)!.contains("\"image\""))
        let format = (json["output_config"] as? [String: Any])?["format"] as? [String: Any]
        check("the count schema follows structured output rules", format.map { schemaIsStrict($0["schema"]!) } ?? false)
    }

    var notedStat = reading
    notedStat.notes = ["Sam is my brother"]
    StubAPI.requests = []
    StubAPI.replies = [(200, [:], rawReply(#"{"pages":[]}"#))]
    _ = try await counter.count(notedStat, pages: [target])
    if let body = StubAPI.requests.last?.1, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
        let content = (json["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        check("counting is given her notes", content.contains("Notes from the writer: Sam is my brother."))
    }

    // Counted while a page is read.
    let jpeg = try PagePhoto.prepare(syntheticPhoto())
    let pageJSON: [String: Any] = ["transcription": "Dear diary, I cried.", "entries": [], "names": [],
                                   "stats": ["s1": [["quote": "I cried"]]]]
    StubAPI.requests = []
    StubAPI.replies = [(200, [:], rawReply(String(data: try JSONSerialization.data(withJSONObject: pageJSON), encoding: .utf8)!))]
    let read = try await transcriber.transcribe(photo: jpeg, stats: [noted])
    check("a reading counts stats in the same request", read.statQuotes[reading.id] == ["I cried"])
    if let body = StubAPI.requests.last?.1, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
        let format = (json["output_config"] as? [String: Any])?["format"] as? [String: Any]
        let schema = format?["schema"] as? [String: Any]
        check("reading a photo with stats stays on Opus", json["model"] as? String == Transcriber.model
              && Transcriber.model.hasPrefix("claude-opus"))
        check("the reading schema asks for each stat", (schema?["required"] as? [String])?.contains("stats") == true
              && schemaIsStrict(schema ?? [:]))
        let content = ((json["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        check("the reading says what counts", (content.last?["text"] as? String)?.contains("Each time I cried.") == true)
        check("a page reading is given her notes", (content.last?["text"] as? String)?.contains("Sam is my brother.") == true)
    }

    // What the vault keeps.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let vault = try Vault.create(in: directory, password: "synthetic password").vault
    let book = try vault.createJournal(name: "Stats")
    let mark = PageFingerprint(words: ["an", "invented", "page"])
    let saved = try vault.addPage(journalID: book.id, number: 1, photo: jpeg, fingerprint: mark)
    check("a page keeps its fingerprint", try vault.pages().first?.fingerprint == mark)
    try vault.setCustomStats([reading])
    check("stats are saved", try vault.customStats() == [reading])
    try vault.saveReading(pageID: saved.id, transcription: read)
    check("a reading saves its stat quotes", try vault.pages().first?.stats?[reading.id.uuidString]?.quotes == ["I cried"])
    try vault.setStatFindings(pageID: saved.id, [reading.id: StatFinding(quotes: ["a", "b"], text: "x")])
    check("findings can be replaced", try vault.pages().first?.stats?[reading.id.uuidString]?.quotes.count == 2)
    try vault.removeStatFindings(statID: reading.id)
    check("a deleted stat's findings are removed", try vault.pages().first?.stats?[reading.id.uuidString] == nil)
    vault.lock()
}

/// Duplicate pages: the same file, the same page photographed again, and the same text saved twice.
func runDuplicateChecks() async throws {
    print("Duplicate pages")
    let page = handwrittenPage()
    check("the same file has the same digest", PageFingerprint.fileDigest(page) == PageFingerprint.fileDigest(page))
    check("different files have different digests", PageFingerprint.fileDigest(page) != PageFingerprint.fileDigest(page + Data([0])))

    let whole = try PageFlattener.process(page, crop: CGRect(x: 0, y: 0, width: 1, height: 1), flatten: false)
    let tighter = try PageFlattener.process(page, crop: CGRect(x: 0.03, y: 0.02, width: 0.94, height: 0.95), flatten: true)
    let first = await PageFingerprint.make(image: whole)
    let second = await PageFingerprint.make(image: tighter)
    check("Vision reads words on an invented page", (first?.words.count ?? 0) >= 10)
    if let first, let second {
        check("the same page cropped differently matches", first.isSamePage(as: second))
    }
    let blank = await PageFingerprint.make(image: syntheticPhoto())
    check("a blank page has no fingerprint", blank == nil)
    let a = "we walked down to the river and sat by the water until the light went".split(separator: " ").map(String.init)
    let b = "my sister called about the trip and we planned the drive for next weekend".split(separator: " ").map(String.init)
    check("different pages share few word pairs", PageFingerprint.wordSimilarity(a, b) < PageFingerprint.samePage)
    check("the same words in order match", PageFingerprint.wordSimilarity(a, a) == 1)

    let text = (1...40).map { "line \($0) of an invented page with words" }.joined(separator: "\n")
    let edited = text.replacingOccurrences(of: "line 3 ", with: "lime 3 ")
    let other = (1...40).map { "another sentence number \($0) somewhere else entirely" }.joined(separator: "\n")
    let ids = [UUID(), UUID(), UUID()]
    let pairs = TextDuplicates.find([ids[0]: text, ids[1]: edited, ids[2]: other])
    check("pages with nearly the same text are paired", pairs[ids[0]] == ids[1] && pairs[ids[1]] == ids[0])
    check("a different page isn't paired", pairs[ids[2]] == nil)
    check("short pages aren't compared", TextDuplicates.find([ids[0]: "a few words", ids[1]: "a few words"]).isEmpty)
}

/// Answers page readings with invented text, and counting requests with one quote on every counted page.
final class StatStubAPI: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var countRequests = 0
    nonisolated(unsafe) static var readings = 0

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
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let content = (json["messages"] as? [[String: Any]])?.first?["content"]
        let text: String
        if let prompt = content as? String {
            // Counting: one instance on every page that isn't context.
            Self.lock.withLock { Self.countRequests += 1 }
            let keys = prompt.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("[P"), !line.hasSuffix("(context only)"), let end = line.firstIndex(of: "]") else { return nil }
                return String(line[line.index(after: line.startIndex)..<end])
            }
            let pages = keys.map { ["page": $0, "instances": [["quote": "I cried"]]] as [String: Any] }
            text = rawReply(String(data: try! JSONSerialization.data(withJSONObject: ["pages": pages]), encoding: .utf8)!)
        } else {
            let number = Self.lock.withLock { () -> Int in Self.readings += 1; return Self.readings }
            let line = "On an invented day number \(number) I walked to the shop, and later I cried a little. "
            text = reply(text: String(repeating: line, count: 40))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// Counting a stat with Claude across a whole journal, through the app, as when she confirms "Count Pages".
@MainActor
func runStatCountingChecks() async throws {
    print("Counting a stat on many pages (stubbed network)")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(directory: directory)
    model.makeTranscriber = { key in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatStubAPI.self]
        return Transcriber(apiKey: key, session: URLSession(configuration: configuration), retryDelay: 0.01)
    }
    await model.createVault(password: "synthetic password")
    model.confirmRecoveryKeySaved()
    model.showSettings = false
    _ = await model.saveAPIKey("sk-test-canary")
    guard let journal = model.createJournal(name: "Stat Test") else {
        check("stat test journal is made", false)
        return
    }
    let jpeg = try PagePhoto.prepare(syntheticPhoto(width: 300, height: 400))
    // Enough text for several batches; more pages only make the reading slow on GitHub's Macs.
    let total = 60
    for number in 1...total {
        _ = model.addPage(journalID: journal.id, number: number, photo: jpeg, replacing: false)
    }
    var deadline = Date().addingTimeInterval(240)
    while Date() < deadline, model.pages.contains(where: { $0.status == .reading || $0.status == .waiting }) {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    check("\(total) invented pages are read", model.pages.filter { $0.status == .done }.count == total)

    let stat = CustomStat(name: "Cry Count", question: "How many times did I cry?", criteria: "Each time I cried.",
                          method: .reading, words: [])
    model.saveStat(stat)
    check("every read page waits to be counted", model.pagesToCount(stat).count == total)
    StatStubAPI.countRequests = 0
    model.countStat(stat.id)
    deadline = Date().addingTimeInterval(120)
    while Date() < deadline, model.statCounting[stat.id] != nil {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    check("counting finishes without a problem", model.statCounting[stat.id] == nil)
    check("counting is sent in batches", StatStubAPI.countRequests >= 3)
    check("every page is counted", model.pagesToCount(stat).isEmpty
          && model.statFindings(stat).count == total)

    // Leaving an entry out with a reason.
    let analysis = await model.makeAnalysisSnapshot()
    if let saved = model.customStats.first(where: { $0.id == stat.id }),
       let match = analysis.result(for: saved, findings: model.statFindings(saved)).matches.first {
        model.exclude(match, from: stat.id, reason: "Sam is my brother")
        let after = model.customStats.first { $0.id == stat.id }
        check("a reason becomes a note for Claude", after?.notes == ["Sam is my brother"] && after?.exclusions.count == 1)
        check("a new note offers counting again", after?.recountSuggested == true)
        check("the entry is left out of the count",
              analysis.result(for: after!, findings: model.statFindings(after!)).excludedCount == 1)
        var renamed = after!
        renamed.name = "Friend Talk"
        model.saveStat(renamed)
        check("editing a stat keeps what was left out", model.customStats.first { $0.id == stat.id }?.exclusions.count == 1
              && model.pagesToCount(stat).isEmpty)
        model.dismissRecountSuggestion(stat.id)
        check("the offer can be put off", model.customStats.first { $0.id == stat.id }?.recountSuggested == false)
        model.includeAgain(after!.exclusions[0], in: stat.id)
        check("a left-out entry can be counted again", model.customStats.first { $0.id == stat.id }?.exclusions.isEmpty == true)
    } else {
        check("a counted stat lists where it was found", false)
    }
    model.lock()
}
