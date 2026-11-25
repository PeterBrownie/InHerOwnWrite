import AppKit
import SwiftUI
import WriteCore

public struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updater: Updater
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        NavigationSplitView {
            JournalSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            Group {
                if model.showingAnalysis {
                    AnalysisScopeColumn()
                } else {
                    LibraryColumn()
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            Group {
                if model.showingAnalysis {
                    AnalysisDetail()
                } else if model.libraryMode == .entries, let entry = model.selectedEntry {
                    EntryReader(entry: entry).id(entry.id)
                } else if model.libraryMode == .pages, model.selectedPage != nil {
                    PageReader()
                } else {
                    EmptyDetail()
                }
            }
            // Inside the detail column, below its toolbar, so it stays clear of the sidebar.
            .safeAreaInset(edge: .top, spacing: 0) {
                if updater.showsBanner { UpdateBanner(updater: updater) }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search for a word or phrase")
        .onChange(of: model.searchText) { _, text in
            if !text.isEmpty { model.showingAnalysis = false }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showUpload = true } label: {
                    Label("Add Page", systemImage: "plus")
                }
                .help("Add a page")
                Button { model.showLocalReader() } label: {
                    Label("Reading on This Mac", systemImage: "cpu")
                }
                .help("Watch pages being read on this Mac")
                Button { model.showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
                Button { model.lock() } label: {
                    Label("Lock", systemImage: "lock")
                }
                .help("Lock journal")
            }
        }
        .onChange(of: model.localWindowRequest) {
            openWindow(id: "local-reader")
        }
        .sheet(isPresented: $model.showUpload) {
            UploadSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet().environmentObject(model)
        }
    }
}

private enum SidebarItem: Hashable {
    case analysis
    case journal(UUID)
}

private struct JournalSidebar: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var isNaming = false
    @ViewState private var name = ""
    @ViewState private var renaming: JournalInfo?
    @ViewState private var deleting: JournalInfo?

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if model.showingAnalysis { return .analysis }
                return model.selectedJournalID.map(SidebarItem.journal)
            },
            set: { item in
                switch item {
                case .analysis: model.showingAnalysis = true
                case .journal(let id): model.selectJournal(id)
                case nil: break
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Label("Analysis", systemImage: "chart.bar.xaxis")
                .tag(SidebarItem.analysis)

            Section("Journals") {
                ForEach(model.journals) { journal in
                    HStack {
                        Label(journal.name, systemImage: "book.closed")
                            .lineLimit(1)
                        Spacer()
                        Text("\(model.pages.filter { $0.journalID == journal.id }.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .tag(SidebarItem.journal(journal.id))
                    .contextMenu {
                        Button("Rename…") {
                            name = journal.name
                            renaming = journal
                        }
                        Button("Delete…", role: .destructive) { deleting = journal }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                name = ""
                isNaming = true
            } label: {
                Label("New Journal", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .alert("New Journal", isPresented: $isNaming) {
            TextField("Name", text: $name)
            Button("Create") {
                if let journal = model.createJournal(name: name) { model.selectJournal(journal.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Journal", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") {
                if let renaming { model.renameJournal(id: renaming.id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")” and all its pages?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Journal", role: .destructive) {
                if let deleting { model.deleteJournal(id: deleting.id) }
            }
        } message: {
            Text("This can't be undone.")
        }
    }
}

/// The middle column: browse the selected journal by page or by entry.
private struct LibraryColumn: View {
    @EnvironmentObject private var model: AppModel

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var title: String {
        if isSearching { return "Results" }
        return model.selectedJournalID.map(model.journalName) ?? "Pages"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View by", selection: Binding(get: { model.libraryMode }, set: model.setLibraryMode)) {
                ForEach(LibraryMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if model.libraryMode == .entries {
                EntryListControls()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            switch model.libraryMode {
            case .pages: PageList(isSearching: isSearching)
            case .entries: EntryList(isSearching: isSearching)
            }
        }
        .navigationTitle(title)
        .safeAreaInset(edge: .bottom) {
            if model.waitingCount > 0 && model.hasAPIKey {
                Button("Read \(model.waitingCount) Waiting \(model.waitingCount == 1 ? "Page" : "Pages")") {
                    model.readAllWaiting()
                }
                .padding(10)
            }
        }
    }
}

private struct PageList: View {
    @EnvironmentObject private var model: AppModel
    let isSearching: Bool

    var body: some View {
        if model.visiblePages.isEmpty {
            ContentUnavailableView {
                Label(isSearching ? "No matches" : "No pages yet",
                      systemImage: isSearching ? "magnifyingglass" : "doc.text")
            } description: {
                Text(isSearching ? "Nothing in your journals matches that." : "Add a photo of a page to begin.")
            } actions: {
                if !isSearching {
                    Button("Add Page") { model.showUpload = true }
                }
            }
        } else {
            List(model.visiblePages, selection: $model.selectedPageID) { page in
                PageRow(page: page, showJournal: isSearching).tag(page.id)
            }
        }
    }
}

/// Sorting the entries, and showing only starred ones.
private struct EntryListControls: View {
    @EnvironmentObject private var model: AppModel

    private func label(_ sort: EntrySort) -> String {
        sort == .date ? "Date" : "Length"
    }

    private func direction(_ sort: EntrySort, ascending: Bool) -> String {
        switch sort {
        case .date: return ascending ? "Oldest First" : "Newest First"
        case .length: return ascending ? "Shortest First" : "Longest First"
        }
    }

    var body: some View {
        HStack {
            Menu {
                Picker("Sort By", selection: $model.entrySort) {
                    ForEach(EntrySort.allCases) { Text(label($0)).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Order", selection: $model.entrySortAscending) {
                    Text(direction(model.entrySort, ascending: true)).tag(true)
                    Text(direction(model.entrySort, ascending: false)).tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label("\(label(model.entrySort)), \(direction(model.entrySort, ascending: model.entrySortAscending))",
                      systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort entries")

            Spacer()

            Toggle(isOn: $model.showsStarredOnly) {
                Label("Starred", systemImage: model.showsStarredOnly ? "star.fill" : "star")
            }
            .toggleStyle(.button)
            .help(model.showsStarredOnly ? "Show all entries" : "Show only starred entries, from every journal")
        }
        .font(.callout)
        .controlSize(.small)
    }
}

private struct EntryList: View {
    @EnvironmentObject private var model: AppModel
    let isSearching: Bool

    var body: some View {
        if model.visibleEntries.isEmpty {
            if model.showsStarredOnly {
                ContentUnavailableView {
                    Label(isSearching ? "No matches" : "No starred entries", systemImage: "star")
                } description: {
                    Text(isSearching ? "None of your starred entries matches that."
                         : "Star an entry to keep it here. Starred entries from every journal are listed together.")
                }
            } else {
                ContentUnavailableView {
                    Label(isSearching ? "No matches" : "No entries yet",
                          systemImage: isSearching ? "magnifyingglass" : "calendar")
                } description: {
                    Text(isSearching ? "Nothing in your entries matches that." : "Entries appear once pages have been read.")
                }
            }
        } else {
            List(model.visibleEntries, selection: $model.selectedEntryID) { entry in
                EntryRow(entry: entry, showJournal: isSearching || (model.showsStarredOnly && model.journals.count > 1))
                    .tag(entry.id)
            }
        }
    }
}

/// Merging a continued entry into the one before, or splitting a merged one again.
private struct EntryJoinActions: View {
    @EnvironmentObject private var model: AppModel
    let entry: JournalEntry

    var body: some View {
        if model.canMergeWithPrevious(entry) {
            Button("Merge with Previous Entry") { model.mergeWithPrevious(entry) }
        }
        ForEach(model.joinedParts(of: entry)) { part in
            Button("Split at Page \(part.pageNumber)") { model.split(entry, at: part) }
        }
    }
}

private struct EntryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: JournalEntry
    let showJournal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.isStarred(entry) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .help("Starred")
                }
                if model.canMergeWithPrevious(entry) || !model.joinedParts(of: entry).isEmpty {
                    Menu {
                        EntryJoinActions(entry: entry)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                }
            }
            HStack(spacing: 6) {
                if let time = entry.timeLabel { Text(time) }
                Text(entry.pageLabel)
                if model.entrySort == .length {
                    let words = model.wordCount(of: entry)
                    Text("\(words) \(words == 1 ? "word" : "words")")
                }
                if showJournal { Text(model.journalName(entry.journalID)).lineLimit(1) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(entry.bodyText.replacingOccurrences(of: "\n", with: " "))
                .font(.system(.callout, design: .serif))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(model.isStarred(entry) ? "Remove Star" : "Star") { model.toggleStar(entry) }
            EntryJoinActions(entry: entry)
        }
    }
}

private struct PageRow: View {
    @EnvironmentObject private var model: AppModel
    let page: PageInfo
    let showJournal: Bool

    private var preview: String {
        let text = (model.texts[page.id] ?? "").replacingOccurrences(of: "\n", with: " ")
        if !text.isEmpty { return text }
        switch page.status {
        case .reading: return "Reading…"
        case .failed: return "Couldn't read this page"
        default: return "Waiting to be read"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Page \(page.number)").fontWeight(.semibold)
                if showJournal {
                    Text(model.journalName(page.journalID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                StatusIcon(status: page.status)
            }
            Text(preview)
                .font(.system(.callout, design: .serif))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }
}

private struct StatusIcon: View {
    let status: ReadingStatus

    var body: some View {
        switch status {
        case .done: EmptyView()
        case .reading: ProgressView().controlSize(.mini)
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary).help("Waiting to be read")
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.highlight).help("Couldn't be read")
        }
    }
}

private struct EmptyDetail: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label(model.libraryMode == .pages ? "Choose a page" : "Choose an entry", systemImage: "book")
        } description: {
            Text(model.libraryMode == .pages
                 ? "Its photo and text will appear here, side by side."
                 : "It will appear here, even when it runs across several pages.")
        } actions: {
            Button("Add Page") { model.showUpload = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card.ignoresSafeArea())
    }
}

struct MovePageSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let page: PageInfo
    @ViewState private var journalID = UUID()
    @ViewState private var numberText = ""

    init(page: PageInfo) {
        self.page = page
        _journalID = ViewState(wrappedValue: page.journalID)
        _numberText = ViewState(wrappedValue: String(page.number))
    }

    private var number: Int? {
        Int(numberText).flatMap { (1...Vault.maximumPageNumber).contains($0) ? $0 : nil }
    }

    private var isTaken: Bool {
        guard let number, !(journalID == page.journalID && number == page.number) else { return false }
        return model.isPageTaken(journalID: journalID, number: number)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move Page").font(.title2.weight(.semibold))
            Form {
                Picker("Journal", selection: $journalID) {
                    ForEach(model.journals) { Text($0.name).tag($0.id) }
                }
                TextField("Page number", text: $numberText)
            }
            if isTaken {
                Label("That page number is already used.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.highlight)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Move") {
                    if let number, model.movePage(id: page.id, toJournal: journalID, number: number) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(number == nil || isTaken)
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}
