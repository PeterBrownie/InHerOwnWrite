import AppKit
import SwiftUI
import WriteCore

/// The view controls at the top of both readers.
private struct ReaderControls<Extra: View>: View {
    @EnvironmentObject private var model: AppModel
    @ViewBuilder let extra: Extra

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 8)

            extra

            Toggle(isOn: $model.showPhoto) {
                Label("Photo", systemImage: "photo")
            }
            .toggleStyle(.button)
            .help(model.showPhoto ? "Hide the page photo" : "Show the page photo")

            Menu {
                Toggle("Accurate Line Breaks", isOn: $model.accurateLineBreaks)
            } label: {
                Label("View", systemImage: "text.alignleft")
            }
            .fixedSize()
            .help("View options")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Flip buttons around the title, below the text like a book's page number.
private struct ReaderNavigation: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 18) {
            Button { model.flip(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canFlipBack)
                .help("Flip back (⌘[)")

            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 160)

            Button { model.flip(1) } label: { Label("Next", systemImage: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canFlipForward)
                .help("Flip forward (⌘])")
        }
        .labelStyle(.iconOnly)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct PageReader: View {
    @EnvironmentObject private var model: AppModel

    private var title: String {
        let pages = model.spreadPages
        guard let first = pages.first else { return "" }
        guard let last = pages.last, pages.count > 1 else { return "Page \(first.number)" }
        return "Pages \(first.number)–\(last.number)"
    }

    var body: some View {
        let pages = model.spreadPages
        VStack(spacing: 0) {
            ReaderControls {
                Picker("Pages shown", selection: $model.twoPageSpread) {
                    Label("One Page", systemImage: "doc").tag(false)
                    Label("Two Pages", systemImage: "book").tag(true)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .fixedSize()
                .help("Show one page or two")
            }
            Divider()
            if pages.count == 2 {
                HSplitView {
                    PageColumn(page: pages[0], isCompact: true).id(pages[0].id).frame(minWidth: 240)
                    PageColumn(page: pages[1], isCompact: true).id(pages[1].id).frame(minWidth: 240)
                }
            } else if let page = pages.first {
                PageColumn(page: page, isCompact: model.twoPageSpread).id(page.id)
            }
            Divider()
            ReaderNavigation(title: title, subtitle: pages.first.map { model.journalName($0.journalID) } ?? "")
        }
        .background(Theme.card.ignoresSafeArea())
    }
}

private struct PageColumn: View {
    @EnvironmentObject private var model: AppModel
    let page: PageInfo
    let isCompact: Bool
    @ViewState private var isMoving = false
    @ViewState private var confirmDelete = false
    @ViewState private var confirmReread = false

    private var notice: String? {
        if let problem = page.problem { return problem }
        if page.wasCutOff { return "This reading stopped early, so the end of the page may be missing." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.notice)
            }
            if !model.showPhoto {
                textPane
            } else if isCompact {
                VSplitView {
                    PhotoPane(pageID: page.id).frame(minHeight: 180)
                    textPane.frame(minHeight: 140)
                }
            } else {
                HSplitView {
                    PhotoPane(pageID: page.id).frame(minWidth: 280)
                    textPane.frame(minWidth: 320)
                }
            }
            Divider()
            pageFooter
        }
        .sheet(isPresented: $isMoving) {
            MovePageSheet(page: page).environmentObject(model)
        }
        .confirmationDialog("Delete page \(page.number)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Page", role: .destructive) { model.deletePage(id: page.id) }
        } message: {
            Text("The photo and text will be permanently removed.")
        }
        .confirmationDialog("Read page \(page.number) again?", isPresented: $confirmReread, titleVisibility: .visible) {
            Button("Read Again") { model.readAgain(page.id) }
        } message: {
            Text("The photo is sent to Anthropic again, and the new text replaces the current text, including your edits.")
        }
    }

    private var pageFooter: some View {
        HStack(spacing: 8) {
            Text("Page \(page.number)")
                .font(.subheadline.weight(.semibold))
            if page.status == .reading {
                ProgressView().controlSize(.small)
                Text("Reading…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if page.status != .done && page.status != .reading {
                Button("Read Page") { model.readAgain(page.id) }
                    .controlSize(.small)
                    .disabled(!model.hasAPIKey)
            }
            if page.status != .reading {
                Button("Read on This Mac") { model.readOnThisMac(page.id) }
                    .controlSize(.small)
                    .help("Read this page with the decision model on this Mac, and watch it work")
            } else if model.localSession?.pageID == page.id {
                Button("Watch") { model.showLocalReader() }
                    .controlSize(.small)
            }
            Menu {
                if page.status == .done {
                    Button("Read Again…") { confirmReread = true }
                        .disabled(!model.hasAPIKey)
                }
                Button("Move…") { isMoving = true }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: {
                Label("Page actions", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Page actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var textPane: some View {
        if model.accurateLineBreaks {
            JournalTextEditor(
                text: Binding(
                    get: { model.texts[page.id] ?? "" },
                    set: { model.editText($0, pageID: page.id) }
                ),
                isEditable: page.status != .reading,
                notes: model.showConfidence ? model.wordNotes(pageID: page.id) : [],
                onResolve: { note, replacement in model.resolve(note, pageID: page.id, replacement: replacement) }
            )
            .padding(4)
            .background(Theme.card)
        } else {
            // Flowing paragraphs can be edited too; each change is made to the text as written.
            JournalTextEditor(
                text: Binding(
                    get: { model.reflowedText(pageID: page.id) },
                    set: { model.editReflowed($0, pageID: page.id) }
                ),
                isEditable: page.status != .reading,
                notes: model.showConfidence ? model.reflowedWordNotes(pageID: page.id) : [],
                onResolve: { note, replacement in model.resolve(note, pageID: page.id, replacement: replacement) }
            )
            .padding(4)
            .background(Theme.card)
        }
    }
}

struct EntryReader: View {
    @EnvironmentObject private var model: AppModel
    let entry: JournalEntry

    private var position: String {
        let list = model.entries.filter { $0.journalID == entry.journalID }
        guard let index = list.firstIndex(where: { $0.id == entry.id }) else { return "Entry" }
        return "Entry \(index + 1) of \(list.count)"
    }

    private var details: String {
        var pieces = [entry.pageLabel]
        if let time = entry.timeLabel { pieces.insert(time, at: 0) }
        if entry.yearWasInferred { pieces.append("year inferred from nearby entries") }
        return pieces.joined(separator: " · ")
    }

    private var pageIDs: [UUID] {
        var seen = Set<UUID>()
        return entry.parts.map(\.pageID).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            ReaderControls { EmptyView() }
            Divider()
            if model.showPhoto {
                HSplitView {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(pageIDs, id: \.self) { EntryPhoto(pageID: $0) }
                        }
                        .padding(12)
                    }
                    .background(Theme.paper)
                    .frame(minWidth: 280)
                    entryText.frame(minWidth: 320)
                }
            } else {
                entryText
            }
            Divider()
            ReaderNavigation(title: position, subtitle: model.journalName(entry.journalID))
        }
        .background(Theme.card.ignoresSafeArea())
    }

    private var entryText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(entry.parts.enumerated()), id: \.element.id) { index, part in
                    if index > 0 || entry.parts.count > 1 {
                        HStack(spacing: 8) {
                            Text("Page \(part.pageNumber)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                    }
                    Text(model.accurateLineBreaks ? part.body : LineFlow.reflow(part.body))
                        .font(.system(size: 15, design: .serif))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit on Page \(part.pageNumber)") { model.openPage(part.pageID) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(20)
        }
        .background(Theme.card)
    }
}

private struct EntryPhoto: View {
    @EnvironmentObject private var model: AppModel
    let pageID: UUID
    @ViewState private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Color.clear.frame(height: 320)
            }
            Text("Page \(model.page(id: pageID)?.number ?? 0)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: pageID) { image = model.image(for: pageID) }
    }
}

private struct PhotoPane: View {
    @EnvironmentObject private var model: AppModel
    let pageID: UUID
    @ViewState private var image: NSImage?
    @ViewState private var scale: CGFloat = 1
    @ViewState private var gestureScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        let fitted = fittedSize(image.size, in: proxy.size)
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fitted.width * scale * gestureScale,
                                   height: fitted.height * scale * gestureScale)
                            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                    }
                }
                .gesture(MagnifyGesture()
                    .onChanged { gestureScale = $0.magnification }
                    .onEnded { value in
                        scale = min(max(scale * value.magnification, 1), 6)
                        gestureScale = 1
                    })
            }
            HStack(spacing: 0) {
                Button { scale = max(scale / 1.4, 1) } label: { Image(systemName: "minus") }
                    .help("Zoom out")
                Button { scale = min(scale * 1.4, 6) } label: { Image(systemName: "plus") }
                    .help("Zoom in")
            }
            .controlSize(.small)
            .padding(8)
        }
        .background(Theme.paper)
        .task(id: pageID) { image = model.image(for: pageID) }
    }

    private func fittedSize(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let ratio = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * ratio, height: image.height * ratio)
    }
}
