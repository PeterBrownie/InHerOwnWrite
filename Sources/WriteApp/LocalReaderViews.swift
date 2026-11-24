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
                Label("llama.cpp isn't installed. In Terminal, run: brew install llama.cpp", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
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
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NOW DECIDING").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
            if let crop = session.crop {
                Image(decorative: crop, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxHeight: 64)
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
            }
            if let question = session.question {
                Text(title(question)).font(.callout.weight(.medium))
                let maxShare = displayShares.max() ?? 1
                ForEach(Array(question.labels.enumerated()), id: \.offset) { index, label in
                    OptionRow(label: question.letter == nil ? label : "\(label)",
                              candidate: question.candidates[index],
                              share: shareFor(index),
                              relative: maxShare > 0 ? shareFor(index).map { $0 / maxShare } : nil,
                              isRead: index == 0,
                              isChosen: session.choice == index,
                              isLetter: question.letter != nil)
                }
            } else {
                Text(session.isActive ? "Waiting for the next question…" : "No question right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
            Text(attributed)
                .font(.system(size: 15, design: .serif))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                legend(color: Theme.accent, "changed by the model")
                legend(color: .orange, "close call")
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

    private var attributed: AttributedString {
        var result = AttributedString()
        for (lineIndex, line) in session.lines.enumerated() {
            if lineIndex > 0 { result += AttributedString("\n") }
            for (wordIndex, word) in line.enumerated() {
                if wordIndex > 0 { result += AttributedString(" ") }
                var piece = AttributedString(word.text)
                if session.current?.line == lineIndex && session.current?.word == wordIndex {
                    piece.backgroundColor = Theme.accent.opacity(0.18)
                } else if word.confidence == nil {
                    piece.foregroundColor = .secondary.opacity(0.45)
                }
                if word.changed {
                    piece.foregroundColor = Theme.accent
                    piece.underlineStyle = .single
                } else if let confidence = word.confidence, confidence < LocalReader.closeCall {
                    piece.underlineStyle = Text.LineStyle(pattern: .dot, color: .orange)
                }
                result += piece
            }
        }
        return result
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
                        .foregroundStyle(item.share < LocalReader.closeCall ? .orange : .secondary)
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
    @ObservedObject var session: LocalReadSession

    var body: some View {
        GeometryReader { geometry in
            if let photo = session.photo, photo.size.width > 0, photo.size.height > 0 {
                let frame = fit(photo.size, in: geometry.size.insetBy(18))
                ZStack(alignment: .topLeading) {
                    Image(nsImage: photo)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
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
                } else if let confidence = word.confidence {
                    let color: Color = word.changed ? accent : (confidence < LocalReader.closeCall ? .orange : .green)
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
