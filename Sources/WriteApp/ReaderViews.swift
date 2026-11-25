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
                // Two equal halves, like an open book. A draggable split moved its middle whenever either
                // page's text changed size.
                GeometryReader { proxy in
                    let half = max((proxy.size.width - 1) / 2, 0)
                    HStack(spacing: 0) {
                        PageColumn(page: pages[0], isCompact: true).id(pages[0].id)
                            .frame(width: half)
                        Divider()
                        PageColumn(page: pages[1], isCompact: true).id(pages[1].id)
                            .frame(width: half)
                    }
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

/// "2 people" in a page's footer: the names on the page, with a mark when one could mean more than one
/// person. Clicking it lists them, so each can be told apart with a last name or initial.
private struct PeopleButton: View {
    @EnvironmentObject private var model: AppModel
    let page: PageInfo
    @ViewState private var isShowing = false

    var body: some View {
        let people = model.people.people(on: page)
        if !people.isEmpty {
            let unsure = people.contains { $0.resolution.isUnsure }
            Button { isShowing.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                    Text(people.count == 1 ? "1 person" : "\(people.count) people")
                    if unsure {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
            }
            .controlSize(.small)
            .help(unsure ? "A name on this page could mean more than one person; click to say which"
                         : "The people named on this page, and who each name means")
            .popover(isPresented: $isShowing, arrowEdge: .top) {
                PeopleOnPage(page: page, people: model.people).environmentObject(model)
            }
        }
    }
}

/// The names on one page, each with who it means. A name can be given a last name or initial ("Hannah K."), or
/// matched to someone already known by one, so two people who share a first name are counted apart.
public struct PeopleOnPage: View {
    let page: PageInfo
    let directory: PeopleDirectory

    public init(page: PageInfo, people: PeopleDirectory) {
        self.page = page
        directory = people
    }

    public var body: some View {
        let people = directory.people(on: page)
        VStack(alignment: .leading, spacing: 10) {
            Text("People on page \(page.number)").font(.headline)
            Text("Who each name here means. To tell apart two people with the same first name, give each a last name or initial.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(people, id: \.written) { item in
                        PersonRow(page: page, written: item.written, resolution: item.resolution,
                                  choices: directory.people(sharingFirstNameWith: item.written))
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 380)
    }
}

private struct PersonRow: View {
    @EnvironmentObject private var model: AppModel
    let page: PageInfo
    let written: String
    let resolution: PersonResolution
    /// Others known by this first name.
    let choices: [String]
    @ViewState private var draft: String?

    private var chosen: String? { page.structure?.people?[PeopleDirectory.key(written)] }

    /// Saves who the name means; nil or an empty name goes back to the name as written.
    private func save(_ person: String?) {
        let trimmed = person?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty ? nil : trimmed
        draft = nil
        guard value != chosen else { return }
        model.setPerson(pageID: page.id, written: written, person: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(written)
                    .font(.system(size: 14, design: .serif))
                    .lineLimit(1)
                    .frame(width: 100, alignment: .leading)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                TextField(written, text: Binding(get: { draft ?? chosen ?? "" }, set: { draft = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let draft { save(draft) } }
                    .help("A fuller name for who \(written) means on this page, like \(written) K.; leave empty for just \(written)")
                Menu {
                    ForEach(choices, id: \.self) { choice in
                        Toggle(choice, isOn: Binding(get: { chosen == choice }, set: { _ in save(choice) }))
                    }
                    if !choices.isEmpty { Divider() }
                    Button("Just \(written)") { save(nil) }
                        .disabled(chosen == nil)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(choices.isEmpty && chosen == nil ? 0 : 1)
                .disabled(choices.isEmpty && chosen == nil)
                .help("Choose someone already known by this first name")
            }
            if case .unsure(_, let options) = resolution {
                Label("Unsure which: \(Self.either(options))",
                      systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 108)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { if let draft { save(draft) } }
    }

    private static func either(_ names: [String]) -> String {
        switch names.count {
        case 0: return "more than one person"
        case 1: return names[0]
        case 2: return "\(names[0]) or \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", or " + names.last!
        }
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
            Button("Read Again with Claude") { model.readAgain(page.id) }
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
            if page.status != .reading {
                PeopleButton(page: page)
            }
            if page.status != .done && page.status != .reading {
                Button("Read with Claude") { model.readAgain(page.id) }
                    .controlSize(.small)
                    .disabled(!model.hasAPIKey)
                    .help("Send the photo to Claude to read")
            }
            if page.status != .reading {
                if model.hasLocalProgress(page.id) {
                    Button("Resume on This Mac") { model.readOnThisMac(page.id) }
                        .controlSize(.small)
                        .help("Pick up the reading on this Mac where it stopped")
                } else if page.status != .done {
                    Button("Read on This Mac") { model.readOnThisMac(page.id) }
                        .controlSize(.small)
                        .help("Read this page with the decision model on this Mac, and watch it work")
                }
            } else if model.localSession?.pageID == page.id {
                Button("Watch") { model.showLocalReader() }
                    .controlSize(.small)
            }
            Menu {
                if page.status == .done {
                    Button("Read Again with Claude…") { confirmReread = true }
                        .disabled(!model.hasAPIKey)
                    if !model.hasLocalProgress(page.id) {
                        Button("Read Again on This Mac") { model.readOnThisMac(page.id) }
                    }
                }
                if model.hasLocalProgress(page.id) && page.status != .reading {
                    Button("Start Reading on This Mac Over") { model.readOnThisMac(page.id, startOver: true) }
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
                onResolve: { note, replacement in model.resolve(note, pageID: page.id, replacement: replacement) },
                onFocus: { note in model.focusWord(note, pageID: page.id) },
                find: model.findText
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
                onResolve: { note, replacement in model.resolve(note, pageID: page.id, replacement: replacement) },
                onFocus: { note in model.focusWord(note, pageID: page.id) },
                find: model.findText
            )
            .padding(4)
            .background(Theme.card)
        }
    }
}

struct EntryReader: View {
    @EnvironmentObject private var model: AppModel
    let entry: JournalEntry
    @ViewState private var isChangingDate = false

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

    /// The part's text with what's being searched for highlighted.
    private func highlighted(_ text: String) -> AttributedString {
        var styled = AttributedString(text)
        for range in TextSearch.ranges(of: model.findText, in: text) {
            guard let found = Range(range, in: text),
                  let lower = AttributedString.Index(found.lowerBound, within: styled),
                  let upper = AttributedString.Index(found.upperBound, within: styled) else { continue }
            styled[lower..<upper].backgroundColor = Color.yellow.opacity(0.45)
        }
        return styled
    }

    private var entryText: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.title)
                            .font(.system(size: 22, weight: .semibold, design: .serif))
                        Spacer()
                        let starred = model.isStarred(entry)
                        Button { model.toggleStar(entry) } label: {
                            Label(starred ? "Starred" : "Star", systemImage: starred ? "star.fill" : "star")
                                .foregroundStyle(starred ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help(starred ? "Remove the star" : "Star this entry")
                        Button("Change Date…") { isChangingDate = true }
                            .buttonStyle(.link)
                            .font(.callout)
                            .popover(isPresented: $isChangingDate, arrowEdge: .bottom) {
                                EntryDateEditor(entry: entry) { isChangingDate = false }
                                    .environmentObject(model)
                            }
                    }
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
                    Text(highlighted(model.accurateLineBreaks ? part.body : LineFlow.reflow(part.body)))
                        .font(.system(size: 15, design: .serif))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(part.id)
                    Button("Edit on Page \(part.pageNumber)") {
                        model.openPage(part.pageID, highlight: model.findText.isEmpty ? nil : model.findText)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .padding(20)
        }
        .background(Theme.card)
        .task(id: "\(entry.id)|\(model.findText)") {
            // Bring the first part that mentions the search into view.
            let find = model.findText
            guard !find.isEmpty, entry.parts.count > 1,
                  let part = entry.parts.first(where: { TextSearch.contains($0.body, find) }) else { return }
            scroller.scrollTo(part.id, anchor: .top)
        }
        }
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
    @ViewState private var tint: CGImage?
    @ViewState private var scale: CGFloat = 1
    @ViewState private var gestureScale: CGFloat = 1

    /// Ink to color: words a reading on this Mac changed, and words it wasn't sure of.
    private var tintRegions: [InkTint.Region] {
        guard model.showConfidence else { return [] }
        return model.wordNotes(pageID: pageID).compactMap { item -> InkTint.Region? in
            guard let outline = item.note.outline else { return nil }
            let color = item.note.wasChanged ? InkTint.changed : InkTint.closeCall
            return InkTint.Region(outline: outline, red: color.red, green: color.green, blue: color.blue)
        }
    }

    private var focused: [CGPoint]? {
        guard let word = model.focusedWord, word.pageID == pageID else { return nil }
        return word.note.outline
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        let fitted = fittedSize(image.size, in: proxy.size)
                        let size = CGSize(width: fitted.width * scale * gestureScale,
                                          height: fitted.height * scale * gestureScale)
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                            if let tint {
                                Image(decorative: tint, scale: 1)
                                    .resizable()
                                    .interpolation(.high)
                            }
                            if let focused {
                                WordOutline(corners: focused)
                            }
                        }
                        .frame(width: size.width, height: size.height)
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
        .task(id: TintKey(image: image.map(ObjectIdentifier.init), regions: tintRegions)) {
            let regions = tintRegions
            guard !regions.isEmpty, let photo = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                tint = nil
                return
            }
            let made = await Task.detached(priority: .userInitiated) {
                InkTint.overlay(for: photo, regions: regions)
            }.value
            guard !Task.isCancelled else { return }
            tint = made
        }
    }

    private struct TintKey: Equatable {
        let image: ObjectIdentifier?
        let regions: [InkTint.Region]
    }

    private func fittedSize(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let ratio = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * ratio, height: image.height * ratio)
    }
}

/// A word outlined on the page photo, with corners normalized to the photo.
struct WordOutline: View {
    let corners: [CGPoint]

    var body: some View {
        GeometryReader { proxy in
            let points = corners.map { CGPoint(x: $0.x * proxy.size.width, y: $0.y * proxy.size.height) }
            let shape = Path { path in
                guard let first = points.first else { return }
                // A little room around the word, out from its middle.
                let middle = CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                                     y: points.map(\.y).reduce(0, +) / Double(points.count))
                func out(_ point: CGPoint) -> CGPoint {
                    let dx = point.x - middle.x, dy = point.y - middle.y
                    let length = max(hypot(dx, dy), 1)
                    return CGPoint(x: point.x + dx / length * 5, y: point.y + dy / length * 5)
                }
                path.move(to: out(first))
                for point in points.dropFirst() { path.addLine(to: out(point)) }
                path.closeSubpath()
            }
            shape.stroke(Color.white.opacity(0.9), lineWidth: 4)
            shape.stroke(Color.blue, lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

/// Sets an entry's date and time by hand. The change is written as the entry's date line on its first page.
private struct EntryDateEditor: View {
    @EnvironmentObject private var model: AppModel
    let entry: JournalEntry
    let done: () -> Void
    @ViewState private var date = Date()
    @ViewState private var time = Date()
    @ViewState private var includesTime = false

    init(entry: JournalEntry, done: @escaping () -> Void) {
        self.entry = entry
        self.done = done
        var calendar = Calendar.current
        calendar.timeZone = .current
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        let parts = entry.time?.split(separator: ":").compactMap { Int($0) } ?? []
        let day = calendar.date(from: DateComponents(year: entry.year ?? today.year, month: entry.month ?? today.month,
                                                     day: entry.day ?? today.day)) ?? Date()
        let clock = calendar.date(bySettingHour: parts.first ?? 12, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: day) ?? day
        _date = ViewState(wrappedValue: day)
        _time = ViewState(wrappedValue: clock)
        _includesTime = ViewState(wrappedValue: entry.time != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Entry date").font(.headline)
            DatePicker("Date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.field)
            Toggle("Time", isOn: $includesTime)
            if includesTime {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field)
                    .labelsHidden()
            }
            Text(entry.heading == nil
                 ? "A date line is added at the start of this entry on page \(entry.firstPage)."
                 : "The entry's date line on page \(entry.firstPage) is rewritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Set Date") {
                    let calendar = Calendar.current
                    let day = calendar.dateComponents([.year, .month, .day], from: date)
                    let clock = calendar.dateComponents([.hour, .minute], from: time)
                    if let year = day.year, let month = day.month, let dayNumber = day.day {
                        model.setDate(of: entry, year: year, month: month, day: dayNumber,
                                      hour: includesTime ? clock.hour : nil, minute: clock.minute ?? 0)
                    }
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
