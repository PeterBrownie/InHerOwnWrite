import SwiftUI
import WriteCore

/// Stats she makes herself, such as "How many times did I cry?": a row of her stats, and the chosen one's
/// count, chart, and where it was found.
struct CustomStatsSection: View {
    @EnvironmentObject private var model: AppModel
    let snapshot: AnalysisSnapshot
    @Binding var selected: UUID?
    @ViewState private var editing: CustomStat?
    @ViewState private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Your Stats").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.customStats) { stat in
                            let isSelected = selected == stat.id
                            Button { selected = isSelected ? nil : stat.id } label: {
                                Text(stat.name)
                                    .font(.callout.weight(isSelected ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? Theme.accent.opacity(0.18) : Theme.paper, in: Capsule())
                                    .overlay(Capsule().strokeBorder(isSelected ? Theme.accent : Theme.line))
                            }
                            .buttonStyle(.plain)
                            .help(stat.question)
                        }
                    }
                    .padding(1)
                }
                Button("New Stat…") { isCreating = true }
                    .help("Count something in your own words, such as “How many times did I cry?”")
            }
            if let stat = model.customStats.first(where: { $0.id == selected }) {
                CustomStatDetail(stat: stat, snapshot: snapshot, onEdit: { editing = stat },
                                 onDelete: {
                                     selected = nil
                                     model.deleteStat(stat.id)
                                 })
            } else if model.customStats.isEmpty {
                Text("Ask a question about the journal, such as “How many times did I cry?”, and it's counted on every page and charted over time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $isCreating) {
            StatEditorSheet(existing: nil) { selected = $0.id }
                .environmentObject(model)
        }
        .sheet(item: $editing) { stat in
            StatEditorSheet(existing: stat) { selected = $0.id }
                .environmentObject(model)
        }
    }
}

private struct CustomStatDetail: View {
    @EnvironmentObject private var model: AppModel
    let stat: CustomStat
    let snapshot: AnalysisSnapshot
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ViewState private var axis = TimelineAxis.date
    @ViewState private var showAll = false
    @ViewState private var confirmCount = false
    @ViewState private var confirmDelete = false
    @ViewState private var confirmRecount = false

    private static let matchLimit = 5

    private var singular: String {
        stat.unit.hasSuffix("s") && !stat.unit.hasSuffix("ss") ? String(stat.unit.dropLast()) : stat.unit
    }

