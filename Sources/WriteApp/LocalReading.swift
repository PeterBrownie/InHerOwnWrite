import AppKit
import CoreGraphics
import SwiftUI
import WriteCore

/// What the window shows while a page is read on this Mac. Every decision the model makes passes through here.
@MainActor
public final class LocalReadSession: ObservableObject {
    public enum Phase: Equatable {
        case loadingModel
        case findingWords
        case reading
        case done
        case failed(String)
        case stopped
    }

    public struct WordState: Equatable {
        public var text: String
        public var letters: [CGRect]
        public var box: CGRect
        public var confidence: Double?
        public var changed: Bool
        /// Fixed by hand while the reading ran.
        public var edited = false
    }

    public struct Summary: Identifiable, Equatable {
        public let id: Int
        public let word: String
        public let title: String
        public let picked: String
        public let share: Double
        public let changed: Bool
    }

    public let pageID: UUID
    public let pageNumber: Int
    public let journalName: String
    @Published public private(set) var photo: NSImage?
    public let settings: LocalReadSettings

    @Published public private(set) var phase: Phase = .loadingModel
    @Published public private(set) var lines: [[WordState]] = []
    @Published public private(set) var lineBoxes: [CGRect] = []
    @Published public private(set) var current: (line: Int, word: Int)?
    @Published public private(set) var crop: CGImage?
    @Published public private(set) var question: DecisionQuestion?
    @Published public private(set) var probabilities: [Double?] = []
    @Published public private(set) var shares: [Double]?
    @Published public private(set) var choice: Int?
    @Published public private(set) var recent: [Summary] = []
    @Published public private(set) var decisions = 0
    @Published public private(set) var reused = 0
    @Published public private(set) var lettersChanged = 0
    @Published public private(set) var wordsDone = 0
    @Published public private(set) var modelMilliseconds = 0.0
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var finishedAt: Date?
    /// Words fixed by hand while reading, by line and word position, applied when the page is saved.
    @Published public private(set) var edits: [Int: [Int: String]] = [:]

    public init(pageID: UUID, pageNumber: Int, journalName: String, photo: NSImage?, settings: LocalReadSettings) {
        self.pageID = pageID
        self.pageNumber = pageNumber
        self.journalName = journalName
        self.photo = photo
        self.settings = settings
    }

    public var wordCount: Int { lines.reduce(0) { $0 + $1.count } }

    public var averageMilliseconds: Double? {
        decisions > 0 ? modelMilliseconds / Double(decisions) : nil
    }

    /// Projects the remaining time from the pace so far.
    public var secondsLeft: Double? {
        guard let startedAt, wordsDone >= 3, wordCount > wordsDone, finishedAt == nil else { return nil }
        let perWord = Date().timeIntervalSince(startedAt) / Double(wordsDone)
        return perWord * Double(wordCount - wordsDone)
    }

    public var isActive: Bool {
        switch phase {
        case .loadingModel, .findingWords, .reading: return true
        default: return false
        }
    }

