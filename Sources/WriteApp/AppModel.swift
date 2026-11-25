import AppKit
import CoreGraphics
import SwiftUI
import WriteCore

public enum LibraryMode: String, CaseIterable, Identifiable {
    case pages
    case entries

    public var id: String { rawValue }
    var label: String { self == .pages ? "Pages" : "Entries" }
}

/// All app state. Decrypted content lives here only while the journal is unlocked.
@MainActor
public final class AppModel: ObservableObject {
    public enum Screen: Equatable {
        case create
        case showRecoveryKey(String)
        case chooseNewPassword
        case locked
        case library
    }

    private enum PreferenceKey {
        static let appearance = "appearance"
        static let showPhoto = "showPhoto"
        static let twoPages = "twoPageSpread"
        static let lineBreaks = "accurateLineBreaks"
        static let readsLocally = "readsLocally"
        static let showConfidence = "showConfidence"
        static let localDepth = "localDepth"
        static let localLetterOptions = "localLetterOptions"
    }

    private static let idleLockSeconds: Double = 10 * 60

    @Published public private(set) var screen: Screen
    @Published public private(set) var journals: [JournalInfo] = []
    @Published public private(set) var pages: [PageInfo] = []
    @Published public internal(set) var texts: [UUID: String] = [:]
    @Published public private(set) var entries: [JournalEntry] = []
    @Published public private(set) var contentVersion = 0
    @Published public var selectedJournalID: UUID?
    @Published public var selectedPageID: UUID?
    @Published public var selectedEntryID: String?
    @Published public private(set) var libraryMode: LibraryMode = .pages
    @Published public var showingAnalysis = false
    @Published public var searchText = ""
    /// The words looked up in Analysis, separated by commas; kept while a match's page is open.
    @Published public var analysisTerm = ""
    @Published public var isWorking = false
    @Published public var errorMessage: String?
    @Published public var showUpload = false
    @Published public var showSettings = false
    @Published public private(set) var hasAPIKey = false
    @Published public private(set) var hiddenWords: Set<String> = []
    @Published public var analysisExcludedJournals: Set<UUID> = []
    @Published public var analysisRanges: [UUID: String] = [:]

