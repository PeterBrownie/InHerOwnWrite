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
    @ViewState private var term = ""
    @ViewState private var result: TermResult?
    @ViewState private var axis = TimelineAxis.date
    @ViewState private var includeCommon = false
    @ViewState private var showAllWords = false
    @ViewState private var showHidden = false
    @ViewState private var showTable = false
    @ViewState private var confirmRead = false

    private static let wordLimit = 40

    public init(initialTerm: String = "") {
        _term = ViewState(wrappedValue: initialTerm)
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
            result = made.term(term)
        }
        .onChange(of: term) { _, value in
            result = snapshot?.term(value)
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
                TextField("Type a word or name", text: $term)
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

            if let result {
                termResult(result)
            }
        }
    }

    private func termResult(_ result: TermResult) -> some View {
        let bins = axis == .date ? result.byDate : result.byPage
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 28) {
                StatTile(label: "Mentions of “\(result.display)”", value: result.total)
                StatTile(label: "Pages", value: result.pageCount)
                StatTile(label: "Entries", value: result.entryCount)
                Spacer()
            }
            if result.total > 0 {
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
                    TimelineChart(bins: bins, term: result.display)
                        .frame(height: 210)
                } else {
                    Text(axis == .date
                         ? "There aren't enough dated entries here to chart. Try By Page."
                         : "Include more pages to see a chart.")
                        .foregroundStyle(.secondary)
                }
                if axis == .date, result.undatedMentions > 0 {
                    Text("\(count(result.undatedMentions, "mention")) in undated writing \(result.undatedMentions == 1 ? "isn't" : "aren't") shown by date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if bins.count >= 2 {
                    DisclosureGroup("Table", isExpanded: $showTable) {
                        VStack(spacing: 3) {
                            ForEach(bins.filter { $0.count > 0 }) { bin in
                                HStack {
                                    Text(bin.label)
                                    Spacer()
                                    Text("\(bin.count)").monospacedDigit()
                                }
                                .font(.callout)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
            } else {
                Text("That doesn't appear in the selected pages.")
                    .foregroundStyle(.secondary)
            }
        }
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
            WordRows(words: shown, maximum: shown.first?.count ?? 1) { term = $0 }
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
            WordRows(words: Array(names.prefix(Self.wordLimit)), maximum: names.first?.count ?? 1) { term = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural ?? singular + "s")"
    }
}

private struct StatTile: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value.formatted())
                .font(.system(size: 26, weight: .semibold))
        }
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
                    .help("See how \(word.display) is used over time")

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

/// A single-series column chart with hover details.
private struct TimelineChart: View {
    let bins: [TimelineBin]
    let term: String
    @ViewState private var hovered: Int?

    private let axisWidth: CGFloat = 36
    private let axisHeight: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let plot = CGRect(x: axisWidth, y: 10,
                              width: max(proxy.size.width - axisWidth, 1),
                              height: max(proxy.size.height - axisHeight - 10, 1))
            let ticks = Self.ticks(maximum: bins.map(\.count).max() ?? 1)
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
                    let width = max(min(24, slot - 2), 1)
                    for (index, bin) in bins.enumerated() where bin.count > 0 {
                        let height = max(plot.height * CGFloat(bin.count) / top, 2)
                        let rect = CGRect(x: plot.minX + slot * CGFloat(index) + (slot - width) / 2,
                                          y: plot.maxY - height, width: width, height: height)
                        let radius = min(4, width / 2, height)
                        let bar = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius).path(in: rect)
                        context.fill(bar, with: .color(Theme.chart))
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
                    tooltip(bins[hovered])
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
        .accessibilityLabel("Chart of mentions of \(term) over the journal")
        .accessibilityValue(bins.filter { $0.count > 0 }.map { "\($0.label): \($0.count)" }.joined(separator: ", "))
    }

    private func tooltip(_ bin: TimelineBin) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bin.label).font(.caption.weight(.semibold)).lineLimit(1)
            Text("\(bin.count) \(bin.count == 1 ? "mention" : "mentions") · \(bin.pageCount) \(bin.pageCount == 1 ? "page" : "pages")")
                .font(.caption)
                .foregroundStyle(.secondary)
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
