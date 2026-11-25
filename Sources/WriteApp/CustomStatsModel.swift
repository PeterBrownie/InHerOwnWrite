import Foundation
import WriteCore

/// How far Claude has got counting a stat.
public struct StatCountProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var problem: String?
}

// MARK: - Custom stats

extension AppModel {
    /// Asks Claude to suggest a stat for her question. Only the question is sent.
    public func planStat(question: String) async throws -> StatPlan {
        guard let apiKey else { throw TranscriberError.missingKey }
        return try await StatCounter(transcriber: makeTranscriber(apiKey)).plan(question: question)
    }

    /// Adds a new stat, or saves changes to one. A stat counted by reading whose criteria changed forgets what
    /// was found before, so every page is counted again under the new criteria.
    public func saveStat(_ stat: CustomStat) {
        guard let vault else { return }
        var stats = customStats
        var recount = stat.method == .reading
        var stat = stat
        if let index = stats.firstIndex(where: { $0.id == stat.id }) {
            let old = stats[index]
            recount = stat.method == .reading && (old.criteria != stat.criteria || old.method != .reading)
            // New notes don't throw away what was counted; they offer counting again.
            if stat.method == .reading, !recount, old.notes != stat.notes, !stat.notes.isEmpty { stat.recountSuggested = true }
            stats[index] = stat
        } else {
            stats.append(stat)
        }
        do {
            try vault.setCustomStats(stats)
            customStats = stats
            if recount, stats.contains(where: { $0.id == stat.id }) {
                statTasks.removeValue(forKey: stat.id)?.cancel()
                statCounting[stat.id] = nil
                try vault.removeStatFindings(statID: stat.id)
                pages = try vault.pages()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forgets what Claude found for a stat and counts every read page again.
    public func recountStat(_ id: UUID) {
        guard let vault else { return }
        stopCounting(id)
        if var stat = customStats.first(where: { $0.id == id }), stat.recountSuggested {
            stat.recountSuggested = false
            saveStat(stat)
        }
        do {
            try vault.removeStatFindings(statID: id)
            pages = try vault.pages()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        countStat(id)
    }

    /// Leaves one entry on one page out of a stat. A reason, for a stat Claude counts, becomes a note Claude
    /// is given from then on ("Sam is my brother"), with an offer to count every page again.
    public func exclude(_ match: TermMatch, from statID: UUID, reason: String? = nil) {
        guard var stat = customStats.first(where: { $0.id == statID }), let entryID = match.entryID,
              !stat.excludes(pageID: match.pageID, entryID: entryID) else { return }
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = reason?.isEmpty == false ? reason : nil
        stat.exclusions.append(StatExclusion(pageID: match.pageID, entryID: entryID, pageNumber: match.pageNumber,
                                             date: match.date, snippet: match.snippet, reason: given))
        if let given, stat.method == .reading, !stat.notes.contains(given) {
            stat.notes.append(given)
            stat.recountSuggested = true
        }
        saveStat(stat)
    }

    /// Counts an entry she left out again. Its reason stays among the notes until she removes it there.
    public func includeAgain(_ exclusion: StatExclusion, in statID: UUID) {
        guard var stat = customStats.first(where: { $0.id == statID }) else { return }
        stat.exclusions.removeAll { $0.id == exclusion.id }
        saveStat(stat)
    }

    public func dismissRecountSuggestion(_ statID: UUID) {
        guard var stat = customStats.first(where: { $0.id == statID }), stat.recountSuggested else { return }
        stat.recountSuggested = false
        saveStat(stat)
    }

    public func deleteStat(_ id: UUID) {
        guard let vault else { return }
        statTasks.removeValue(forKey: id)?.cancel()
        statCounting[id] = nil
        let stats = customStats.filter { $0.id != id }
        do {
            try vault.setCustomStats(stats)
            customStats = stats
            try vault.removeStatFindings(statID: id)
            pages = try vault.pages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Claude's quotes for a stat, by page.
    public func statFindings(_ stat: CustomStat) -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        for page in pages {
            if let finding = page.stats?[stat.id.uuidString] { result[page.id] = finding.quotes }
        }
        return result
    }

    /// Read pages a stat counted by reading still has to count: never counted, or edited since.
    public func pagesToCount(_ stat: CustomStat) -> [PageInfo] {
        guard stat.method == .reading else { return [] }
        return pages.filter { page in
            guard page.status == .done, let text = texts[page.id],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let finding = page.stats?[stat.id.uuidString] else { return true }
            return !finding.matches(text)
        }
    }

    /// Has Claude count a stat on every page that needs it, from the pages' text. Photos aren't sent. Pages go
    /// in journal order, a few batches at a time, and each batch is saved as it comes back.
    public func countStat(_ id: UUID) {
        guard statTasks[id] == nil, let vault, let apiKey,
              let stat = customStats.first(where: { $0.id == id }) else { return }
        let needed = Set(pagesToCount(stat).map(\.id))
        guard !needed.isEmpty else { return }
        flushEdits()

        // Pages in journal order; the page just before a counted one goes along as context.
        var list: [StatPageText] = []
        let order = Dictionary(uniqueKeysWithValues: journals.enumerated().map { ($1.id, $0) })
        let sorted = pages.sorted { (order[$0.journalID] ?? 0, $0.number) < (order[$1.journalID] ?? 0, $1.number) }
        let multipleJournals = journals.count > 1
        for (index, page) in sorted.enumerated() where needed.contains(page.id) {
            let label = (multipleJournals ? "\(journalName(page.journalID)), page " : "Page ") + "\(page.number)"
            if index > 0, list.last?.pageID != sorted[index - 1].id {
                let before = sorted[index - 1]
                if before.journalID == page.journalID, before.number == page.number - 1, let text = texts[before.id], !text.isEmpty {
                    let beforeLabel = (multipleJournals ? "\(journalName(before.journalID)), page " : "Page ") + "\(before.number)"
                    list.append(StatPageText(pageID: before.id, label: beforeLabel, text: text, context: true))
                }
            }
            list.append(StatPageText(pageID: page.id, label: label, text: texts[page.id] ?? "", context: false))
        }
        let batches = StatCounter.batches(list)
        let counter = StatCounter(transcriber: makeTranscriber(apiKey))
        statCounting[id] = StatCountProgress(done: 0, total: needed.count, problem: nil)

        statTasks[id] = Task { [weak self] in
            // Kept plain on purpose: an earlier version that added tasks from a nested function stopped
            // quietly in release builds, with nothing saved and no error.
            var waiting = batches[...]
            var failure: Error?
            await withTaskGroup(of: StatBatchOutcome.self) { group in
                for _ in 0..<Self.concurrentReads {
                    guard let batch = waiting.popFirst() else { break }
                    group.addTask { await StatBatchOutcome(counter: counter, stat: stat, batch: batch) }
                }
                while let outcome = await group.next() {
                    if Task.isCancelled || self?.vault !== vault {
                        group.cancelAll()
                        continue
                    }
                    if let error = outcome.error {
                        if !(error is CancellationError), failure == nil { failure = error }
                        continue
                    }
                    let texts = Dictionary(outcome.batch.map { ($0.pageID, $0.text) }, uniquingKeysWith: { first, _ in first })
                    for (pageID, quotes) in outcome.found {
                        try? vault.setStatFindings(pageID: pageID, [id: StatFinding(quotes: quotes, text: texts[pageID] ?? "")])
                    }
                    self?.statCounting[id]?.done += outcome.found.count
                    if let updated = try? vault.pages() { self?.pages = updated }
                    if failure == nil, let batch = waiting.popFirst() {
                        group.addTask { await StatBatchOutcome(counter: counter, stat: stat, batch: batch) }
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.statTasks[id] = nil
            if let failure {
                self.statCounting[id]?.problem = failure.localizedDescription
            } else {
                self.statCounting[id] = nil
            }
        }
    }

    public func stopCounting(_ id: UUID) {
        statTasks.removeValue(forKey: id)?.cancel()
        statCounting[id] = nil
    }
}

// MARK: - Duplicate pages

extension AppModel {
    /// The saved page that looks like the same page as this fingerprint, if any, with how alike they are.
    public func samePage(as fingerprint: PageFingerprint, excluding: Set<UUID> = []) -> PageInfo? {
        var best: (page: PageInfo, score: Double)?
        for page in pages where !excluding.contains(page.id) {
            guard let other = page.fingerprint else { continue }
            let score = fingerprint.similarity(to: other)
            if score >= PageFingerprint.samePage, score > best?.score ?? 0 { best = (page, score) }
        }
        return best?.page
    }

    /// The page whose text this page's text nearly repeats, if any.
    public func duplicate(of pageID: UUID) -> PageInfo? {
        textDuplicates[pageID].flatMap(page(id:))
    }

    /// Works out, in the background, fingerprints for pages saved before they were kept.
    func fingerprintOldPages() {
        guard let vault, fingerprinting == nil else { return }
        let ids = pages.filter { $0.fingerprint == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        fingerprinting = Task { [weak self] in
            for id in ids {
                guard let self, !Task.isCancelled, self.vault === vault else { return }
                guard let photo = try? vault.image(pageID: id) else { continue }
                let fingerprint = await Task.detached(priority: .background) {
                    await PageFingerprint.make(image: photo)
                }.value
                guard !Task.isCancelled, self.vault === vault else { return }
                // A page with too little writing to compare gets an empty fingerprint, so it isn't tried again.
                try? vault.setFingerprint(pageID: id, fingerprint ?? PageFingerprint(words: []))
            }
            guard let self, !Task.isCancelled, self.vault === vault else { return }
            if let updated = try? vault.pages() { self.pages = updated }
            self.fingerprinting = nil
        }
    }
}

/// What came back for one batch of pages: the quotes found on each counted page, or why counting failed.
struct StatBatchOutcome: Sendable {
    let batch: [StatPageText]
    var found: [UUID: [String]] = [:]
    var error: Error?

    init(counter: StatCounter, stat: CustomStat, batch: [StatPageText]) async {
        self.batch = batch
        do {
            found = try await counter.count(stat, pages: batch)
        } catch {
            self.error = error
        }
    }
}