    @Published public var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: PreferenceKey.appearance)
            NSApplication.shared.appearance = appearance.nsAppearance
        }
    }
    /// The theme color; `Theme.accent` and `Theme.chart` follow it.
    @Published public var accent: AccentChoice {
        didSet {
            AccentChoice.current = accent
            UserDefaults.standard.set(accent.rawValue, forKey: AccentChoice.preferenceKey)
        }
    }
    @Published public var showPhoto: Bool {
        didSet { UserDefaults.standard.set(showPhoto, forKey: PreferenceKey.showPhoto) }
    }
    @Published public var twoPageSpread: Bool {
        didSet { UserDefaults.standard.set(twoPageSpread, forKey: PreferenceKey.twoPages) }
    }
    @Published public var accurateLineBreaks: Bool {
        didSet {
            flushEdits()
            UserDefaults.standard.set(accurateLineBreaks, forKey: PreferenceKey.lineBreaks)
        }
    }

    /// Marks words a reading on this Mac changed or wasn't sure of.
    @Published public var showConfidence: Bool {
        didSet { UserDefaults.standard.set(showConfidence, forKey: PreferenceKey.showConfidence) }
    }

    // Reading on this Mac (see LocalReading.swift).
    @Published public var readsLocally: Bool {
        didSet { UserDefaults.standard.set(readsLocally, forKey: PreferenceKey.readsLocally) }
    }
    @Published public var localSettings: LocalReadSettings {
        didSet {
            UserDefaults.standard.set(localSettings.depth.rawValue, forKey: PreferenceKey.localDepth)
            UserDefaults.standard.set(localSettings.letterOptions, forKey: PreferenceKey.localLetterOptions)
        }
    }
    @Published public internal(set) var localSession: LocalReadSession?
    @Published public internal(set) var modelDownloadProgress: Double?
    /// Bumped to ask the library to open the reading window.
    @Published public internal(set) var localWindowRequest = 0
    var localQueue: [UUID] = []
    var localTask: Task<Void, Never>?
    var downloadTask: Task<Void, Never>?
    var decisionServer: DecisionServer?
    var serverStopTask: Task<Void, Never>?
    var journalVocabulary: Set<String>?

    let directory: URL
    var vault: Vault?
    private var apiKey: String?
    private var readQueue: [UUID] = []
    private var readerTask: Task<Void, Never>?
    var pendingEdits: [UUID: String] = [:]
    /// The marked word last clicked in a page's text, outlined on its photo.
    @Published public var focusedWord: FocusedWord?

    public struct FocusedWord: Equatable {
        public let pageID: UUID
        public let note: WordNote
    }

    public func focusWord(_ note: WordNote?, pageID: UUID) {
        let next = note.map { FocusedWord(pageID: pageID, note: $0) }
        if focusedWord != next { focusedWord = next }
    }

    /// Pages with a reading on this Mac saved partway.
    @Published public internal(set) var pagesWithProgress: Set<UUID> = []
    private var editSaveTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var idleTimer: Timer?

    public init(directory: URL) {
        self.directory = directory
        screen = Vault.exists(in: directory) ? .locked : .create
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: PreferenceKey.appearance).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        appearance = mode
        accent = AccentChoice.current
        showPhoto = defaults.object(forKey: PreferenceKey.showPhoto) as? Bool ?? false
        twoPageSpread = defaults.bool(forKey: PreferenceKey.twoPages)
        accurateLineBreaks = defaults.object(forKey: PreferenceKey.lineBreaks) as? Bool ?? true
        readsLocally = defaults.bool(forKey: PreferenceKey.readsLocally)
        showConfidence = defaults.object(forKey: PreferenceKey.showConfidence) as? Bool ?? true
        let depth = defaults.string(forKey: PreferenceKey.localDepth).flatMap(LocalReadDepth.init(rawValue:)) ?? .quick
        let letterOptions = defaults.object(forKey: PreferenceKey.localLetterOptions) as? Int ?? 6
        localSettings = LocalReadSettings(depth: depth, letterOptions: min(max(letterOptions, 2), 10))
        NSApplication.shared.appearance = mode.nsAppearance
        observeLockEvents()
    }

    // MARK: - Unlocking

    public func createVault(password: String) async {
        await perform {
            let directory = self.directory
            let result = try await Task.detached { try Vault.create(in: directory, password: password) }.value
            self.vault = result.vault
            self.screen = .showRecoveryKey(result.recoveryKey)
        }
    }

    public func confirmRecoveryKeySaved() {
        guard vault != nil else { return }
        enterLibrary()
        showSettings = !hasAPIKey
    }

    public func unlock(password: String) async {
        await perform {
            let directory = self.directory
            self.vault = try await Task.detached { try Vault.unlock(in: directory, password: password) }.value
            self.enterLibrary()
        }
    }

    public func unlock(recoveryKey: String) async {
        await perform {
            let directory = self.directory
            self.vault = try await Task.detached { try Vault.unlock(in: directory, recoveryKey: recoveryKey) }.value
            self.screen = .chooseNewPassword
        }
    }

    public func setNewPassword(_ password: String) async -> Bool {
        guard let vault else { return false }
        var succeeded = false
        await perform {
            try await Task.detached { try vault.changePassword(to: password) }.value
            succeeded = true
            if self.screen == .chooseNewPassword { self.enterLibrary() }
        }
        return succeeded
    }

    public func lock() {
        // The recovery key is shown only once, so sleep must not dismiss it.
        if case .showRecoveryKey = screen { return }
        flushEdits()
        readerTask?.cancel()
        readerTask = nil
        readQueue = []
        shutDownLocalReading()
        if let vault, pages.contains(where: { $0.status == .reading }) {
            for page in pages where page.status == .reading {
                try? vault.setStatus(pageID: page.id, status: .waiting)
            }
        }
        vault?.lock()
        vault = nil
        apiKey = nil
        hasAPIKey = false
        hiddenWords = []
        journals = []
        pages = []
        texts = [:]
        pagesWithProgress = []
        focusedWord = nil
        entries = []
        selectedJournalID = nil
        selectedPageID = nil
        selectedEntryID = nil
        libraryMode = .pages
        showingAnalysis = false
        analysisExcludedJournals = []
        analysisRanges = [:]
        searchText = ""
        showUpload = false
        showSettings = false
        errorMessage = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if screen != .create { screen = .locked }
    }

    /// Saves unsaved edits before the app quits.
    public func prepareToQuit() {
        lock()
        decisionServer?.terminateNow()
    }

    private func enterLibrary() {
        guard let vault else { return }
        do {
            for page in try vault.pages() where page.status == .reading {
                try vault.setStatus(pageID: page.id, status: .waiting)
            }
            apiKey = try vault.apiKey()
            hasAPIKey = apiKey != nil
            hiddenWords = try vault.hiddenWords()
            let loaded = try vault.pages()
            texts = Dictionary(uniqueKeysWithValues: try loaded.map { ($0.id, try vault.text(pageID: $0.id)) })
            try reload()
            selectedJournalID = selectedJournalID ?? journals.first?.id
            screen = .library
            startIdleTimer()
        } catch {
            errorMessage = error.localizedDescription
            vault.lock()
            self.vault = nil
            screen = .locked
        }
    }

    // MARK: - Journals

    @discardableResult
    public func createJournal(name: String) -> JournalInfo? {
        guard let vault else { return nil }
        do {
            let journal = try vault.createJournal(name: name)
            try reload()
            selectedJournalID = journal.id
            return journal
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func renameJournal(id: UUID, to name: String) {
        attempt { try $0.renameJournal(id: id, to: name) }
    }

    public func deleteJournal(id: UUID) {
        guard let vault else { return }
        do {
            let removed = pages.filter { $0.journalID == id }.map(\.id)
            readQueue.removeAll(where: removed.contains)
            localQueue.removeAll(where: removed.contains)
            removed.forEach {
                texts[$0] = nil
                pendingEdits[$0] = nil
            }
            try vault.deleteJournal(id: id)
            if let selectedPageID, removed.contains(selectedPageID) { self.selectedPageID = nil }
            analysisExcludedJournals.remove(id)
            analysisRanges[id] = nil
            try reload()
            if selectedJournalID == id { selectedJournalID = journals.first?.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func selectJournal(_ id: UUID) {
        showingAnalysis = false
        guard selectedJournalID != id else { return }
        selectedJournalID = id
        if selectedPage?.journalID != id { selectedPageID = nil }
        if selectedEntry?.journalID != id { selectedEntryID = nil }
    }

    // MARK: - Pages and entries

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func matchesSearch(_ text: String) -> Bool {
        text.range(of: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                   options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    public var visiblePages: [PageInfo] {
        guard isSearching else { return pages.filter { $0.journalID == selectedJournalID } }
        return pages.filter { matchesSearch(texts[$0.id] ?? "") }
    }

    public var visibleEntries: [JournalEntry] {
        guard isSearching else { return entries.filter { $0.journalID == selectedJournalID } }
        return entries.filter { matchesSearch($0.bodyText) || matchesSearch($0.heading ?? "") }
    }

    public var selectedPage: PageInfo? {
        pages.first { $0.id == selectedPageID }
    }

    public var selectedEntry: JournalEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    public var waitingCount: Int {
        pages.filter { $0.status == .waiting || $0.status == .failed }.count
    }

    public func journalName(_ id: UUID) -> String {
        journals.first { $0.id == id }?.name ?? "Journal"
    }

    public func page(id: UUID) -> PageInfo? {
        pages.first { $0.id == id }
    }

    /// Switches views and keeps her place: the entry on this page, or the page of this entry.
    public func setLibraryMode(_ mode: LibraryMode) {
        guard mode != libraryMode else { return }
        flushEdits()
        if mode == .entries, let selectedPageID {
            selectedEntryID = entries.first { $0.parts.contains { $0.pageID == selectedPageID } }?.id
        } else if mode == .pages, let entry = selectedEntry {
            selectedPageID = entry.parts.first?.pageID
        }
        libraryMode = mode
    }

    public func openPage(_ id: UUID) {
        guard let page = page(id: id) else { return }
        flushEdits()
        showingAnalysis = false
        selectedJournalID = page.journalID
        selectedPageID = id
        libraryMode = .pages
    }

    private func journalPages(of page: PageInfo) -> [PageInfo] {
        pages.filter { $0.journalID == page.journalID }.sorted { $0.number < $1.number }
    }

    /// The selected page, plus the page after it when two-page view is on.
    public var spreadPages: [PageInfo] {
        guard let page = selectedPage else { return [] }
        guard twoPageSpread else { return [page] }
        let list = journalPages(of: page)
        guard let index = list.firstIndex(where: { $0.id == page.id }) else { return [page] }
        return Array(list[index..<min(index + 2, list.count)])
    }

    public var canFlipBack: Bool { flipTarget(-1) != nil }
    public var canFlipForward: Bool { flipTarget(1) != nil }

    public func flip(_ direction: Int) {
        guard let target = flipTarget(direction) else { return }
        flushEdits()
        switch libraryMode {
        case .pages: selectedPageID = UUID(uuidString: target)
        case .entries: selectedEntryID = target
        }
    }

    private func flipTarget(_ direction: Int) -> String? {
        switch libraryMode {
        case .pages:
            guard let page = selectedPage else { return nil }
            let list = journalPages(of: page)
            guard let index = list.firstIndex(where: { $0.id == page.id }) else { return nil }
            let step = twoPageSpread ? 2 : 1
            let target = direction > 0 ? index + step : max(index - step, 0)
            guard target != index, list.indices.contains(target) else { return nil }
            return list[target].id.uuidString
        case .entries:
            guard let entry = selectedEntry else { return nil }
            let list = entries.filter { $0.journalID == entry.journalID }
            guard let index = list.firstIndex(where: { $0.id == entry.id }) else { return nil }
            let target = index + direction
            return list.indices.contains(target) ? list[target].id : nil
        }
    }

    public func nextPageNumber(in journalID: UUID) -> Int {
        let used = Set(pages.filter { $0.journalID == journalID }.map(\.number))
        var number = (used.max() ?? 0) + 1
        if number > Vault.maximumPageNumber {
            number = 1
            while used.contains(number) && number < Vault.maximumPageNumber { number += 1 }
        }
        return number
    }

    public func isPageTaken(journalID: UUID, number: Int) -> Bool {
        pages.contains { $0.journalID == journalID && $0.number == number }
    }

    /// Saves the encrypted photo first, then queues it to be read.
    @discardableResult
    public func addPage(journalID: UUID, number: Int, jpeg: Data, replacing: Bool, readLocally: Bool = false) -> Bool {
        guard let vault else { return false }
        do {
            let replaced = pages.first { $0.journalID == journalID && $0.number == number }
            let page = try vault.addPage(journalID: journalID, number: number, jpeg: jpeg, replacing: replacing)
            if let replaced {
                readQueue.removeAll { $0 == replaced.id }
                localQueue.removeAll { $0 == replaced.id }
                texts[replaced.id] = nil
                pendingEdits[replaced.id] = nil
                if selectedPageID == replaced.id { selectedPageID = page.id }
            }
            texts[page.id] = ""
            try reload()
            selectedJournalID = journalID
            if readLocally { readOnThisMac(page.id, announce: false) } else { enqueue(page.id) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func image(for id: UUID) -> NSImage? {
        guard let data = try? vault?.image(pageID: id) else { return nil }
        return NSImage(data: data)
    }

    /// The page text with handwritten line wraps joined, for when line breaks are off.
    public func reflowedText(pageID: UUID) -> String {
        flowed(pageID: pageID).text
    }

    func flowed(pageID: UUID) -> LineFlow.Flowed {
        let text = texts[pageID] ?? ""
        let headings = EntryBuilder.headings(in: text, structure: page(id: pageID)?.structure)
        return LineFlow.mapped(text, headingLines: Set(headings.map(\.line)))
    }

    /// An edit made with line breaks off, carried over to the text as written, so her line breaks stay.
    public func editReflowed(_ edited: String, pageID: UUID) {
        let written = texts[pageID] ?? ""
        let flow = flowed(pageID: pageID)
        guard edited != flow.text else { return }
        editText(flow.applying(edited, to: written), pageID: pageID)
    }

    /// Noted words located in the flowing text, for marking them with line breaks off.
    public func reflowedWordNotes(pageID: UUID) -> [(note: WordNote, range: NSRange)] {
        let flow = flowed(pageID: pageID)
        return wordNotes(pageID: pageID).compactMap { item in flow.flowedRange(for: item.range).map { (item.note, $0) } }
    }

    public func editText(_ text: String, pageID: UUID) {
        texts[pageID] = text
        pendingEdits[pageID] = text
        editSaveTask?.cancel()
        editSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flushEdits()
        }
    }

    /// Sets an entry's date, and time if given, by rewriting its date line, or adding one, on its first page.
    public func setDate(of entry: JournalEntry, year: Int, month: Int, day: Int, hour: Int?, minute: Int) {
        guard let part = entry.parts.first, let text = texts[part.pageID] else { return }
        let line = EntryBuilder.headingLine(year: year, month: month, day: day, hour: hour, minute: minute)
        editText(EntryBuilder.settingHeading(line, of: part, in: text), pageID: part.pageID)
        flushEdits()
        selectedEntryID = entries.first { $0.parts.first?.pageID == part.pageID && $0.heading == line }?.id ?? selectedEntryID
    }

    public func flushEdits() {
        editSaveTask?.cancel()
        editSaveTask = nil
        guard let vault, !pendingEdits.isEmpty else { return }
        for (id, text) in pendingEdits {
            do {
                try vault.setText(pageID: id, text: text)
                pendingEdits[id] = nil
            } catch VaultError.notFound {
                pendingEdits[id] = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        try? reload()
    }

    public func movePage(id: UUID, toJournal journalID: UUID, number: Int) -> Bool {
        guard let vault else { return false }
        do {
            try vault.movePage(id: id, toJournal: journalID, number: number)
            try reload()
            selectedJournalID = journalID
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func deletePage(id: UUID) {
        guard let vault else { return }
        do {
            readQueue.removeAll { $0 == id }
            localQueue.removeAll { $0 == id }
            pendingEdits[id] = nil
            try vault.deletePage(id: id)
            texts[id] = nil
            if selectedPageID == id { selectedPageID = nil }
            try reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func readAgain(_ id: UUID) {
        flushEdits()
        enqueue(id)
    }

    public func readAllWaiting() {
        pages.filter { $0.status == .waiting || $0.status == .failed }.forEach { enqueue($0.id) }
    }

    // MARK: - Analysis

    /// Finished pages read before names and entry dates were extracted.
    public var pagesMissingNames: [PageInfo] {
        pages.filter { $0.status == .done && $0.structure == nil }
    }

    public func readPagesMissingNames() {
        flushEdits()
        pagesMissingNames.forEach { enqueue($0.id) }
    }

    public func isRangeValid(journalID: UUID) -> Bool {
        PageSelection.parse(analysisRanges[journalID] ?? "") != nil
    }

    public var analysisPageIDs: Set<UUID> {
        var included = Set<UUID>()
        for journal in journals where !analysisExcludedJournals.contains(journal.id) {
            guard let selection = PageSelection.parse(analysisRanges[journal.id] ?? "") else { continue }
            for page in pages where page.journalID == journal.id && selection.contains(page.number) {
                included.insert(page.id)
            }
        }
        return included
    }

    public func makeAnalysisSnapshot() async -> AnalysisSnapshot {
        let entries = entries
        let included = analysisPageIDs
        let names = pages.filter { included.contains($0.id) }.flatMap { $0.structure?.names ?? [] }
        let journalNames = Dictionary(uniqueKeysWithValues: journals.map { ($0.id, $0.name) })
        return await Task.detached(priority: .userInitiated) {
            AnalysisSnapshot(entries: entries, includedPages: included, names: names, journalNames: journalNames)
        }.value
    }

    public func hideWord(_ key: String) {
        updateHiddenWords { $0.insert(key) }
    }

    public func unhideWord(_ key: String) {
        updateHiddenWords { $0.remove(key) }
    }

    public func unhideAllWords() {
        updateHiddenWords { $0.removeAll() }
    }

    private func updateHiddenWords(_ change: (inout Set<String>) -> Void) {
        guard let vault else { return }
        var updated = hiddenWords
        change(&updated)
        do {
            try vault.setHiddenWords(updated)
            hiddenWords = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Reading

    private func enqueue(_ id: UUID) {
        guard hasAPIKey else {
            try? vault?.setStatus(pageID: id, status: .waiting, problem: TranscriberError.missingKey.errorDescription)
            try? reload()
            return
        }
        guard !readQueue.contains(id) else { return }
        readQueue.append(id)
        try? vault?.setStatus(pageID: id, status: .reading)
        try? reload()
        if readerTask == nil {
            readerTask = Task { [weak self] in await self?.drainQueue() }
        }
    }

    private func drainQueue() async {
        while !Task.isCancelled, let id = readQueue.first, let vault, let apiKey {
            do {
                let jpeg = try vault.image(pageID: id)
                let result = try await Transcriber(apiKey: apiKey).transcribe(jpeg: jpeg)
                try Task.checkCancellation()
                // The page may have been deleted or replaced while it was being read.
                if readQueue.contains(id) {
                    pendingEdits[id] = nil
                    try vault.saveReading(pageID: id, transcription: result)
                    texts[id] = result.text
                }
            } catch is CancellationError {
                return
            } catch VaultError.notFound {
                // Deleted while it was being read.
            } catch VaultError.locked {
                return
            } catch {
                try? vault.setStatus(pageID: id, status: .failed, problem: error.localizedDescription)
            }
            readQueue.removeAll { $0 == id }
            try? reload()
        }
        readerTask = nil
    }

    // MARK: - Settings

    /// Verifies the key with Anthropic. Network trouble doesn't block saving a well-formed key.
    public func saveAPIKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let vault, !trimmed.isEmpty else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await Transcriber(apiKey: trimmed).verifyKey()
        } catch TranscriberError.invalidKey {
            errorMessage = TranscriberError.invalidKey.errorDescription
            return false
        } catch {
            // The key is checked again when the next page is read.
        }
        do {
            try vault.setAPIKey(trimmed)
            apiKey = trimmed
            hasAPIKey = true
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func removeAPIKey() {
        guard let vault else { return }
        do {
            try vault.setAPIKey(nil)
            apiKey = nil
            hasAPIKey = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    func reload() throws {
        guard let vault else { return }
        journals = try vault.journals()
        pages = try vault.pages()
        pagesWithProgress = (try? vault.pagesWithProgress()) ?? []
        let currentTexts = texts
        entries = EntryBuilder.build(pages: pages, journalOrder: journals.map(\.id)) { currentTexts[$0] ?? "" }
        if let selectedEntryID, !entries.contains(where: { $0.id == selectedEntryID }) {
            self.selectedEntryID = nil
        }
        contentVersion += 1
    }

    private func attempt(_ body: (Vault) throws -> Void) {
        guard let vault else { return }
        do {
            try body(vault)
            try reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ body: @escaping () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await body()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func observeLockEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let lockNow: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockNow
        )))
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockNow
        )))
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.readQueue.isEmpty, let anyInput = CGEventType(rawValue: UInt32.max) else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
                if idle >= Self.idleLockSeconds { self.lock() }
            }
        }
    }
}
