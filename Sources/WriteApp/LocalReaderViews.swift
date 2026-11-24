import AppKit
import SwiftUI
import WriteCore

/// The "Reading on This Mac" window: the page with every line, word, and letter the model is looking at,
/// and each decision as it is made.
public struct LocalReaderWindow: View {
    @EnvironmentObject private var model: AppModel

    public init() {}

    public var body: some View {
        Group {
            if model.screen != .library {
                placeholder(icon: "lock", title: "Locked", detail: "Unlock the journal to read pages on this Mac.")
            } else if let session = model.localSession {
                LocalSessionView(session: session)
            } else {
                LocalReaderSetup()
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .background(Theme.paper)
        .background(WindowPrivacyMarker())
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 32, weight: .light)).foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 20, weight: .semibold, design: .serif))
            Text(detail).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the window shows before anything has been read: model status and how it works.
struct LocalReaderSetup: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reading on This Mac")
                .font(.system(size: 26, weight: .semibold, design: .serif))
            Text("""
                An experiment. Apple's Vision framework finds each line, word, and letter. Then a small \
                decision model, MiniCPM-OCR-Jev, looks at each word and keeps answering one kind of question: \
                which of these spellings, or which of these letters, is actually written here? \
                Nothing leaves this Mac.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ModelStatus()
            LocalSettingsControls()
            Text("To read a page, choose **This Mac** when adding it, or use **Read on This Mac** under a page.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }
}

struct ModelStatus: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.hasLocalRuntime {
                Label(DecisionModelFiles.runtimeHelp, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.highlight)
                    .textSelection(.enabled)
            }
            if let progress = model.modelDownloadProgress {
                HStack {
                    ProgressView(value: progress)
                    Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                    Button("Cancel") { model.cancelModelDownload() }
                }
                Text("Downloading the model (\(model.modelDownloadSize)) from Hugging Face. Only the model is downloaded; nothing is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.isModelDownloaded {
                Label("Model ready: MiniCPM-OCR-Jev, 2B parameters, about 2.7 GB of memory while reading.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                HStack {
                    Label("The model isn't downloaded yet (\(model.modelDownloadSize)).", systemImage: "arrow.down.circle")
                    Spacer()
                    Button("Download Model") { model.downloadModel() }
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

struct LocalSettingsControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Depth", selection: $model.localSettings.depth) {
                Text("Quick").tag(LocalReadDepth.quick)
                Text("Careful").tag(LocalReadDepth.thorough)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Text(model.localSettings.depth == .quick
                 ? "One question per word. Letters are checked only where the word was a close call."
                 : "Letter by letter, except words the model is already sure of (90% or more). Slower, and shows the model at work letter by letter.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(value: $model.localSettings.letterOptions, in: 2...10) {
                Text("\(model.localSettings.letterOptions) options per letter")
                    .monospacedDigit()
            }
            .frame(width: 260, alignment: .leading)
        }
    }
}

// MARK: - Live view

public struct LocalSessionView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: LocalReadSession
    @AppStorage("localLiveView") private var showLive = true

    public init(session: LocalReadSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showLive {
                HSplitView {
                    PageOverlay(session: session)
                        .frame(minWidth: 420)
                    sidePanel
                        .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
                }
            } else {
                compact
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(session.pageNumber)").font(.system(size: 17, weight: .semibold, design: .serif))
                Text(session.journalName).font(.caption).foregroundStyle(.secondary)
            }
            phaseLabel
            Spacer()
            if session.wordCount > 0 {
                ProgressView(value: Double(session.wordsDone), total: Double(max(session.wordCount, 1)))
                    .frame(width: 160)
                Text("\(session.wordsDone) of \(session.wordCount) words").font(.caption).monospacedDigit()
            }
            Toggle("Live View", isOn: $showLive).toggleStyle(.switch).controlSize(.small)
            if session.isActive {
                Button("Stop") { model.stopLocalReading() }
            } else if model.localQueueCount == 0 {
                Button("Close Reading") { model.localSession = nil }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Theme.card)
    }

    @ViewBuilder private var phaseLabel: some View {
        switch session.phase {
        case .loadingModel: Label("Loading the model…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .findingWords: Label("Finding lines and words…", systemImage: "text.viewfinder").foregroundStyle(.secondary)
        case .reading: Label("Reading", systemImage: "eye").foregroundStyle(Theme.accent)
        case .done: Label("Saved to the page", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .stopped: Label("Stopped", systemImage: "stop.circle").foregroundStyle(.secondary)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.highlight).lineLimit(2)
        }
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StatsRow(session: session)
                DecisionCard(session: session)
                TranscriptCard(session: session)
                RecentDecisions(session: session)
            }
            .padding(16)
        }
        .background(Theme.paper)
    }

    private var compact: some View {
        VStack(spacing: 16) {
            StatsRow(session: session).frame(maxWidth: 560)
            TranscriptCard(session: session).frame(maxWidth: 560)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StatsRow: View {
    @ObservedObject var session: LocalReadSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 0) {
                stat("\(session.decisions)", "decisions")
                stat(session.averageMilliseconds.map { "\(Int($0)) ms" } ?? "–", "each")
                stat("\(session.lettersChanged)", "letters fixed")
                stat(elapsed, session.finishedAt == nil ? "elapsed" : "total")
                stat(session.secondsLeft.map(Self.clock) ?? "–", "left")
            }
        }
        .padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private var elapsed: String {
        guard let start = session.startedAt else { return "–" }
        return Self.clock((session.finishedAt ?? Date()).timeIntervalSince(start))
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The question being decided right now, with each option's score filling in as the model answers.
struct DecisionCard: View {
    @ObservedObject var session: LocalReadSession

    /// Fixed sizes keep the card the same height from word to word, so the text below stays put.
    private static let cropHeight: CGFloat = 76
    private static let rowHeight: CGFloat = 26
    private static let visibleRows: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NOW DECIDING").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.white)
                if let crop = session.crop {
                    Image(decorative: crop, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(6)
                }
            }
            .frame(height: Self.cropHeight)
            Text(session.question.map(title) ?? (session.isActive ? "Waiting for the next question…" : "No question right now."))
                .font(.callout.weight(.medium))
                .foregroundStyle(session.question == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let question = session.question {
                        let maxShare = displayShares.max() ?? 1
                        ForEach(Array(question.labels.enumerated()), id: \.offset) { index, label in
                            OptionRow(label: label,
                                      candidate: question.candidates[index],
                                      share: shareFor(index),
                                      relative: maxShare > 0 ? shareFor(index).map { $0 / maxShare } : nil,
                                      isRead: index == 0,
                                      isChosen: session.choice == index,
                                      isLetter: question.letter != nil)
                                .frame(height: Self.rowHeight)
                        }
                    }
                }
            }
            .frame(height: Self.rowHeight * Self.visibleRows)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        .animation(.easeOut(duration: 0.15), value: session.probabilities)
    }

    /// Shares among the options scored so far, so bars fill in live.
    private var displayShares: [Double] {
        if let shares = session.shares { return shares }
        let known = session.probabilities.compactMap { $0 }
        let total = known.reduce(0, +)
        return session.probabilities.map { probability in
            guard let probability, total > 0 else { return 0 }
            return probability / total
        }
    }

    private func shareFor(_ index: Int) -> Double? {
        guard session.probabilities.indices.contains(index), session.probabilities[index] != nil else { return nil }
        return displayShares[safe: index]
    }

    private func title(_ question: DecisionQuestion) -> String {
        if let note = question.note { return "Re-checking a correction. \(note)" }
        let word = question.candidates.first ?? ""
        guard let letter = question.letter else { return "Which word is this?" }
        let ordinal = (letter + 1).formatted(.number)
        return "Letter \(ordinal) of “\(word)”: which is it?"
    }
}

struct OptionRow: View {
    let label: String
    let candidate: String
    let share: Double?
    let relative: Double?
    let isRead: Bool
    let isChosen: Bool
    let isLetter: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: isLetter ? 20 : 15, weight: isChosen ? .bold : .regular, design: .serif))
                .frame(width: isLetter ? 34 : 110, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line.opacity(0.5))
                    Capsule()
                        .fill(isChosen ? Theme.accent : Theme.chart.opacity(0.55))
                        .frame(width: max(geometry.size.width * (relative ?? 0), share == nil ? 0 : 3))
                }
            }
            .frame(height: 8)
            Group {
                if let share {
                    Text(share.formatted(.percent.precision(.fractionLength(0))))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption.monospacedDigit())
            .frame(width: 38, alignment: .trailing)
            Image(systemName: isChosen ? "checkmark.circle.fill" : (isRead ? "eye" : "circle"))
                .foregroundStyle(isChosen ? Theme.accent : Color.secondary.opacity(isRead ? 0.8 : 0.3))
                .help(isRead ? "What Vision read" : "")
        }
        .help(isLetter ? "Rendered as “\(candidate)”" : candidate)
    }
}

struct TranscriptCard: View {
    @ObservedObject var session: LocalReadSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TEXT SO FAR").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(session.lines.enumerated()), id: \.offset) { lineIndex, line in
                    WordFlow(spacing: 5) {
                        ForEach(Array(line.enumerated()), id: \.offset) { wordIndex, word in
                            TranscriptWord(session: session, line: lineIndex, index: wordIndex, word: word)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                legend(color: Theme.accent, "changed by the model")
                legend(color: Theme.highlight, "close call")
                legend(color: .blue, "fixed by you")
                Spacer()
                Text("Click a word to see or fix it.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private func legend(color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(color).frame(width: 12, height: 2)
            Text(text)
        }
    }
}

/// One word of the text so far. Once decided, clicking it opens a field to fix it.
struct TranscriptWord: View {
    @ObservedObject var session: LocalReadSession
    let line: Int
    let index: Int
    let word: LocalReadSession.WordState
    @ViewState private var isEditing = false
    @ViewState private var draft = ""

    private var isCurrent: Bool { session.current?.line == line && session.current?.word == index }
    private var isDecided: Bool { word.confidence != nil }
    private var isCloseCall: Bool { (word.confidence ?? 1) < LocalReader.closeCall }

    private var isSelected: Bool { session.selected == .init(line: line, word: index) }

    var body: some View {
        Text(word.text)
            .font(.system(size: 15, design: .serif))
            .foregroundStyle(color)
            .strikethrough(word.removed, color: .secondary)
            .underline(!word.removed && (word.edited || word.changed || isCloseCall),
                       pattern: isCloseCall && !word.changed && !word.edited ? .dot : .solid,
                       color: word.edited ? .blue : (word.changed ? Theme.accent : Theme.highlight))
            .padding(.horizontal, 1)
            .background(isCurrent ? Theme.accent.opacity(0.18) : (isSelected ? Color.blue.opacity(0.14) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
            .onTapGesture {
                session.selected = .init(line: line, word: index)
                guard isDecided else { return }
                draft = word.removed ? "" : word.text
                isEditing = true
            }
            .help(word.removed ? "Removed: not on the page. Click to restore it."
                  : isDecided ? "Click to see this word on the page and fix it" : "Not decided yet")
            .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                if word.removed {
                    HStack(spacing: 8) {
                        Text("“\(word.text)” will be left out when the page is saved.").font(.callout)
                        Button("Restore") {
                            session.restore(line: line, word: index)
                            isEditing = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                    .frame(width: 300, alignment: .leading)
                } else {
                    editor
                }
            }
    }

    private var editor: some View {
                VStack(alignment: .leading, spacing: 8) {
                    if word.changed && word.read != word.text {
                        HStack(spacing: 6) {
                            Text("Corrected from “\(word.read)”").font(.callout)
                            Spacer()
                            Button("Use “\(word.read)”") { save(word.read) }.controlSize(.small)
                        }
                    }
                    if let confidence = word.confidence {
                        Text("The model was \(Int((confidence * 100).rounded()))% sure of “\(word.text)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !word.otherReadings.isEmpty {
                        Text("Other readings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        WordFlow(spacing: 6) {
                            ForEach(word.otherReadings, id: \.self) { option in
                                Button(option) { save(option) }.controlSize(.small)
                            }
                        }
                    }
                    HStack {
                        TextField("Word", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit { save(draft) }
                        Button(isEmptyDraft ? "Remove" : "Fix") { save(draft) }
                            .keyboardShortcut(.defaultAction)
                            .help(isEmptyDraft ? "Leave this word out: it isn't on the page" : "Use this spelling")
                    }
                }
                .padding(12)
                .frame(width: 300, alignment: .leading)
    }

    private var isEmptyDraft: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var color: Color {
        if word.removed { return .secondary }
        if word.edited { return .blue }
        if word.changed { return Theme.accent }
        return isDecided || isCurrent ? .primary : .secondary.opacity(0.45)
    }

    private func save(_ text: String) {
        session.edit(line: line, word: index, to: text)
        isEditing = false
    }
}

/// Lays words out left to right, wrapping onto new rows like text.
struct WordFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + 2
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + 2
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct RecentDecisions: View {
    @ObservedObject var session: LocalReadSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT DECISIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
            if session.recent.isEmpty {
                Text("None yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(session.recent.prefix(14)) { item in
                HStack(spacing: 6) {
                    Text(item.word).font(.system(size: 13, design: .serif)).lineLimit(1)
                    Text(item.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("→ \(item.picked)")
                        .font(.system(size: 13, weight: item.changed ? .bold : .regular, design: .serif))
                        .foregroundStyle(item.changed ? Theme.accent : .primary)
                    Text(item.share.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(item.share < LocalReader.closeCall ? Theme.highlight : .secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

/// The page photo with lines, words, and letters drawn over it.
struct PageOverlay: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: LocalReadSession
    @ViewState private var tint: CGImage?

    /// Ink to color as words are decided: words the model changed, and words it wasn't sure of.
    private var tintRegions: [InkTint.Region] {
        guard model.showConfidence else { return [] }
        let bands = PageLayout.lineBands(session.lineBoxes)
        return session.lines.enumerated().flatMap { index, line in
            line.compactMap { word -> InkTint.Region? in
                guard let confidence = word.confidence, !word.removed, !word.edited,
                      word.changed || confidence < LocalReader.closeCall
                else { return nil }
                let color = word.changed ? InkTint.changed : InkTint.closeCall
                let box = bands.indices.contains(index) ? PageLayout.clip(word.box, to: bands[index]) : word.box
                return InkTint.Region(box: box, red: color.red, green: color.green, blue: color.blue)
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            if let photo = session.photo, photo.size.width > 0, photo.size.height > 0 {
                let frame = fit(photo.size, in: geometry.size.insetBy(18))
                ZStack(alignment: .topLeading) {
                    Image(nsImage: photo)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                    if let tint {
                        Image(decorative: tint, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .allowsHitTesting(false)
                    }
                    Canvas { context, size in draw(in: &context, size: size) }
                        .frame(width: frame.width, height: frame.height)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.paper)
        .task(id: tintRegions) {
            let regions = tintRegions
            guard !regions.isEmpty, let page = session.pageImage else {
                tint = nil
                return
            }
            // A word is decided about every half second; a short pause keeps this to one redraw at a time.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let made = await Task.detached(priority: .utility) { InkTint.overlay(for: page, regions: regions) }.value
            guard !Task.isCancelled else { return }
            tint = made
        }
    }

    private func fit(_ image: CGSize, in area: CGSize) -> CGSize {
        let scale = min(area.width / image.width, area.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        func rect(_ normalized: CGRect) -> CGRect {
            CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
                   width: normalized.width * size.width, height: normalized.height * size.height)
        }
        let accent = Theme.accent
        for box in session.lineBoxes {
            context.stroke(Path(roundedRect: rect(box).insetBy(dx: -3, dy: -3), cornerRadius: 4),
                           with: .color(.blue.opacity(0.22)), lineWidth: 1)
        }
        for (lineIndex, line) in session.lines.enumerated() {
            for (wordIndex, word) in line.enumerated() {
                let box = rect(word.box)
                let isCurrent = session.current?.line == lineIndex && session.current?.word == wordIndex
                if isCurrent {
                    context.fill(Path(roundedRect: box.insetBy(dx: -2, dy: -2), cornerRadius: 3),
                                 with: .color(accent.opacity(0.10)))
                    context.stroke(Path(roundedRect: box.insetBy(dx: -2, dy: -2), cornerRadius: 3),
                                   with: .color(accent), lineWidth: 2)
                    for (index, letter) in word.letters.enumerated() {
                        let letterBox = rect(letter)
                        var divider = Path()
                        divider.move(to: CGPoint(x: letterBox.minX, y: letterBox.minY + 2))
                        divider.addLine(to: CGPoint(x: letterBox.minX, y: letterBox.maxY - 2))
                        if index > 0 { context.stroke(divider, with: .color(accent.opacity(0.55)), lineWidth: 1) }
                        if session.question?.letter == index {
                            context.fill(Path(letterBox), with: .color(accent.opacity(0.28)))
                        }
                    }
                } else if word.removed {
                    var strike = Path()
                    strike.move(to: CGPoint(x: box.minX, y: box.midY))
                    strike.addLine(to: CGPoint(x: box.maxX, y: box.midY))
                    context.stroke(strike, with: .color(.gray.opacity(0.8)), lineWidth: 2)
                } else if let confidence = word.confidence {
                    let color: Color = word.changed ? accent : (confidence < LocalReader.closeCall ? Theme.highlight : .secondary)
                    var underline = Path()
                    underline.move(to: CGPoint(x: box.minX, y: box.maxY + 1.5))
                    underline.addLine(to: CGPoint(x: box.maxX, y: box.maxY + 1.5))
                    context.stroke(underline, with: .color(color.opacity(0.85)), lineWidth: 2)
                } else {
                    context.stroke(Path(roundedRect: box, cornerRadius: 2), with: .color(.gray.opacity(0.35)),
                                   lineWidth: 0.75)
                }
            }
        }
        // The word clicked in the text so far.
        if let selected = session.selected, let word = session.lines[safe: selected.line]?[safe: selected.word] {
            let bands = PageLayout.lineBands(session.lineBoxes)
            let box = bands.indices.contains(selected.line) ? PageLayout.clip(word.box, to: bands[selected.line]) : word.box
            let outline = Path(roundedRect: rect(box).insetBy(dx: -4, dy: -4), cornerRadius: 4)
            context.stroke(outline, with: .color(.white.opacity(0.9)), lineWidth: 4)
            context.stroke(outline, with: .color(.blue), lineWidth: 2)
        }
    }
}

private extension CGSize {
    func insetBy(_ amount: CGFloat) -> CGSize {
        CGSize(width: max(width - amount * 2, 1), height: max(height - amount * 2, 1))
    }
}

/// Keeps this window out of the snapshots macOS saves for session restore.
struct WindowPrivacyMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.isRestorable = false }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isRestorable = false
    }
}
