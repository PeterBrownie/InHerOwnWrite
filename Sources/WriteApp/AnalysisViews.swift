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

    private static let wordLimit = 40

    public init() {}

    private var term: String {
        get { model.analysisTerm }
        nonmutating set { model.analysisTerm = newValue }
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
                Button("Read Again…") { confirmRead = true }
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
                TextField("Type a word, name, or phrase; separate several with commas", text: $model.analysisTerm)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                if !term.isEmpty {
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
                Button { model.openPage(item.match.pageID) } label: {
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
            // Tiles wrap onto a second row rather than squeezing a value like "10:00 PM" onto two lines.
            WordFlow(spacing: 28, rowSpacing: 14) {
                StatTile(label: "Entries", value: rhythm.entryCount)
                if let perMonth = rhythm.perMonth, let perWeek = rhythm.perWeek {
                    StatTile(label: "Average per month", value: perMonth.formatted(.number.precision(.fractionLength(1))))
                    StatTile(label: "Average per week", value: perWeek.formatted(.number.precision(.fractionLength(1))))
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
                    StatTile(label: "Usual time", value: average,
                             detail: "from \(count(rhythm.timedCount, "entry", "entries")) with a time")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if rhythm.datedCount == 0 {
                Text("None of these entries has a date yet, so they can't be shown over time.")
                    .foregroundStyle(.secondary)
            } else {
                if bins.count >= 2 {
                    TimelineChart(series: [TimelineSeries(name: "entries", color: Theme.chart, bins: bins)], noun: ("entry", "entries"))
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
            WordRows(words: shown, maximum: shown.first?.count ?? 1) { select($0) }
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
            WordRows(words: Array(names.prefix(Self.wordLimit)), maximum: names.first?.count ?? 1) { select($0) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural ?? singular + "s")"
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    var detail: String?
    var color: Color?

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
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(words) { word in
                HStack(spacing: 8) {
                    Button { onSelect(word.display) } label: {
                        Text(word.display)
                            .lineLimit(1)
                            .frame(width: 112, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("See where \(word.display) appears; Command-click to compare it with the words already chosen")

                    GeometryReader { proxy in
                        UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                            .fill(Theme.chart)
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
                    Button("Hide") { model.hideWord(word.key) }
                        .controlSize(.mini)
                        .help("Hide \(word.display) from these lists")
                }
                .accessibilityElement(children: .combine)
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

struct TimelineSeries {
    let name: String
    let color: Color
    /// Must line up bin for bin with the other series in the same chart.
    let bins: [TimelineBin]
}

/// A column chart with hover details; several series sit side by side in each slot.
private struct TimelineChart: View {
    let series: [TimelineSeries]
    /// What each bar counts, singular and plural.
    var noun = ("mention", "mentions")
    @ViewState private var hovered: Int?

    private let axisWidth: CGFloat = 36
    private let axisHeight: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let plot = CGRect(x: axisWidth, y: 10,
                              width: max(proxy.size.width - axisWidth, 1),
                              height: max(proxy.size.height - axisHeight - 10, 1))
            let ticks = Self.ticks(maximum: series.flatMap { $0.bins.map(\.count) }.max() ?? 1)
            let top = CGFloat(ticks.last ?? 1)

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for tick in ticks {
                        var line = Path()
                        let y = (plot.maxY - plot.height * CGFloat(tick) / top).rounded() + 0.5
                        line.move(to: CGPoint(x: plot.minX, y: y))
                        line.addLine(to: CGPoint(x: plot.maxX, y: y))
                        context.stroke(line, with: .color(Theme.line), lineWidth: 1)
                    }
                    let slot = plot.width / CGFloat(bins.count)
                    if let hovered {
                        let band = CGRect(x: plot.minX + slot * CGFloat(hovered), y: plot.minY,
                                          width: slot, height: plot.height)
                        context.fill(Path(band), with: .color(.primary.opacity(0.06)))
                    }
                    let group = max(min(24 * CGFloat(series.count), slot - 2), 1)
                    let width = group / CGFloat(max(series.count, 1))
                    for (item, line) in series.enumerated() {
                        for (index, bin) in line.bins.enumerated() where bin.count > 0 {
                            let height = max(plot.height * CGFloat(bin.count) / top, 2)
                            let rect = CGRect(x: plot.minX + slot * CGFloat(index) + (slot - group) / 2 + width * CGFloat(item),
                                              y: plot.maxY - height, width: max(width - (series.count > 1 ? 1 : 0), 1),
                                              height: height)
                            let radius = min(4, rect.width / 2, height)
                            let bar = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius).path(in: rect)
                            context.fill(bar, with: .color(line.color))
                        }
                    }
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
                        .position(x: min(max(center(hovered, plot), plot.minX + 90), plot.maxX - 90), y: plot.minY + 24)
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
                    let slot = plot.width / CGFloat(bins.count)
                    hovered = min(Int((point.x - plot.minX) / slot), bins.count - 1)
                case .ended:
                    hovered = nil
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(noun.0 == "mention"
                            ? "Chart of mentions of \(names) over the journal" : "Chart of \(names) over the journal")
        .accessibilityValue(series.map { line in
            line.name + ": " + line.bins.filter { $0.count > 0 }.map { "\($0.label): \($0.count)" }.joined(separator: ", ")
        }.joined(separator: "; "))
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