    var body: some View {
        let result = snapshot.result(for: stat, findings: model.statFindings(stat))
        let term = result.term
        let bins = axis == .date ? term.byDate : term.byPage
        let waiting = model.pagesToCount(stat)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 28) {
                StatTile(label: stat.name, value: term.total)
                StatTile(label: "Entries", value: term.entryCount)
                StatTile(label: "Pages", value: term.pageCount)
                Spacer()
                Menu {
                    Button("Edit…", action: onEdit)
                    if stat.method == .reading {
                        Button("Count Every Page Again…") { confirmRecount = true }
                        .disabled(!model.hasAPIKey)
                    }
                    Divider()
                    Button("Delete Stat…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
            }
            Text(method)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            countingStatus(waiting: waiting.count)

            if term.total > 0 {
                HStack {
                    Text("Over the journal").font(.headline)
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
                    TimelineChart(series: [TimelineSeries(name: stat.name, color: Theme.accent, bins: bins)],
                                  noun: (singular, stat.unit))
                        .frame(height: 210)
                } else {
                    Text(axis == .date ? "There aren't enough dated entries here to chart. Try By Page."
                         : "Include more pages to see a chart.")
                        .foregroundStyle(.secondary)
                }
                if axis == .date, term.undatedMentions > 0 {
                    Text("\(term.undatedMentions) in undated writing \(term.undatedMentions == 1 ? "isn't" : "aren't") shown by date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                matchList(result.matches)
            } else if waiting.isEmpty, model.statCounting[stat.id] == nil {
                Text("None found in the selected pages.").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Theme.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        .confirmationDialog("Count \(waiting.count) \(waiting.count == 1 ? "page" : "pages") with Claude?",
                            isPresented: $confirmCount, titleVisibility: .visible) {
            Button("Count Pages") { model.countStat(stat.id) }
        } message: {
            Text("The text of these pages is sent to Anthropic to be counted. Photos aren't sent.")
        }
        .confirmationDialog("Count every page again?", isPresented: $confirmRecount, titleVisibility: .visible) {
            Button("Count Again") { model.recountStat(stat.id) }
        } message: {
            Text("The text of every read page is sent to Anthropic and counted again. Photos aren't sent.")
        }
        .confirmationDialog("Delete “\(stat.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Stat", role: .destructive, action: onDelete)
        } message: {
            Text("Its counts are removed. The pages aren't changed.")
        }
    }

    private var method: String {
        switch stat.method {
        case .words:
            return "Counted on this Mac, each time one of these is written: " + stat.words.joined(separator: ", ") + "."
        case .reading:
            return "Claude reads each page and counts: " + stat.criteria + " New pages read by Claude are counted as they're read."
        }
    }

    @ViewBuilder
    private func countingStatus(waiting: Int) -> some View {
        if stat.method == .reading {
            if let progress = model.statCounting[stat.id] {
                if let problem = progress.problem {
                    HStack {
                        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        Spacer()
                        Button("Try Again") {
                            model.stopCounting(stat.id)
                            model.countStat(stat.id)
                        }
                    }
                    .font(.callout)
                } else {
                    HStack(spacing: 10) {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            .frame(width: 160)
                        Text("Counting… \(progress.done) of \(progress.total) pages")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("Stop") { model.stopCounting(stat.id) }
                            .controlSize(.small)
                    }
                }
            } else if waiting > 0 {
                HStack {
                    Label("\(waiting) read \(waiting == 1 ? "page hasn't" : "pages haven't") been counted yet, or changed since.",
                          systemImage: "info.circle")
                    Spacer()
                    Button("Count with Claude…") { confirmCount = true }
                        .disabled(!model.hasAPIKey)
                        .help(model.hasAPIKey ? "Sends the pages' text, not their photos" : "Add an API key in Settings first")
                }
                .font(.callout)
                .padding(10)
                .background(Theme.notice, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func matchList(_ matches: [TermMatch]) -> some View {
        let shown = showAll ? matches : Array(matches.prefix(Self.matchLimit))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Where it was found").font(.headline).padding(.top, 6)
            ForEach(shown) { match in
                Button { model.openPage(match.pageID, highlight: match.highlightedText) } label: {
                    MatchRow(match: match, color: nil)
                }
                .buttonStyle(.plain)
                .help("Open page \(match.pageNumber)")
            }
            if matches.count > Self.matchLimit {
                Button(showAll ? "Show Fewer" : "Show All \(matches.count)") { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

/// Makes or changes a stat. Claude can suggest the name, what counts, and the words from the question alone.
public struct StatEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let existing: CustomStat?
    let onSave: (CustomStat) -> Void

    public init(existing: CustomStat?, onSave: @escaping (CustomStat) -> Void) {
        self.existing = existing
        self.onSave = onSave
    }

    @ViewState private var question = ""
    @ViewState private var name = ""
    @ViewState private var unit = "times"
    @ViewState private var criteria = ""
    @ViewState private var wordsText = ""
    @ViewState private var method = CustomStat.Method.reading
    @ViewState private var isPlanning = false
    @ViewState private var planned = false
    @ViewState private var problem: String?
    @ViewState private var loaded = false

    private var words: [String] {
        wordsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !isPlanning
            && (method == .words ? !words.isEmpty : !criteria.trimmingCharacters(in: .whitespaces).isEmpty && model.hasAPIKey)
    }

    private var showsFields: Bool { existing != nil || planned || !model.hasAPIKey }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New Stat" : "Edit Stat")
                .font(.system(size: 24, weight: .semibold, design: .serif))
            VStack(alignment: .leading, spacing: 6) {
                Text("What do you want to know?").font(.subheadline.weight(.medium))
                HStack {
                    TextField("How many times did I cry?", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(plan)
                    if model.hasAPIKey {
                        Button(planned || existing != nil ? "Suggest Again" : "Suggest", action: plan)
                            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isPlanning)
                    }
                }
                Text(model.hasAPIKey ? "Claude suggests how to count it from your question alone; no journal text is sent."
                     : "Add an API key in Settings to have Claude suggest and count stats. Counting words works without one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isPlanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working out how to count it…").foregroundStyle(.secondary)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
            if showsFields { fields }
            Spacer(minLength: 0)
            HStack {
                if !showsFields, model.hasAPIKey {
                    Button("Set Up Myself") { planned = true }
                        .buttonStyle(.link)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveLabel, action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 520, height: showsFields ? 600 : 300)
        .background(Theme.card)
        .onAppear(perform: load)
    }

    private var saveLabel: String {
        guard method == .reading else { return "Save" }
        return existing == nil ? "Save and Count" : "Save"
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.subheadline.weight(.medium))
                    TextField("Cry Count", text: $name).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Counted in").font(.subheadline.weight(.medium))
                    TextField("times", text: $unit).textFieldStyle(.roundedBorder)
                }
                .frame(width: 120)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Count by").font(.subheadline.weight(.medium))
                Picker("Count by", selection: $method) {
                    Text("Claude Reading").tag(CustomStat.Method.reading)
                    Text("Words").tag(CustomStat.Method.words)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(method == .reading
                     ? "Claude reads each page's text and counts what matches. The text of read pages is sent to Anthropic, not their photos, and new pages are counted as Claude reads them."
                     : "Counts the words below as they're written, on this Mac. Instant, but it can't tell “I cried” from “she cried”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if method == .reading {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What counts").font(.subheadline.weight(.medium))
                    TextField("Each time I describe crying myself. Someone else crying doesn't count.",
                              text: $criteria, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Words").font(.subheadline.weight(.medium))
                    TextField("cried, cry*, tears, sobbed", text: $wordsText, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                    Text("Separate them with commas. End a word with * to match every word starting with it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let existing {
            question = existing.question
            name = existing.name
            unit = existing.unit
            criteria = existing.criteria
            wordsText = existing.words.joined(separator: ", ")
            method = existing.method
        } else if !model.hasAPIKey {
            method = .words
        }
    }

    private func plan() {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, model.hasAPIKey, !isPlanning else { return }
        isPlanning = true
        problem = nil
        Task {
            do {
                let suggestion = try await model.planStat(question: asked)
                name = suggestion.name
                unit = suggestion.unit.isEmpty ? "times" : suggestion.unit
                criteria = suggestion.criteria
                wordsText = suggestion.words.joined(separator: ", ")
                method = suggestion.method
                planned = true
            } catch {
                problem = error.localizedDescription
            }
            isPlanning = false
        }
    }

    private func save() {
        guard canSave else { return }
        let stat = CustomStat(id: existing?.id ?? UUID(),
                              name: name.trimmingCharacters(in: .whitespaces),
                              question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                              criteria: criteria.trimmingCharacters(in: .whitespacesAndNewlines),
                              method: method, words: words,
                              unit: unit.trimmingCharacters(in: .whitespaces).isEmpty ? "times" : unit.trimmingCharacters(in: .whitespaces).lowercased())
        model.saveStat(stat)
        if stat.method == .reading, existing == nil { model.countStat(stat.id) }
        onSave(stat)
        dismiss()
    }
}