    /// The text as decided so far, with words not reached yet left out.
    public var transcript: String {
        lines.map { line in line.filter { $0.confidence != nil }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// Fixes a word that has already been decided. It's saved with the page when the reading finishes.
    public func edit(line: Int, word: Int, to text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !cleaned.isEmpty, lines.indices.contains(line), lines[line].indices.contains(word),
              lines[line][word].confidence != nil
        else { return }
        lines[line][word].text = cleaned
        lines[line][word].edited = true
        edits[line, default: [:]][word] = cleaned
    }

    public func setPhase(_ phase: Phase) {
        self.phase = phase
        if phase == .findingWords { startedAt = Date() }
        if !isActive {
            finishedAt = Date()
            current = nil
            question = nil
        }
    }

    public func apply(_ event: LocalReadEvent) {
        switch event {
        case .started(let layout, let image):
            photo = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            lineBoxes = layout.lines.map(\.box)
            lines = layout.lines.map { line in
                line.words.map { WordState(text: $0.text, letters: $0.letters, box: $0.box, confidence: nil, changed: false) }
            }
            phase = .reading

        case .wordStarted(let line, let word, let crop):
            current = (line, word)
            self.crop = crop

        case .asked(let question):
            self.question = question
            probabilities = Array(repeating: nil, count: question.candidates.count)
            shares = nil
            choice = nil

        case .scored(let id, let option, let probability, let milliseconds, let cached):
            guard question?.id == id, probabilities.indices.contains(option) else { return }
            probabilities[option] = probability
            if cached {
                reused += 1
            } else {
                decisions += 1
                modelMilliseconds += milliseconds
            }

        case .answered(let id, let choice, let shares):
            guard let question, question.id == id else { return }
            self.shares = shares
            self.choice = choice
            let word = lines[safe: question.line]?[safe: question.word]?.text ?? ""
            let title: String
            if let letter = question.letter {
                let read = word.isEmpty ? "" : String(Array(word)[min(letter, word.count - 1)])
                title = "letter \(letter + 1) (\(read))"
            } else {
                title = "whole word"
            }
            recent.insert(Summary(id: id, word: word, title: title, picked: question.labels[choice],
                                  share: shares[choice], changed: choice != 0), at: 0)
            if recent.count > 40 { recent.removeLast(recent.count - 40) }

        case .lettersMoved(let line, let word, let text, let letters):
            guard lines.indices.contains(line), lines[line].indices.contains(word) else { return }
            lines[line][word].text = text
            lines[line][word].letters = letters
            lines[line][word].changed = true
            lettersChanged += 1

        case .wordFinished(let line, let word, let text, let confidence):
            guard lines.indices.contains(line), lines[line].indices.contains(word) else { return }
            if lines[line][word].text != text {
                lines[line][word].changed = true
                lines[line][word].letters = LetterSplitter.evenly(text: text, box: lines[line][word].box)
            }
            lines[line][word].text = text
            lines[line][word].confidence = confidence
            wordsDone += 1

        case .finished:
            current = nil
            question = nil
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - The app model's part

extension AppModel {
    var modelFiles: DecisionModelFiles {
        DecisionModelFiles(directory: directory.appendingPathComponent("Models", isDirectory: true))
    }

    public var isModelDownloaded: Bool { modelFiles.isDownloaded }
    public var hasLocalRuntime: Bool { DecisionModelFiles.findRuntime() != nil }
    public var modelDownloadSize: String {
        ByteCountFormatter.string(fromByteCount: DecisionModelFiles.downloadSize, countStyle: .file)
    }

    public var localQueueCount: Int { localQueue.count }

    /// Reads a page with the decision model on this Mac. The photo never leaves it.
    public func readOnThisMac(_ id: UUID) {
        guard vault != nil, !localQueue.contains(id) else { return }
        flushEdits()
        localQueue.append(id)
        try? vault?.setStatus(pageID: id, status: .reading)
        try? reload()
        localWindowRequest += 1
        if localTask == nil {
            localTask = Task { [weak self] in await self?.drainLocalQueue() }
        }
        objectWillChange.send()
    }

    public func showLocalReader() {
        localWindowRequest += 1
    }

    public func stopLocalReading() {
        localTask?.cancel()
        localTask = nil
        for id in localQueue {
            try? vault?.setStatus(pageID: id, status: .waiting)
        }
        localQueue = []
        if localSession?.isActive == true { localSession?.setPhase(.stopped) }
        try? reload()
        scheduleServerStop(after: 0)
    }

    public func downloadModel() {
        guard downloadTask == nil else { return }
        modelDownloadProgress = 0
        let files = modelFiles
        downloadTask = Task { [weak self] in
            do {
                try await files.download { fraction in
                    Task { @MainActor in self?.modelDownloadProgress = fraction }
                }
            } catch is CancellationError {
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.modelDownloadProgress = nil
            self?.downloadTask = nil
            self?.objectWillChange.send()
        }
    }

    public func cancelModelDownload() {
        downloadTask?.cancel()
    }

    /// Called when the journal locks: stops reading and drops everything held in memory.
    func shutDownLocalReading() {
        localTask?.cancel()
        localTask = nil
        localQueue = []
        localSession = nil
        journalVocabulary = nil
        scheduleServerStop(after: 0)
    }

    private func drainLocalQueue() async {
        defer {
            localTask = nil
            objectWillChange.send()
            scheduleServerStop(after: 180)
        }
        serverStopTask?.cancel()
        let server = decisionServer ?? DecisionServer(files: modelFiles)
        decisionServer = server
        let vocabulary = await loadVocabulary()

        while !Task.isCancelled, let id = localQueue.first, let vault {
            let page = page(id: id)
            let jpeg = try? vault.image(pageID: id)
            let session = LocalReadSession(pageID: id, pageNumber: page?.number ?? 0,
                                           journalName: page.map { journalName($0.journalID) } ?? "",
                                           photo: jpeg.flatMap(NSImage.init(data:)), settings: localSettings)
            localSession = session
            do {
                guard let jpeg else { throw VaultError.notFound }
                session.setPhase(.loadingModel)
                try await server.start()
                session.setPhase(.findingWords)
                let reader = LocalReader(server: server, candidates: CandidateMaker(words: vocabulary),
                                         settings: session.settings)
                let result = try await reader.read(jpeg: jpeg) { event in
                    await MainActor.run { session.apply(event) }
                }
                try Task.checkCancellation()
                // The page may have been deleted or replaced while it was being read.
                if localQueue.contains(id) {
                    pendingEdits[id] = nil
                    // Words she fixed in the window while it read.
                    let final = result.applying(session.edits)
                    try vault.saveReading(pageID: id, transcription: LocalReader.transcription(of: final.text,
                                                                                               notes: final.notes))
                    texts[id] = final.text
                }
                session.setPhase(.done)
            } catch is CancellationError {
                session.setPhase(.stopped)
                return
            } catch VaultError.notFound {
                session.setPhase(.failed("This page was deleted."))
            } catch VaultError.locked {
                return
            } catch {
                let message = error.localizedDescription
                session.setPhase(.failed(message))
                try? vault.setStatus(pageID: id, status: .failed, problem: message)
                if error is DecisionModelError {
                    // The model can't run, so the rest of the queue would fail the same way.
                    for other in localQueue where other != id {
                        try? vault.setStatus(pageID: other, status: .waiting)
                    }
                    localQueue = []
                    try? reload()
                    return
                }
            }
            localQueue.removeAll { $0 == id }
            try? reload()
        }
    }

    /// Words on a page that a reading on this Mac changed or wasn't sure of, where they are in its text now.
    public func wordNotes(pageID: UUID) -> [(note: WordNote, range: NSRange)] {
        guard let notes = page(id: pageID)?.structure?.wordNotes, let text = texts[pageID] else { return [] }
        return WordNote.locate(notes, in: text)
    }

    /// Settles a noted word: replaces it, or keeps it as read when `replacement` is nil. Either way its
    /// underline goes away.
    public func resolve(_ note: WordNote, pageID: UUID, replacement: String?) {
        guard let vault, let notes = page(id: pageID)?.structure?.wordNotes else { return }
        if let replacement, let text = texts[pageID], let changed = WordNote.replacing(note, with: replacement, in: text) {
            editText(changed, pageID: pageID)
        }
        do {
            try vault.setWordNotes(pageID: pageID, notes: notes.filter { $0 != note })
            try reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The word list plus every word in her journals, so names and her own words count as real words.
    private func loadVocabulary() async -> Set<String> {
        if let journalVocabulary { return journalVocabulary }
        let pageTexts = Array(texts.values)
        let words = await Task.detached(priority: .userInitiated) {
            CandidateMaker.loadDictionary(extraText: pageTexts)
        }.value
        journalVocabulary = words
        return words
    }

    /// Keeps the model loaded for a while after reading, then frees its memory.
    private func scheduleServerStop(after seconds: Double) {
        serverStopTask?.cancel()
        guard let server = decisionServer else { return }
        serverStopTask = Task { [weak self] in
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            guard !Task.isCancelled, self?.localTask == nil else { return }
            await server.stop()
        }
    }
}
