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
        if let index = stats.firstIndex(where: { $0.id == stat.id }) {
            let old = stats[index]
            recount = stat.method == .reading && (old.criteria != stat.criteria || old.method != .reading)
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
        do {
            try vault.removeStatFindings(statID: id)
            pages = try vault.pages()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        countStat(id)
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
            var next = 0
            var failure: Error?
            await withTaskGroup(of: (batch: [StatPageText], result: Result<[UUID: [String]], Error>).self) { group in
                func start() {
                    guard next < batches.count else { return }
                    let batch = batches[next]
                    next += 1
                    group.addTask {
                        do { return (batch, .success(try await counter.count(stat, pages: batch))) } catch { return (batch, .failure(error)) }
                    }
                }
                for _ in 0..<min(Self.concurrentReads, batches.count) { start() }
                for await (batch, outcome) in group {
                    guard let self, !Task.isCancelled, self.vault === vault else { return }
                    switch outcome {
                    case .success(let found):
                        let texts = Dictionary(uniqueKeysWithValues: batch.map { ($0.pageID, $0.text) })
                        for (pageID, quotes) in found {
                            try? vault.setStatFindings(pageID: pageID, [id: StatFinding(quotes: quotes, text: texts[pageID] ?? "")])
                        }
                        self.statCounting[id]?.done += found.count
                        if let updated = try? vault.pages() { self.pages = updated }
                        if failure == nil { start() }
                    case .failure(let error):
                        if !(error is CancellationError) { failure = error }
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
