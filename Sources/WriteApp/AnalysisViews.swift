import AppKit
import SwiftUI
import WriteCore

/// The middle column in Analysis: which journals and pages to include.
public struct AnalysisScopeColumn: View {
    @EnvironmentObject private var model: AppModel

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Include")
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                if model.journals.isEmpty {
                    Text("Add a journal to begin.").foregroundStyle(.secondary)
                }
                ForEach(model.journals) { journal in
                    JournalScopeRow(journal: journal)
                }
                Text("Leave pages blank to include them all, or type a list like 1-40, 52, 60-")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .navigationTitle("Analysis")
    }
}

private struct JournalScopeRow: View {
    @EnvironmentObject private var model: AppModel
    let journal: JournalInfo

    private var isIncluded: Binding<Bool> {
        Binding(
            get: { !model.analysisExcludedJournals.contains(journal.id) },
            set: { included in
                if included {
                    model.analysisExcludedJournals.remove(journal.id)
                } else {
                    model.analysisExcludedJournals.insert(journal.id)
                }
            }
        )
    }

    private var range: Binding<String> {
        Binding(
            get: { model.analysisRanges[journal.id] ?? "" },
            set: { model.analysisRanges[journal.id] = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isIncluded) {
                HStack {
                    Text(journal.name).lineLimit(1)
                    Spacer()
                    Text("\(model.pages.filter { $0.journalID == journal.id }.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .toggleStyle(.checkbox)
            TextField("All pages", text: range)
                .textFieldStyle(.roundedBorder)
                .disabled(!isIncluded.wrappedValue)
            if !model.isRangeValid(journalID: journal.id) {
                Label("Try a list like 1-40, 52", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.highlight)
            }
        }
    }
}

private struct SnapshotKey: Hashable {
    let version: Int
    let pages: Set<UUID>
}

public struct AnalysisDetail: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var snapshot: AnalysisSnapshot?
    @ViewState private var results: [TermResult] = []
    @ViewState private var matches: [[TermMatch]] = []
    @ViewState private var showAllMatches = false
    @ViewState private var axis = TimelineAxis.date
    @ViewState private var includeCommon = false
    @ViewState private var showAllWords = false
    @ViewState private var showHidden = false
    @ViewState private var showTable = false
    @ViewState private var confirmRead = false
    @ViewState private var rhythm: EntryRhythm?
    @ViewState private var byWeek = false
    /// The stat whose history is shown under the Entries tiles, if one was clicked.
    @ViewState private var trend: StatTrend?
    /// The name being renamed on every page, if Rename was clicked.
    @ViewState private var renaming: WordStat?

    private static let wordLimit = 40

    public init() {}

    /// Opens with one stat's history showing, for the rendered screenshots.
    public init(showingTrend: StatTrend) {
        _trend = ViewState(wrappedValue: showingTrend)
    }

    /// What's typed in the search field but not looked up yet: the lookup waits until typing pauses for a
    /// second (or Return), since redrawing the charts at every key press lags.
    @ViewState private var typed: String?

    private var term: String {
        get { model.analysisTerm }
        nonmutating set {
            typed = nil
            model.analysisTerm = newValue
        }
    }

    /// Looks up what's typed now, without waiting.
    private func applyTyped() {
        guard let typed else { return }
        term = typed
    }

    private func lookUp(_ text: String) {
        guard let snapshot else { results = []; matches = []; return }
        let parts = AnalysisSnapshot.splitTerms(text)
        results = parts.compactMap { snapshot.term($0) }
        matches = parts.map { snapshot.matches($0) }
        showAllMatches = false
    }

    /// A plain click looks a word up; Command-click adds it to the words being compared.
    private func select(_ word: String) {
        let current = AnalysisSnapshot.splitTerms(term)
        if NSEvent.modifierFlags.contains(.command), !current.isEmpty {
            if let index = current.firstIndex(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                term = current.enumerated().filter { $0.offset != index }.map(\.element).joined(separator: ", ")
            } else {
                term = (current + [word]).joined(separator: ", ")
            }
        } else {
            term = word
        }
    }

    /// The words being looked up, by key, in the colors the charts above give them, so the lists can mark them.
    private var chosenColors: [String: Color] {
        let keys = AnalysisSnapshot.splitTerms(term)
            .map { WordTokenizer.tokens(in: $0).map(\.key).joined(separator: " ") }
            .filter { !$0.isEmpty }
        var colors: [String: Color] = [:]
        for (index, key) in keys.enumerated() where colors[key] == nil {
            colors[key] = keys.count > 1 ? Theme.series(index) : Theme.accent
        }
        return colors
    }

    private var key: SnapshotKey {
        SnapshotKey(version: model.contentVersion, pages: model.analysisPageIDs)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let missing = missingNamesNotice { missing }
                termSection
                if let rhythm, rhythm.entryCount > 0 {
                    entriesSection(rhythm)
                }
                if let snapshot {
                    HStack(alignment: .top, spacing: 24) {
                        wordsSection(snapshot)
                        namesSection(snapshot)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card.ignoresSafeArea())
        .task(id: key) {
            let made = await model.makeAnalysisSnapshot()
            guard !Task.isCancelled else { return }
            snapshot = made
            rhythm = made.entryRhythm()
            lookUp(term)
        }
        .onChange(of: model.analysisTerm) { _, value in
            lookUp(value)
        }
        .sheet(item: $renaming) { name in
            RenamePersonSheet(label: name.display) { newName in
                // A lookup of the old name follows it to the new one.
                let parts = AnalysisSnapshot.splitTerms(term)
                if parts.contains(where: { PeopleDirectory.key($0) == name.key }) {
                    term = parts.map { PeopleDirectory.key($0) == name.key ? newName : $0 }.joined(separator: ", ")
                }
            }
            .environmentObject(model)
        }
        .confirmationDialog(
            "Read \(model.pagesMissingNames.count) older pages again?",
            isPresented: $confirmRead,
            titleVisibility: .visible
        ) {
            Button("Read Pages") { model.readPagesMissingNames() }
        } message: {
            Text("Their photos are sent to Anthropic again, and the new text replaces the current text, including your edits.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Analysis")
                .font(.system(size: 28, weight: .semibold, design: .serif))
            if let snapshot {
                Text("\(snapshot.wordTotal.formatted()) words · \(count(snapshot.pageCount, "page")) · \(count(snapshot.entryCount, "entry", "entries"))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var missingNamesNotice: AnyView? {
        let count = model.pagesMissingNames.count
        guard count > 0 else { return nil }
        return AnyView(
            HStack {
                Label("\(self.count(count, "page")) read before names were added.", systemImage: "info.circle")
                Spacer()
                Button("Read Again with Claude…") { confirmRead = true }
                    .disabled(!model.hasAPIKey)
            }
            .font(.callout)
            .padding(10)
            .background(Theme.notice, in: RoundedRectangle(cornerRadius: 8))
        )
    }

    // MARK: - Word or name lookup

    private var termSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a word, name, or phrase; separate several with commas",
                          text: Binding(get: { typed ?? term }, set: { typed = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .onSubmit { applyTyped() }
                    .task(id: typed) {
                        guard let typed, typed != term else { return }
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, self.typed == typed else { return }
                        applyTyped()
                    }
                if !(typed ?? term).isEmpty {
                    Button { term = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear")
                }
            }
            .padding(10)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))

            if !results.isEmpty {
                termResult(results)
            }
        }
    }

    private func termResult(_ results: [TermResult]) -> some View {
        let series = results.enumerated().map { index, result in
            TimelineSeries(name: result.display, color: Theme.series(index),
                           bins: axis == .date ? result.byDate : result.byPage)
        }
        let bins = series.first?.bins ?? []
        let total = results.reduce(0) { $0 + $1.total }
        let undated = results.reduce(0) { $0 + $1.undatedMentions }
        return VStack(alignment: .leading, spacing: 12) {
            if results.count == 1, let result = results.first {
                HStack(spacing: 28) {
                    StatTile(label: "Mentions of “\(result.display)”", value: result.total)
                    StatTile(label: "Pages", value: result.pageCount)
                    StatTile(label: "Entries", value: result.entryCount)
                    Spacer()
                }
            } else {
                HStack(spacing: 28) {
                    ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                        StatTile(label: "“\(result.display)”", value: result.total, color: Theme.series(index))
                    }
                    Spacer()
                }
            }
            if total > 0 {
                HStack {
                    Text("Usage over the journal").font(.headline)
                    Spacer()
                    Picker("Show by", selection: $axis) {
                        Text("By Date").tag(TimelineAxis.date)
                        Text("By Page").tag(TimelineAxis.pages)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if bins.count >= 2 {
                    TimelineChart(series: series)
                        .frame(height: 210)
                } else {
                    Text(axis == .date
                         ? "There aren't enough dated entries here to chart. Try By Page."
                         : "Include more pages to see a chart.")
                        .foregroundStyle(.secondary)
                }
                if axis == .date, undated > 0 {
                    Text("\(count(undated, "mention")) in undated writing \(undated == 1 ? "isn't" : "aren't") shown by date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if results.count == 1 {
                    Text("Command-click words below to compare them with this one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if bins.count >= 2 {
                    DisclosureGroup("Table", isExpanded: $showTable) {
                        VStack(spacing: 3) {
                            ForEach(bins.indices.filter { index in series.contains { $0.bins[index].count > 0 } }, id: \.self) { index in
                                HStack {
                                    Text(bins[index].label)
                                    Spacer()
                                    ForEach(series.indices, id: \.self) { item in
                                        Text("\(series[item].bins[index].count)")
                                            .monospacedDigit()
                                            .foregroundStyle(series.count > 1 ? series[item].color : .primary)
                                            .frame(minWidth: 36, alignment: .trailing)
                                    }
                                }
                                .font(.callout)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
                matchList
            } else {
                Text("\(results.count == 1 ? "That doesn't" : "Those don't") appear in the selected pages.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let matchLimit = 5

    /// Where the words appear, newest journal order, each opening its page.
    private var matchList: some View {
        let all = matches.enumerated().flatMap { index, list in list.map { (series: index, match: $0) } }
        let shown = showAllMatches ? all : Array(all.prefix(Self.matchLimit))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Where it appears").font(.headline).padding(.top, 6)
            ForEach(shown, id: \.match.id) { item in
                Button { model.openPage(item.match.pageID, highlight: item.match.highlightedText) } label: {
                    MatchRow(match: item.match, color: matches.count > 1 ? Theme.series(item.series) : nil)
                }
                .buttonStyle(.plain)
                .help("Open page \(item.match.pageNumber)")
            }
            if all.count > Self.matchLimit {
                Button(showAllMatches ? "Show Fewer" : "Show All \(all.count)") { showAllMatches.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    // MARK: - Entries over time

    private func entriesSection(_ rhythm: EntryRhythm) -> some View {
        let bins = byWeek ? rhythm.byWeek : rhythm.byMonth
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Entries").font(.headline)
                Spacer()
                if rhythm.datedCount > 0 {
                    Picker("Show by", selection: $byWeek) {
                        Text("Per Month").tag(false)
                        Text("Per Week").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            // Tiles wrap onto a second row rather than squeezing a value like "10:00 PM" onto two lines, and
            // share the rows evenly rather than leaving one tile on its own.
            WordFlow(spacing: 28, rowSpacing: 14, balanced: true) {
                StatTile(label: "Entries", value: rhythm.entryCount)
                if let perMonth = rhythm.perMonth, let perWeek = rhythm.perWeek {
                    trendTile(.perMonth, StatTile(label: "Average per month", value: perMonth.formatted(.number.precision(.fractionLength(1)))))
                    trendTile(.perWeek, StatTile(label: "Average per week", value: perWeek.formatted(.number.precision(.fractionLength(1)))))
                }
                if let gap = rhythm.longestGap {
                    StatTile(label: "Longest gap", value: count(gap.days, "day"), detail: "\(gap.from)\nto \(gap.to)")
                }
                if let streak = rhythm.longestStreak, streak.days > 1 {
                    StatTile(label: "Longest streak", value: count(streak.days, "day"), detail: "\(streak.from)\nto \(streak.to)")
                }
                if rhythm.currentStreak > 1 {
                    StatTile(label: "Current streak", value: count(rhythm.currentStreak, "day"))
                }
                if let average = rhythm.averageTime {
                    trendTile(.time, StatTile(label: "Usual time", value: average,
                                              detail: "from \(count(rhythm.timedCount, "entry", "entries")) with a time"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trend, let points = trendPoints(trend, rhythm) {
                if points.count >= 2 {
                    trendSection(trend, points: points)
                } else {
                    Text("All dated entries fall in one \(trend == .perWeek || (trend == .time && byWeek) ? "week" : "month") so far, so there's no change to show yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if rhythm.datedCount == 0 {
                Text("None of these entries has a date yet, so they can't be shown over time.")
                    .foregroundStyle(.secondary)
            } else {
                if bins.count >= 2 {
                    TimelineChart(series: [TimelineSeries(name: "entries", color: Theme.chart, bins: bins)], noun: ("entry", "entries"),
                                  onSelect: { index in
                                      model.showEntries(bins[index].entryIDs, label: bins[index].label)
                                  })
                        .frame(height: 180)
                }
                if rhythm.byWeekday.contains(where: { $0.count > 0 }) {
                    Text("By day of the week").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    TimelineChart(series: [TimelineSeries(name: "entries by weekday", color: Theme.chart,
                                                          bins: rhythm.byWeekday)], noun: ("entry", "entries"))
                        .frame(height: 140)
                }
                if rhythm.timedCount > 0 {
                    Text("By time of day").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    TimelineChart(series: [TimelineSeries(name: "entries by time of day", color: Theme.chart,
                                                          bins: rhythm.byTimeOfDay)], noun: ("entry", "entries"))
                        .frame(height: 140)
                    Text("Only entries with a time in their heading, \(rhythm.timedCount) of \(rhythm.entryCount).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(rhythmNote(rhythm))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A tile that shows, or hides, how its figure changed over time when clicked.
    private func trendTile(_ kind: StatTrend, _ tile: StatTile) -> some View {
        Button {
            trend = trend == kind ? nil : kind
        } label: {
            tile.clickable(selected: trend == kind)
        }
        .buttonStyle(.plain)
        .help(trend == kind ? "Hide how this changed over time" : "Show how this changed over time")
    }

    private func trendPoints(_ kind: StatTrend, _ rhythm: EntryRhythm) -> [TrendPoint]? {
        switch kind {
        case .perMonth: rhythm.perMonthTrend
        case .perWeek: rhythm.perWeekTrend
        case .time: byWeek ? rhythm.timeTrendByWeek : rhythm.timeTrendByMonth
        }
    }

    private func trendSection(_ kind: StatTrend, points: [TrendPoint]) -> some View {
        let title: String
        let note: String
        switch kind {
        case .perMonth:
            title = "Average per month over time"
            note = "Each point is the average as it stood at the end of that month, counting only entries dated up to then."
        case .perWeek:
            title = "Average per week over time"
            note = "Each point is the average as it stood at the end of that week, counting only entries dated up to then."
        case .time:
            title = "Usual time over time"
            note = "Each point is the usual time as it stood at the end of that \(byWeek ? "week" : "month"), from entries "
                + "dated up to then that have a time. Gaps are where there's nothing to average yet."
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button("Close") { trend = nil }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            TrendChart(points: points, isTime: kind == .time)
                .frame(height: 160)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line.opacity(0.6)))
        .padding(.vertical, 4)
    }

    /// The span the averages cover, and how many entries were left out for having no date.
    private func rhythmNote(_ rhythm: EntryRhythm) -> String {
        var note = ""
        if let first = rhythm.first, let last = rhythm.last {
            note = first == last ? "All dated entries are from \(first)." : "Averages run from \(first) to \(last), empty months and weeks included."
        }
        let undated = rhythm.entryCount - rhythm.datedCount
        if undated > 0 {
            note += " \(count(undated, "entry", "entries")) without a date \(undated == 1 ? "isn't" : "aren't") counted by date."
        }
        return note
    }

    // MARK: - Top words and names

    private func wordsSection(_ snapshot: AnalysisSnapshot) -> some View {
        let words = snapshot.visibleWords(hidden: model.hiddenWords, includeCommon: includeCommon)
        let shown = showAllWords ? Array(words.prefix(500)) : Array(words.prefix(Self.wordLimit))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top words").font(.headline)
                Spacer()
                if !model.hiddenWords.isEmpty {
                    Button("Hidden (\(model.hiddenWords.count))") { showHidden = true }
                        .buttonStyle(.link)
                        .font(.caption)
                        .popover(isPresented: $showHidden) { HiddenWordsPopover().environmentObject(model) }
                }
            }
            Toggle("Include common words like “the”", isOn: $includeCommon)
                .toggleStyle(.checkbox)
                .font(.caption)
            if shown.isEmpty {
                Text("No words to show.").foregroundStyle(.secondary)
            }
            WordRows(words: shown, maximum: shown.first?.count ?? 1, chosen: chosenColors) { select($0) }
            if words.count > Self.wordLimit {
                Button(showAllWords ? "Show Fewer" : "Show More") { showAllWords.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func namesSection(_ snapshot: AnalysisSnapshot) -> some View {
        let names = snapshot.nameStats(hidden: model.hiddenWords)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Names").font(.headline)
            Text("People and pets Claude found")
                .font(.caption)
                .foregroundStyle(.secondary)
            if names.isEmpty {
                Text("No names yet.").foregroundStyle(.secondary)
            }
            // Every name found, however many.
            WordRows(words: names, maximum: names.first?.count ?? 1,
                     chosen: chosenColors, onRename: { renaming = $0 }) { select($0) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural ?? singular + "s")"
    }
}

/// The Entries stats that can show how they changed over time.
public enum StatTrend: Hashable, Sendable {
    case perMonth, perWeek, time
}

private struct StatTile: View {
    let label: String
    let value: String
    var detail: String?
    var color: Color?
    /// Set on tiles that open a chart: nil on plain tiles, true while the chart is showing.
    var selected: Bool?

    init(label: String, value: String, detail: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    init(label: String, value: Int, color: Color? = nil) {
        self.init(label: label, value: value.formatted())
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if selected != nil {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.caption2)
                        .foregroundStyle(selected == true ? Theme.accent : .secondary)
                }
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A clickable tile gets a frame the same size as its padding, pulled back out so the row doesn't shift.
        .padding(.horizontal, selected == nil ? 0 : 8)
        .padding(.vertical, selected == nil ? 0 : 5)
        .background {
            if let selected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Theme.card : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accent.opacity(0.6) : Theme.line.opacity(0.6)))
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, selected == nil ? 0 : -8)
        .padding(.vertical, selected == nil ? 0 : -5)
    }

    func clickable(selected: Bool) -> StatTile {
        var tile = self
        tile.selected = selected
        return tile
    }
}

/// A line through a running figure, one point per month or week, with hover details.
private struct TrendChart: View {
    let points: [TrendPoint]
    /// Values are minutes after midnight, labelled as clock times.
    var isTime = false
    @ViewState private var hovered: Int?

    private let axisWidth: CGFloat = 44
    private let axisHeight: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let plot = CGRect(x: axisWidth, y: 10,
                              width: max(proxy.size.width - axisWidth, 1),
                              height: max(proxy.size.height - axisHeight - 10, 1))
            let ticks = self.ticks
            let low = ticks.first ?? 0
            let high = max(ticks.last ?? 1, low + 1e-9)
            // Times run down the chart, earliest at the top, the way a day reads; other figures rise.
            let y = { (value: Double) -> CGFloat in
                let share = CGFloat((value - low) / (high - low))
                return isTime ? plot.minY + plot.height * share : plot.maxY - plot.height * share
            }

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for tick in ticks {
                        var line = Path()
                        let at = y(tick).rounded() + 0.5
                        line.move(to: CGPoint(x: plot.minX, y: at))
                        line.addLine(to: CGPoint(x: plot.maxX, y: at))
                        context.stroke(line, with: .color(Theme.line), lineWidth: 1)
                    }
                    if let hovered {
                        let slot = plot.width / CGFloat(points.count)
                        let band = CGRect(x: plot.minX + slot * CGFloat(hovered), y: plot.minY, width: slot, height: plot.height)
                        context.fill(Path(band), with: .color(.primary.opacity(0.06)))
                    }
                    // Gaps (no value yet) break the line rather than bridging it.
                    var path = Path()
                    var drawing = false
                    for (index, point) in points.enumerated() {
                        guard let value = point.value else { drawing = false; continue }
                        let spot = CGPoint(x: center(index, plot), y: y(value))
                        if drawing { path.addLine(to: spot) } else { path.move(to: spot) }
                        drawing = true
                    }
                    context.stroke(path, with: .color(Theme.chart), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    let dot: CGFloat = points.count <= 40 ? 5 : 0
                    for (index, point) in points.enumerated() {
                        guard let value = point.value else { continue }
                        let size = index == hovered ? 8 : dot
                        guard size > 0 else { continue }
                        let spot = CGPoint(x: center(index, plot), y: y(value))
                        context.fill(Path(ellipseIn: CGRect(x: spot.x - size / 2, y: spot.y - size / 2, width: size, height: size)),
                                     with: .color(Theme.chart))
                    }
                }

                ForEach(ticks, id: \.self) { tick in
                    Text(tickLabel(tick))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: axisWidth - 6, alignment: .trailing)
                        .position(x: (axisWidth - 6) / 2, y: y(tick))
                }

                ForEach(labelIndices(width: plot.width), id: \.self) { index in
                    Text(points[index].shortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(center(index, plot), plot.minX + 26), plot.maxX - 26), y: plot.maxY + 13)
                }

                if let hovered, points.indices.contains(hovered) {
                    tooltip(points[hovered])
                        .position(tooltipSpot(hovered, plot: plot, y: y))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    guard plot.contains(CGPoint(x: point.x, y: min(point.y, plot.maxY - 1))) else {
                        hovered = nil
                        return
                    }
                    hovered = min(Int((point.x - plot.minX) / (plot.width / CGFloat(points.count))), points.count - 1)
                case .ended:
                    hovered = nil
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Line chart over time")
        .accessibilityValue(points.filter { $0.value != nil }.map { "\($0.label): \($0.display)" }.joined(separator: ", "))
    }

    private let tooltipSize = CGSize(width: 180, height: 44)

    /// Where the hover details go so they don't cover the line: above it or below it across the stretch they
    /// span, whichever has room, or else beside the hovered point.
    private func tooltipSpot(_ index: Int, plot: CGRect, y: (Double) -> CGFloat) -> CGPoint {
        let half = tooltipSize.width / 2, gap: CGFloat = 8
        let x = min(max(center(index, plot), plot.minX + half), plot.maxX - half)
        // The line's highest and lowest points under the box, counting the segments that run into it.
        let slot = plot.width / CGFloat(points.count)
        let first = max(Int(((x - half - plot.minX) / slot).rounded(.down)) - 1, 0)
        let last = min(Int(((x + half - plot.minX) / slot).rounded(.up)), points.count - 1)
        let heights = (first...max(first, last)).compactMap { points[$0].value }.map(y)
        let top = heights.min() ?? plot.maxY, bottom = heights.max() ?? plot.minY
        let height = tooltipSize.height
        if top - plot.minY >= height + gap { return CGPoint(x: x, y: top - gap - height / 2) }
        if plot.maxY - bottom >= height + gap { return CGPoint(x: x, y: bottom + gap + height / 2) }
        // No clear band: beside the point, on the side with more room, level with it.
        let spot = center(index, plot)
        let besideX = spot + 14 + half <= plot.maxX ? spot + 14 + half : max(spot - 14 - half, plot.minX + half)
        let pointY = points[index].value.map(y) ?? plot.midY
        return CGPoint(x: besideX, y: min(max(pointY, plot.minY + height / 2), plot.maxY - height / 2))
    }

    private func tooltip(_ point: TrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(point.label).font(.caption.weight(.semibold)).lineLimit(1)
            Text(point.value == nil ? "Nothing to go on yet" : point.display)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }

    private func center(_ index: Int, _ plot: CGRect) -> CGFloat {
        plot.minX + plot.width / CGFloat(points.count) * (CGFloat(index) + 0.5)
    }

    private func labelIndices(width: CGFloat) -> [Int] {
        let capacity = max(Int(width / 84), 2)
        guard points.count > capacity else { return Array(points.indices) }
        return (0..<capacity).map { $0 * (points.count - 1) / (capacity - 1) }
    }

    private func tickLabel(_ tick: Double) -> String {
        guard isTime else { return tick.formatted(.number.precision(.fractionLength(0...1))) }
        return AnalysisSnapshot.clock(Int(tick)).replacingOccurrences(of: ":00 ", with: " ")
    }

    /// Gridlines at a clean step: from zero for averages, whole hours around the line for times.
    private var ticks: [Double] {
        let values = points.compactMap(\.value)
        guard let lowest = values.min(), let highest = values.max() else { return [0, 1] }
        if isTime {
            let low = lowest - 30, high = highest + 30
            let step = [60.0, 120, 180, 360].first { $0 >= (high - low) / 4 } ?? 360
            let start = (low / step).rounded(.down) * step
            let end = (high / step).rounded(.up) * step
            return Array(stride(from: start, through: end + step / 2, by: step))
        }
        let high = max(highest, 0.1)
        let rough = high / 4
        let magnitude = pow(10, (log10(rough)).rounded(.down))
        let step = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? 10 * magnitude
        let end = (high / step).rounded(.up) * step
        return Array(stride(from: 0, through: end + step / 2, by: step))
    }
}

/// One place a word appears: date, page, journal, and two lines around it.
private struct MatchRow: View {
    let match: TermMatch
    let color: Color?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let color { Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(match.date ?? "Undated").font(.callout.weight(.semibold))
                    Text("p. \(match.pageNumber)").font(.callout).foregroundStyle(.secondary)
                    if let journal = match.journalName {
                        Text(journal).font(.callout).foregroundStyle(.secondary)
                    }
                    if match.count > 1 {
                        Text("\(match.count) times").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(snippet)
                    .font(.callout)
                    .lineLimit(2)
                    .foregroundStyle(.primary.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private var snippet: AttributedString {
        var text = AttributedString(match.snippet)
        guard let range = match.highlight, range.upperBound <= match.snippet.count else { return text }
        let start = text.index(text.startIndex, offsetByCharacters: range.lowerBound)
        let end = text.index(text.startIndex, offsetByCharacters: range.upperBound)
        text[start..<end].font = .callout.weight(.bold)
        text[start..<end].foregroundColor = color ?? Theme.accent
        return text
    }
}

private struct WordRows: View {
    @EnvironmentObject private var model: AppModel
    let words: [WordStat]
    let maximum: Int
    /// Words being looked up, marked in their chart colors.
    var chosen: [String: Color] = [:]
    /// For names: renaming one on every page where it's written.
    var onRename: ((WordStat) -> Void)? = nil
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(words) { word in
                let color = chosen[word.key]
                HStack(spacing: 8) {
                    Button { onSelect(word.display) } label: {
                        Text(word.display)
                            .fontWeight(color == nil ? .regular : .semibold)
                            .foregroundStyle(color ?? .primary)
                            .lineLimit(1)
                            .frame(width: 112, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("See where \(word.display) appears; Command-click to compare it with the words already chosen")

                    GeometryReader { proxy in
                        UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                            .fill(color ?? Theme.chart)
                            .frame(width: max(2, proxy.size.width * CGFloat(word.count) / CGFloat(max(maximum, 1))),
                                   height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 20)

                    Text(word.count.formatted())
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                    if let onRename {
                        Button("Rename…") { onRename(word) }
                            .controlSize(.mini)
                            .help("Give \(word.display) a fuller name, such as a last name, on every page where it's written")
                    }
                    Button("Hide") { model.hideWord(word.key) }
                        .controlSize(.mini)
                        .help("Hide \(word.display) from these lists")
                }
                .padding(.horizontal, 6)
                .background(color.map { $0.opacity(0.14) } ?? .clear, in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, -6)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(color == nil ? [] : .isSelected)
            }
        }
    }
}

private struct HiddenWordsPopover: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hidden words").font(.headline)
                Spacer()
                Button("Show All") { model.unhideAllWords() }
                    .controlSize(.small)
            }
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(model.hiddenWords.sorted(), id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button("Show") { model.unhideWord(word) }
                                .controlSize(.mini)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(width: 260)
    }
}

/// Where a chart's hover details go.
public enum ChartTooltip {
    /// The center for details of `size` about `bar` (the hovered slot's bars together): above it when there's
    /// room inside the chart, else beside it on whichever side fits, else above it reaching out of the chart.
    /// Never over the bar.
    public static func spot(size: CGSize, bar: CGRect, plot: CGRect, bounds: CGSize) -> CGPoint {
        let gap: CGFloat = 8
        let x = min(max(bar.midX, size.width / 2), max(bounds.width - size.width / 2, size.width / 2))
        let above = CGPoint(x: x, y: bar.minY - gap - size.height / 2)
        if bar.minY - gap - size.height >= 0 { return above }
        let y = min(max(bar.minY + size.height / 2, plot.minY + size.height / 2), plot.maxY - size.height / 2)
        if bar.maxX + gap + size.width <= bounds.width { return CGPoint(x: bar.maxX + gap + size.width / 2, y: y) }
        if bar.minX - gap - size.width >= 0 { return CGPoint(x: bar.minX - gap - size.width / 2, y: y) }
        return above
    }
}

struct TimelineSeries {
    let name: String
    let color: Color
    /// Must line up bin for bin with the other series in the same chart.
    let bins: [TimelineBin]
}

/// A column chart with hover details; several series sit side by side in each slot. The hovered bar brightens,
/// and its details sit above it, or beside it when it's too tall, never over it.
private struct TimelineChart: View {
    let series: [TimelineSeries]
    /// What each bar counts, singular and plural.
    var noun = ("mention", "mentions")
    /// Called with a slot's index when it's clicked; a chart without it can't be clicked.
    var onSelect: ((Int) -> Void)?
    @ViewState private var hovered: Int?
    @ViewState private var tooltipSize = CGSize(width: 180, height: 40)

    private let axisWidth: CGFloat = 36
    private let axisHeight: CGFloat = 24

    private struct Bar: Identifiable {
        let id: String
        let slot: Int
        let rect: CGRect
        let color: Color
    }

    var body: some View {
        GeometryReader { proxy in
            let plot = CGRect(x: axisWidth, y: 10,
                              width: max(proxy.size.width - axisWidth, 1),
                              height: max(proxy.size.height - axisHeight - 10, 1))
            let ticks = Self.ticks(maximum: series.flatMap { $0.bins.map(\.count) }.max() ?? 1)
            let top = CGFloat(ticks.last ?? 1)
            let bars = self.bars(plot: plot, top: top)

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for tick in ticks {
                        var line = Path()
                        let y = (plot.maxY - plot.height * CGFloat(tick) / top).rounded() + 0.5
                        line.move(to: CGPoint(x: plot.minX, y: y))
                        line.addLine(to: CGPoint(x: plot.maxX, y: y))
                        context.stroke(line, with: .color(Theme.line), lineWidth: 1)
                    }
                    if let hovered {
                        let slot = plot.width / CGFloat(bins.count)
                        let band = CGRect(x: plot.minX + slot * CGFloat(hovered), y: plot.minY,
                                          width: slot, height: plot.height)
                        context.fill(Path(band), with: .color(.primary.opacity(0.06)))
                    }
                }

                ForEach(bars) { bar in
                    let radius = min(4, bar.rect.width / 2, bar.rect.height)
                    UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
                        .fill(bar.color)
                        .brightness(hovered == bar.slot ? 0.12 : 0)
                        .animation(.easeInOut(duration: 0.18), value: hovered == bar.slot)
                        .frame(width: bar.rect.width, height: bar.rect.height)
                        .position(x: bar.rect.midX, y: bar.rect.midY)
                        .allowsHitTesting(false)
                }

                ForEach(ticks, id: \.self) { tick in
                    Text(tick.formatted())
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: axisWidth - 6, alignment: .trailing)
                        .position(x: (axisWidth - 6) / 2, y: plot.maxY - plot.height * CGFloat(tick) / top)
                }

                ForEach(labelIndices(width: plot.width), id: \.self) { index in
                    Text(bins[index].shortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(center(index, plot), plot.minX + 26), plot.maxX - 26),
                                  y: plot.maxY + 13)
                }

                if let hovered, bins.indices.contains(hovered) {
                    tooltip(hovered)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                        .position(tooltipSpot(hovered, bars: bars, plot: plot, bounds: proxy.size))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovered = slot(at: point, plot: plot)
                case .ended:
                    hovered = nil
                }
            }
            .pointerStyle(onSelect != nil && hovered.map(isSelectable) == true ? .link : nil)
            .onTapGesture { point in
                guard let onSelect, let index = slot(at: point, plot: plot), isSelectable(index) else { return }
                onSelect(index)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(noun.0 == "mention"
                            ? "Chart of mentions of \(names) over the journal" : "Chart of \(names) over the journal")
        .accessibilityValue(series.map { line in
            line.name + ": " + line.bins.filter { $0.count > 0 }.map { "\($0.label): \($0.count)" }.joined(separator: ", ")
        }.joined(separator: "; "))
    }

    private func slot(at point: CGPoint, plot: CGRect) -> Int? {
        guard !bins.isEmpty, plot.contains(CGPoint(x: point.x, y: min(point.y, plot.maxY - 1))) else { return nil }
        return min(Int((point.x - plot.minX) / (plot.width / CGFloat(bins.count))), bins.count - 1)
    }

    private func isSelectable(_ index: Int) -> Bool {
        onSelect != nil && bins.indices.contains(index) && bins[index].count > 0
    }

    private func bars(plot: CGRect, top: CGFloat) -> [Bar] {
        let slot = plot.width / CGFloat(max(bins.count, 1))
        let group = max(min(24 * CGFloat(series.count), slot - 2), 1)
        let width = group / CGFloat(max(series.count, 1))
        var bars: [Bar] = []
        for (item, line) in series.enumerated() {
            for (index, bin) in line.bins.enumerated() where bin.count > 0 {
                let height = max(plot.height * CGFloat(bin.count) / top, 2)
                let rect = CGRect(x: plot.minX + slot * CGFloat(index) + (slot - group) / 2 + width * CGFloat(item),
                                  y: plot.maxY - height, width: max(width - (series.count > 1 ? 1 : 0), 1),
                                  height: height)
                bars.append(Bar(id: "\(item)-\(index)", slot: index, rect: rect, color: line.color))
            }
        }
        return bars
    }

    private func tooltipSpot(_ index: Int, bars: [Bar], plot: CGRect, bounds: CGSize) -> CGPoint {
        let slot = plot.width / CGFloat(bins.count)
        let own = bars.filter { $0.slot == index }.map(\.rect)
        let bar = own.dropFirst().reduce(own.first ?? CGRect(x: plot.minX + slot * CGFloat(index), y: plot.maxY,
                                                              width: slot, height: 0)) { $0.union($1) }
        return ChartTooltip.spot(size: tooltipSize, bar: bar, plot: plot, bounds: bounds)
    }

    private var names: String { series.map(\.name).joined(separator: ", ") }
    private var bins: [TimelineBin] { series.first?.bins ?? [] }

    private func tooltip(_ index: Int) -> some View {
        let bin = series[0].bins[index]
        return VStack(alignment: .leading, spacing: 2) {
            Text(bin.label).font(.caption.weight(.semibold)).lineLimit(1)
            if series.count == 1 {
                Text("\(bin.count) \(bin.count == 1 ? noun.0 : noun.1) · \(bin.pageCount) \(bin.pageCount == 1 ? "page" : "pages")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isSelectable(index) {
                    Text("Click to show \(bin.count == 1 ? "it" : "them")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ForEach(series.indices, id: \.self) { item in
                    HStack(spacing: 5) {
                        Circle().fill(series[item].color).frame(width: 7, height: 7)
                        Text("\(series[item].name): \(series[item].bins[index].count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }

    private func center(_ index: Int, _ plot: CGRect) -> CGFloat {
        plot.minX + plot.width / CGFloat(bins.count) * (CGFloat(index) + 0.5)
    }

    private func labelIndices(width: CGFloat) -> [Int] {
        let capacity = max(Int(width / 84), 2)
        guard bins.count > capacity else { return Array(bins.indices) }
        return (0..<capacity).map { $0 * (bins.count - 1) / (capacity - 1) }
    }

    /// Whole-number gridlines at a clean step.
    static func ticks(maximum: Int) -> [Int] {
        let value = max(maximum, 1)
        let rough = Double(value) / 4
        let magnitude = pow(10, floor(log10(max(rough, 1))))
        let step = max(Int(([1, 2, 5, 10].first { Double($0) * magnitude >= rough } ?? 10) * magnitude), 1)
        let top = Int((Double(value) / Double(step)).rounded(.up)) * step
        return Array(stride(from: 0, through: top, by: step))
    }
}

/// Renames a person on every page where their name is written: "Hannah" becomes "Hannah K." in Analysis and
/// in each page's people. The text itself stays as written.
private struct RenamePersonSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let label: String
    let onRenamed: (String) -> Void
    @ViewState private var name: String?

    var body: some View {
        let places = model.pagesNaming(label)
        let pageCount = Set(places.map(\.page.id)).count
        let written = places.first?.written ?? label
        let typed = name ?? written
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(label)").font(.title3.weight(.semibold))
            Text(pageCount == 0
                 ? "\(label) isn't on any page that has been read."
                 : "Give the name to use on \(pageCount == 1 ? "the 1 page" : "all \(pageCount) pages") where this name is written, such as \(written) with a last name or initial. The text stays as written.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(written, text: Binding(get: { typed }, set: { name = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || trimmed == label || pageCount == 0)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func rename() {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != label else { return }
        model.renamePerson(label, to: trimmed)
        onRenamed(trimmed)
        dismiss()
    }
}
