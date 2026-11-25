import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WriteCore

/// The upload screen: add a photo, fit the crop to the page, then choose the journal and page number.
/// With no journals yet, it asks only for the first journal's name until one exists. A photo can hold one
/// page or both pages of the open journal; both are split at the fold and saved as two pages. Several
/// photos dropped at once are shown one after another, in the order they were taken.
public struct UploadSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @ViewState private var journalID: UUID?
    @ViewState private var numberText = ""
    @ViewState private var numberWasTyped = false
    @ViewState private var jpeg: Data?
    @ViewState private var preview: NSImage?
    @ViewState private var crop = PageScanResult.whole.crop
    /// What the first look found, as a frame over the photo as shown, for Reset Crop.
    @ViewState private var suggestion: PageScanResult?
    @AppStorage("flattenPages") private var flattenPages = true
    /// Whether photos show both pages of the open journal, to be split at the fold.
    @AppStorage("bothPages") private var bothPages = false
    @ViewState private var modeSetByPhoto = false
    /// Where the fold divides the crop, as a fraction of its width, when the photo shows both pages.
    @ViewState private var split = 0.5
    @ViewState private var spreadSuggestion: SpreadScanResult?
    /// The way up and tilt the first look found for this photo.
    @ViewState private var orientation: PageScan.Orientation?
    /// Counts looks at the photo, so only the newest one's result is used.
    @ViewState private var scanCount = 0
    /// Photos dropped together that are still to come, in the order they were taken.
    @ViewState private var queue: [URL] = []
    @ViewState private var batchSize = 0
    /// The photo showing, and the ones already saved or skipped, so she can go back to fix one.
    @ViewState private var current: URL?
    @ViewState private var history: [Visited] = []
    @ViewState private var pendingLayout: Layout?
    @ViewState private var showResult = false
    @ViewState private var results: [NSImage] = []
    @ViewState private var isProcessing = false
    /// Quarter turns clockwise, for photos taken sideways or upside down.
    @ViewState private var quarterTurns = 0
    /// A small extra turn, in degrees clockwise, to level a tilted page.
    @ViewState private var straighten = 0.0
    /// The photo after its quarter turns, shown in the crop editor. The small straightening turn isn't
    /// applied to it; the crop frame is turned over it instead.
    @ViewState private var turned: NSImage?
    /// The Result view's pending render, cancelled when a newer setting replaces it.
    @ViewState private var resultTask: Task<Void, Never>?
    @ViewState private var isScanning = false
    @ViewState private var isPreparing = false
    @ViewState private var isChoosingFile = false
    @ViewState private var isDropTargeted = false
    @ViewState private var isNamingJournal = false
    @ViewState private var newJournalName = ""
    @ViewState private var confirmReplace = false
    @ViewState private var problem: String?
    @ViewState private var savedMessage: String?

    /// A photo to start with, for screenshots and checks.
    private let preloaded: Data?

    public init(preloaded: Data? = nil) {
        self.preloaded = preloaded
    }

    private var number: Int? {
        Int(numberText).flatMap { (1...Vault.maximumPageNumber).contains($0) ? $0 : nil }
    }

    /// The page numbers this photo will be saved as: one, or two for both pages.
    private var numbers: [Int] {
        guard let number else { return [] }
        return bothPages ? [number, number + 1] : [number]
    }

    private var takenNumbers: [Int] {
        guard let journalID else { return [] }
        return numbers.filter { model.isPageTaken(journalID: journalID, number: $0) }
    }

    private var isTaken: Bool { !takenNumbers.isEmpty }

    private var canSave: Bool {
        journalID != nil && number != nil && jpeg != nil && !isPreparing
            && numbers.allSatisfy { $0 <= Vault.maximumPageNumber }
    }

    private var needsFirstJournal: Bool { model.journals.isEmpty }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                photoWell
                Group {
                    if needsFirstJournal { firstJournalForm } else { form }
                }
                .frame(width: 280)
            }
            .padding(24)
            Divider()
            footer
        }
        .frame(width: 820, height: 600)
        .background(Theme.card)
        .onAppear {
            setDefaults()
            if let preloaded, jpeg == nil { show(preloaded) }
        }
        .task { await Task.detached(priority: .utility) { await PageScan.warmUp() }.value }
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { start(urls) }
        }
        .confirmationDialog(
            takenNumbers.count > 1 ? "Replace pages \(takenNumbers[0]) and \(takenNumbers[1])?"
                : "Replace page \(takenNumbers.first.map(String.init) ?? numberText)?",
            isPresented: $confirmReplace,
            titleVisibility: .visible
        ) {
            Button("Replace Page", role: .destructive) { save(replacing: true) }
        } message: {
            Text(takenNumbers.count > 1 ? "The saved photos and text for these pages will be permanently removed."
                 : "The saved photo and text for this page will be permanently removed.")
        }
    }

    // MARK: Photo

    private var photoWell: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.paper)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isDropTargeted ? Theme.accent : Theme.line,
                                  style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: preview == nil ? [6, 4] : []))
                if let preview {
                    if showResult {
                        Group {
                            if !results.isEmpty, !isProcessing {
                                HStack(spacing: 6) {
                                    ForEach(results.indices, id: \.self) { index in
                                        Image(nsImage: results[index]).resizable().scaledToFit()
                                    }
                                }
                            } else {
                                ProgressView("Preparing the page…")
                            }
                        }
                        .padding(10)
                    } else {
                        CropEditor(image: turned ?? preview, crop: $crop, angle: straighten, split: bothPages ? $split : nil)
                            .padding(10)
                    }
                } else if isPreparing {
                    ProgressView("Preparing photo…")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Theme.accent)
                        Text(bothPages ? "Drop a photo of both pages here" : "Drop a photo of the page here")
                            .font(.system(size: 15, design: .serif))
                        Text("Drop several to add them in the order they were taken.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Choose Photos…") { isChoosingFile = true }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                start(urls)
            } isTargeted: { isDropTargeted = $0 }

            if preview != nil {
                HStack(spacing: 10) {
                    Picker("View", selection: $showResult) {
                        Text("Crop").tag(false)
                        Text("Result").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button { turn(by: -1) } label: { Image(systemName: "rotate.left") }
                        .help("Turn the photo a quarter turn to the left")
                    Button { turn(by: 1) } label: { Image(systemName: "rotate.right") }
                        .help("Turn the photo a quarter turn to the right")
                    Text("Straighten").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $straighten, in: -15...15, step: 0.5)
                        .frame(width: 110)
                        .help("Turn the photo a little to level a tilted page")
                    Text(straighten == 0 ? "0°" : String(format: "%+.1f°", straighten))
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .leading)
                        .onTapGesture(count: 2) { straighten = 0 }
                        .help("Double-click to reset")
                }
                .controlSize(.small)
                .onChange(of: showResult) { refreshResult() }
                .onChange(of: flattenPages) { refreshResult() }
                .onChange(of: crop) { if showResult { refreshResult() } }
                .onChange(of: split) { if showResult && bothPages { refreshResult() } }
                .onChange(of: straighten) { refreshResult(after: 0.25) }
                HStack(spacing: 10) {
                    Toggle("Flatten curved pages", isOn: $flattenPages)
                        .toggleStyle(.checkbox)
                        .help("Straightens lines of writing that bend toward the fold or slope across the photo")
                    Spacer()
                    if bothPages, let spreadSuggestion, crop != spreadSuggestion.crop || split != spreadSuggestion.split {
                        Button("Reset Crop") {
                            crop = spreadSuggestion.crop
                            split = spreadSuggestion.split
                        }
                    } else if !bothPages, let suggestion, crop != suggestion.crop {
                        Button("Reset Crop") { crop = suggestion.crop }
                    }
                    if crop != PageScanResult.whole.crop {
                        Button("Whole Photo") { crop = PageScanResult.whole.crop }
                    }
                    Button("Change…") { isChoosingFile = true }
                }
                .controlSize(.small)
                HStack(spacing: 6) {
                    if showResult {
                        Text("This is what will be saved and read.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isScanning {
                        ProgressView().controlSize(.small)
                        Text("Finding the page…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(bothPages ? "Drag the edges around both pages, and the line onto the fold."
                             : "Drag the edges so only this page is bright.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if batchSize > 1 {
                        Text("Photo \(batchSize - queue.count) of \(batchSize)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if !queue.isEmpty {
                            Button("Skip") { advance() }
                                .controlSize(.small)
                                .help("Leave this photo out and go to the next one")
                        }
                    }
                }
            }
        }
    }

    // MARK: Forms

    private var firstJournalForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start a Journal")
                .font(.system(size: 24, weight: .semibold, design: .serif))
            Text("Pages are kept in journals. Name the first one, such as the notebook's color or the year it covers.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Journal name", text: $newJournalName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createJournal)
            Button("Create Journal", action: createJournal)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(newJournalName.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a Page")
                .font(.system(size: 24, weight: .semibold, design: .serif))

            VStack(alignment: .leading, spacing: 6) {
                Text("Journal").font(.subheadline.weight(.medium))
                if isNamingJournal {
                    HStack {
                        TextField("New journal name", text: $newJournalName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(createJournal)
                        Button("Add", action: createJournal)
                            .disabled(newJournalName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button("Use an existing journal") { isNamingJournal = false }
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Picker("Journal", selection: $journalID) {
                        ForEach(model.journals) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .onChange(of: journalID) { if !numberWasTyped { suggestNumber() } }
                    Button("New journal…") { isNamingJournal = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Photo shows").font(.subheadline.weight(.medium))
                Picker("Photo shows", selection: $bothPages) {
                    Text("One page").tag(false)
                    Text("Both pages").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: bothPages) { modeChanged() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(bothPages ? "Left page number" : "Page number").font(.subheadline.weight(.medium))
                HStack {
                    TextField("1", text: numberBinding)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                    Stepper("Page number", value: stepperBinding, in: 1...Vault.maximumPageNumber)
                        .labelsHidden()
                }
                if let found = foundNumber, !numberWasTyped, number == found {
                    Label("Read from the photo.", systemImage: "text.viewfinder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if bothPages, let number {
                    Text(number < Vault.maximumPageNumber ? "The right page is saved as page \(number + 1)."
                         : "Page numbers run to \(Vault.maximumPageNumber), so there's no room for the right page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isTaken {
                    Label(takenNumbers.count > 1 ? "Both already saved. Saving will ask before replacing them."
                          : bothPages ? "Page \(takenNumbers[0]) is already saved. Saving will ask before replacing it."
                          : "Already saved. Saving will ask before replacing it.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.highlight)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Read with").font(.subheadline.weight(.medium))
                Picker("Read with", selection: $model.readsLocally) {
                    Text("Claude").tag(false)
                    Text("This Mac").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.readsLocally {
                    Text("Experimental: a small decision model reads it here, and you can watch it work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.hasLocalRuntime {
                        Label(DecisionModelFiles.runtimeHelp + " The page will be saved and can be read later.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.highlight)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)

            Group {
                if model.readsLocally {
                    Label("Encrypted and read on this Mac. Nothing leaves it.", systemImage: "lock.shield")
                } else {
                    if !model.hasAPIKey {
                        Label("No API key yet. The page will be saved and can be read later.", systemImage: "key")
                    }
                    Label("Encrypted on this Mac, then sent to Anthropic to be read.", systemImage: "lock.shield")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let savedMessage {
                Label(savedMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .lineLimit(2)
            }
            Spacer()
            if !history.isEmpty {
                Button("Back to Last Photo") { goBack() }
                    .help("Go back to the photo before this one to fix its frame, fold line, or page number")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if !needsFirstJournal {
                Button("Save Page") {
                    if isTaken { confirmReplace = true } else { save(replacing: false) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: Bindings and actions

    /// Typing a number stops the photo's page number from replacing it.
    private var numberBinding: Binding<String> {
        Binding(
            get: { numberText },
            set: { value in
                let digits = value.filter(\.isNumber)
                if digits != numberText { numberWasTyped = true }
                numberText = digits
            }
        )
    }

    private var stepperBinding: Binding<Int> {
        Binding(
            get: { number ?? 1 },
            set: {
                numberWasTyped = true
                numberText = String($0)
            }
        )
    }

    private func setDefaults() {
        journalID = model.selectedJournalID ?? model.journals.first?.id
        suggestNumber()
    }

    /// The page number read from the photo; for both pages, the left page's.
    private var foundNumber: Int? {
        bothPages ? spreadSuggestion?.leftPageNumber : suggestion?.pageNumber
    }

    private func suggestNumber() {
        if let found = foundNumber, (1...Vault.maximumPageNumber).contains(found) {
            numberText = String(found)
            return
        }
        guard let journalID else { return }
        numberText = String(model.nextPageNumber(in: journalID))
    }

    private func createJournal() {
        guard let journal = model.createJournal(name: newJournalName) else { return }
        journalID = journal.id
        newJournalName = ""
        isNamingJournal = false
        if !numberWasTyped { suggestNumber() }
    }

    /// Starts on photos dropped or chosen together, in the order they were taken.
    @discardableResult
    private func start(_ urls: [URL]) -> Bool {
        let photos = PagePhoto.sortedByDate(urls.filter { url in
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        })
        guard let first = photos.first else {
            problem = urls.isEmpty ? nil : "Those files aren't photos."
            return false
        }
        savedMessage = nil
        queue = Array(photos.dropFirst())
        history = []
        batchSize = photos.count
        load(first)
        return true
    }

    /// How a saved photo was framed, to bring back when she returns to it.
    struct Layout {
        let bothPages: Bool
        let quarterTurns: Int
        let straighten: Double
        let crop: CGRect
        let split: Double
        let numberText: String
    }

    struct Visited {
        let url: URL
        let layout: Layout?
    }

    /// Returns to the photo before this one, framed as it was saved. Saving it again asks before replacing
    /// the pages saved from it.
    private func goBack() {
        guard let last = history.popLast() else { return }
        if let current, jpeg != nil { queue.insert(current, at: 0) }
        batchSize = history.count + 1 + queue.count
        savedMessage = nil
        pendingLayout = last.layout
        load(last.url)
    }

    /// Goes on to the next photo of a batch, or clears the photo when there is none.
    private func advance(saved layout: Layout? = nil) {
        if let current { history.append(Visited(url: current, layout: layout)) }
        current = nil
        if queue.isEmpty {
            clearPhoto()
            batchSize = 0
        } else {
            load(queue.removeFirst())
        }
    }

    private func clearPhoto() {
        scanCount += 1
        resultTask?.cancel()
        jpeg = nil
        preview = nil
        suggestion = nil
        spreadSuggestion = nil
        orientation = nil
        results = []
        showResult = false
        quarterTurns = 0
        straighten = 0
        split = 0.5
        turned = nil
        crop = PageScanResult.whole.crop
        isScanning = false
    }

    private func load(_ url: URL) {
        current = url
        problem = nil
        clearPhoto()
        isPreparing = true
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { () -> Data in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try PagePhoto.prepare(try Data(contentsOf: url))
                }.value
                show(prepared)
            } catch {
                problem = "\(url.lastPathComponent): \(error.localizedDescription)"
                isPreparing = false
                isScanning = false
            }
        }
    }

    /// Shows a prepared photo, turns it upright, and looks for the page in it.
    private func show(_ prepared: Data) {
        jpeg = prepared
        preview = NSImage(data: prepared)
        isPreparing = false
        guard let layout = pendingLayout else {
            findPages(reorient: true)
            return
        }
        pendingLayout = nil
        if bothPages != layout.bothPages {
            modeSetByPhoto = true
            bothPages = layout.bothPages
        }
        quarterTurns = layout.quarterTurns
        refreshTurned()
        straighten = layout.straighten
        crop = layout.crop
        split = layout.split
        numberText = layout.numberText
        numberWasTyped = true
    }

    /// Switching between one page and both looks again. Both pages are levelled along with the fold, so the
    /// split line follows it; one page is flattened instead, so a tilt found for it isn't applied.
    private func modeChanged() {
        if modeSetByPhoto {
            modeSetByPhoto = false
            return
        }
        if bothPages, straighten == 0, let tilt = orientation?.tilt { straighten = (tilt * 2).rounded() / 2 }
        findPages(reorient: false)
    }

    /// The photo's width over its height after `turns` quarter turns.
    private func aspect(afterTurns turns: Int) -> Double {
        let size = preview?.size ?? CGSize(width: 1, height: 1)
        let width = turns % 2 == 1 ? size.height : size.width, height = turns % 2 == 1 ? size.width : size.height
        return height > 0 ? width / height : 1
    }

    /// Looks for the page, or both pages, on the photo as turned. With `reorient`, a new photo is first
    /// turned the way its writing reads.
    private func findPages(reorient: Bool) {
        guard let jpeg else { return }
        scanCount += 1
        let count = scanCount, chosen = bothPages
        let turns = quarterTurns, tilt = straighten
        isScanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                () -> (PageScan.Orientation, PageScan.Orientation, PageScanResult?, SpreadScanResult?) in
                var seen = PageScan.Orientation(quarterTurns: turns, tilt: tilt)
                var way = seen
                var spread = chosen
                if reorient {
                    seen = await PageScan.orientation(jpeg: jpeg)
                    // A new photo decides for itself whether it shows one page or both.
                    if let upright = try? PagePhoto.rotated(jpeg, degrees: Double(seen.quarterTurns) * 90 + seen.tilt) {
                        spread = await PageScan.showsTwoPages(jpeg: upright)
                    }
                    // The slider moves in half degrees.
                    way = PageScan.Orientation(quarterTurns: seen.quarterTurns,
                                               tilt: spread ? (seen.tilt * 2).rounded() / 2 : 0)
                }
                let degrees = Double(way.quarterTurns) * 90 + way.tilt
                guard let upright = try? PagePhoto.rotated(jpeg, degrees: degrees) else { return (seen, way, nil, nil) }
                if spread { return (seen, way, nil, await PageScan.analyzeSpread(jpeg: upright)) }
                return (seen, way, await PageScan.analyze(jpeg: upright), nil)
            }.value
            guard count == scanCount, self.jpeg == jpeg else { return }
            let (seen, way, page, pages) = found
            isScanning = false
            let detected = pages != nil
            if reorient, detected != bothPages {
                // The scan already looked at the photo this way, so the switch doesn't start another.
                modeSetByPhoto = true
                bothPages = detected
            }
            if reorient { orientation = seen }
            if way.quarterTurns != quarterTurns {
                quarterTurns = way.quarterTurns
                refreshTurned()
            }
            straighten = way.tilt
            // The look was at the levelled photo; the editor turns its frame over the photo instead.
            let aspect = aspect(afterTurns: way.quarterTurns)
            func frame(_ found: CGRect) -> CGRect {
                TiltedCrop.fitted(TiltedCrop.photoCrop(found, degrees: way.tilt, aspect: aspect), degrees: way.tilt, aspect: aspect)
            }
            if var page {
                page.crop = frame(page.crop)
                suggestion = page
                crop = page.crop
            }
            if var pages {
                // Fitting the frame inside the photo can shrink it; the split stays on the fold.
                let fold = pages.crop.minX + pages.crop.width * pages.split
                pages.crop = frame(pages.crop)
                let kept = TiltedCrop.canvasCrop(pages.crop, degrees: way.tilt, aspect: aspect)
                pages.split = min(max((fold - kept.minX) / max(kept.width, 1e-9), SpreadScanResult.splitLimits.lowerBound),
                                  SpreadScanResult.splitLimits.upperBound)
                spreadSuggestion = pages
                crop = pages.crop
                split = pages.split
            }
            if !numberWasTyped { suggestNumber() }
            if showResult { refreshResult() }
        }
    }

    private var rotation: Double { Double(quarterTurns) * 90 + straighten }

    /// The crop as it will be cut: the turned frame, fitted inside the photo, as an upright crop of the photo
    /// once it has been turned by `rotation`.
    private var savedCrop: CGRect {
        let aspect = aspect(afterTurns: quarterTurns)
        let frame = TiltedCrop.fitted(crop, degrees: straighten, aspect: aspect)
        return TiltedCrop.canvasCrop(frame, degrees: straighten, aspect: aspect)
    }

    /// What will be cut from the turned photo: the page, or the left and right pages.
    private var savedCrops: [CGRect] {
        guard bothPages else { return [savedCrop] }
        let (left, right) = SpreadScanResult.halves(of: savedCrop, split: split)
        return [left, right]
    }

    /// Crops and flattens off the main thread for the Result view. `delay` lets a slider settle first; a newer
    /// request cancels an older one.
    private func refreshResult(after delay: Double = 0) {
        resultTask?.cancel()
        guard showResult, let jpeg else { return }
        isProcessing = true
        let crops = savedCrops, flatten = flattenPages, rotation = rotation
        resultTask = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            let processed = await Task.detached(priority: .userInitiated) {
                crops.compactMap { try? PageFlattener.process(jpeg, crop: $0, flatten: flatten, rotation: rotation) }
            }.value
            // Only the newest request counts.
            guard !Task.isCancelled, self.jpeg == jpeg, self.savedCrops == crops, self.flattenPages == flatten,
                  self.rotation == rotation else { return }
            results = processed.compactMap(NSImage.init(data:))
            isProcessing = false
        }
    }

    /// Redraws the photo after a quarter turn for the crop editor.
    private func refreshTurned() {
        guard let jpeg else { return }
        let rotation = Double(quarterTurns) * 90
        if rotation == 0 {
            turned = nil
            refreshResult()
            return
        }
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let photo = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let turned = PagePhoto.rotated(photo, degrees: rotation)
                else { return nil }
                return NSImage(cgImage: turned, size: NSSize(width: turned.width, height: turned.height))
            }.value
            guard self.jpeg == jpeg, Double(self.quarterTurns) * 90 == rotation else { return }
            turned = image
            refreshResult()
        }
    }

    /// A quarter turn carries the crop around with the photo, then looks for the page again, since a
    /// sideways photo hides it from the first look.
    private func turn(by quarters: Int) {
        guard jpeg != nil else { return }
        quarterTurns = (quarterTurns + quarters + 4) % 4
        crop = PagePhoto.rotatedCrop(crop, quarters: quarters)
        refreshTurned()
        findPages(reorient: false)
    }

    private func save(replacing: Bool) {
        guard let journalID, let jpeg, !numbers.isEmpty else { return }
        let pages: [Data]
        do {
            pages = try savedCrops.map {
                try PageFlattener.process(jpeg, crop: $0, flatten: flattenPages, rotation: rotation)
            }
        } catch {
            problem = error.localizedDescription
            return
        }
        let numbers = numbers
        for (number, page) in zip(numbers, pages) {
            let replace = replacing && model.isPageTaken(journalID: journalID, number: number)
            guard model.addPage(journalID: journalID, number: number, jpeg: page, replacing: replace,
                                readLocally: model.readsLocally) else {
                problem = model.errorMessage
                model.errorMessage = nil
                return
            }
        }
        let saved = numbers.count > 1 ? "Pages \(numbers[0]) and \(numbers[1])" : "Page \(numbers[0])"
        advance(saved: Layout(bothPages: bothPages, quarterTurns: quarterTurns, straighten: straighten, crop: crop,
                              split: split, numberText: numberText))
        problem = nil
        savedMessage = model.readsLocally
            ? "\(saved) saved and being read on this Mac."
            : model.hasAPIKey
            ? "\(saved) saved and being read."
            : "\(saved) saved. Add an API key to read \(numbers.count > 1 ? "them" : "it")."
        numberWasTyped = false
        numberText = String(min((numbers.last ?? 0) + 1, Vault.maximumPageNumber))
    }
}

/// The photo with the part to keep left bright and everything else darkened. Drag an edge or corner to
/// adjust it, or drag inside to move it. With a straightening angle, the photo stays still and the frame
/// turns over it, so the slider costs nothing to drag; edges then move along the frame's own sides.
/// For a photo of both pages, a line across the frame marks the fold; drag it to move the split.
public struct CropEditor: View {
    let image: NSImage
    @Binding var crop: CGRect
    /// The clockwise turn, in degrees, that will level the page. The frame is drawn turned the other way.
    let angle: Double
    /// Where the fold divides the frame, as a fraction of its width; nil for a single page.
    let split: Binding<Double>?

    public init(image: NSImage, crop: Binding<CGRect>, angle: Double = 0, split: Binding<Double>? = nil) {
        self.image = image
        _crop = crop
        self.angle = angle
        self.split = split
    }

    @ViewState private var dragStart: CGRect?
    @ViewState private var splitStart: Double?

    /// The middle comes first so the edge and corner handles sit above it and get their drags.
    private enum Handle: CaseIterable {
        case middle, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private var aspect: Double {
        image.size.height > 0 ? image.size.width / image.size.height : 1
    }

    public var body: some View {
        GeometryReader { geometry in
            let frame = fitted(in: geometry.size)
            let shown = TiltedCrop.fitted(crop, degrees: angle, aspect: aspect)
            let corners = TiltedCrop.corners(shown, degrees: angle, aspect: aspect).map { point(of: $0, in: frame) }
            let keep = CGRect(x: frame.minX + shown.minX * frame.width, y: frame.minY + shown.minY * frame.height,
                              width: shown.width * frame.width, height: shown.height * frame.height)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                Path { path in
                    path.addRect(frame)
                    path.addLines(corners)
                    path.closeSubpath()
                }
                .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                Path { path in
                    path.addLines(corners)
                    path.closeSubpath()
                }
                .stroke(Color.white, lineWidth: 1.5)
                .shadow(color: .black.opacity(0.4), radius: 1)
                ForEach(Handle.allCases, id: \.self) { handle in
                    handleView(handle, keep: keep, corners: corners, frame: frame)
                }
                if let split {
                    splitView(split, corners: corners, keep: keep)
                }
            }
        }
    }

    /// The fold line and its handle. Dragging moves it along the frame's own width.
    @ViewBuilder
    private func splitView(_ split: Binding<Double>, corners: [CGPoint], keep: CGRect) -> some View {
        let fraction = split.wrappedValue
        let top = Self.between(corners[0], corners[1], fraction), bottom = Self.between(corners[3], corners[2], fraction)
        let middle = CGPoint(x: (top.x + bottom.x) / 2, y: (top.y + bottom.y) / 2)
        let frameWidth = hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y)
        Path { path in
            path.move(to: top)
            path.addLine(to: bottom)
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [7, 4]))
        .shadow(color: .black.opacity(0.5), radius: 1)
        .allowsHitTesting(false)
        Capsule()
            .fill(Color.white)
            .frame(width: 8, height: 34)
            .shadow(color: .black.opacity(0.5), radius: 1.5)
            .frame(width: 22, height: max(keep.height - 64, 40))
            .contentShape(Rectangle())
            .rotationEffect(.degrees(-angle))
            .position(middle)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = splitStart ?? fraction
                        if splitStart == nil { splitStart = start }
                        let radians = angle * .pi / 180
                        let moved = value.translation.width * cos(radians) - value.translation.height * sin(radians)
                        split.wrappedValue = min(max(start + moved / max(frameWidth, 1), SpreadScanResult.splitLimits.lowerBound),
                                                 SpreadScanResult.splitLimits.upperBound)
                    }
                    .onEnded { _ in splitStart = nil }
            )
            .pointerStyle(.columnResize)
            .help("Drag onto the fold between the pages")
    }

    private func fitted(in size: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func point(of normalized: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + normalized.x * frame.width, y: frame.minY + normalized.y * frame.height)
    }

    @ViewBuilder
    private func handleView(_ handle: Handle, keep: CGRect, corners: [CGPoint], frame: CGRect) -> some View {
        let point = position(of: handle, corners: corners)
        let isMiddle = handle == .middle
        let size: CGSize = isMiddle ? CGSize(width: max(keep.width - 40, 10), height: max(keep.height - 40, 10))
            : (handle == .top || handle == .bottom ? CGSize(width: max(keep.width - 44, 20), height: 18)
               : handle == .left || handle == .right ? CGSize(width: 18, height: max(keep.height - 44, 20))
               : CGSize(width: 26, height: 26))
        Group {
            if isMiddle {
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .frame(width: handle == .top || handle == .bottom ? 26 : (handle == .left || handle == .right ? 6 : 12),
                           height: handle == .left || handle == .right ? 26 : (handle == .top || handle == .bottom ? 6 : 12))
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
            }
        }
        .rotationEffect(.degrees(-angle))
        .position(point)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStart ?? TiltedCrop.fitted(crop, degrees: angle, aspect: aspect)
                    if dragStart == nil { dragStart = start }
                    // In units of the photo's height, the same along both axes.
                    let unit = max(frame.height, 1)
                    if let split, handle != .middle, splitStart == nil { splitStart = split.wrappedValue }
                    let moved = adjusted(start, handle: handle,
                                         dx: value.translation.width / unit, dy: value.translation.height / unit)
                    crop = moved
                    if let split, let splitStart, handle != .middle {
                        split.wrappedValue = keptFold(splitStart, from: start, to: moved)
                    }
                }
                .onEnded { _ in
                    dragStart = nil
                    splitStart = nil
                }
        )
        .pointerStyle(pointer(for: handle))
    }

    private static func between(_ a: CGPoint, _ b: CGPoint, _ fraction: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
    }

    /// The split that keeps the fold line where it was on the photo when an edge moves the frame from
    /// `start` to `moved`, both at the same angle.
    private func keptFold(_ fraction: Double, from start: CGRect, to moved: CGRect) -> Double {
        let radians = angle * .pi / 180
        // How far the frame's middle moved along its own width, in units of the photo's height.
        let dx = (moved.midX - start.midX) * aspect, dy = moved.midY - start.midY
        let shift = dx * cos(radians) - dy * sin(radians)
        let fold = (fraction - 0.5) * start.width * aspect
        let width = max(moved.width * aspect, 1e-9)
        return min(max((fold - shift) / width + 0.5, SpreadScanResult.splitLimits.lowerBound),
                   SpreadScanResult.splitLimits.upperBound)
    }

    private func position(of handle: Handle, corners: [CGPoint]) -> CGPoint {
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        let topLeft = corners[0], topRight = corners[1], bottomRight = corners[2], bottomLeft = corners[3]
        switch handle {
        case .topLeft: return topLeft
        case .top: return middle(topLeft, topRight)
        case .topRight: return topRight
        case .right: return middle(topRight, bottomRight)
        case .bottomRight: return bottomRight
        case .bottom: return middle(bottomLeft, bottomRight)
        case .bottomLeft: return bottomLeft
        case .left: return middle(topLeft, bottomLeft)
        case .middle: return middle(topLeft, bottomRight)
        }
    }

    private func pointer(for handle: Handle) -> PointerStyle? {
        switch handle {
        case .middle: return .grabIdle
        case .top: return .frameResize(position: .top)
        case .bottom: return .frameResize(position: .bottom)
        case .left: return .frameResize(position: .leading)
        case .right: return .frameResize(position: .trailing)
        case .topLeft: return .frameResize(position: .topLeading)
        case .topRight: return .frameResize(position: .topTrailing)
        case .bottomLeft: return .frameResize(position: .bottomLeading)
        case .bottomRight: return .frameResize(position: .bottomTrailing)
        }
    }

    /// Moves the dragged edges along the frame's own sides, keeping the frame inside the photo at its angle and
    /// at least a tenth of the photo in each direction. `dx` and `dy` are in units of the photo's height.
    private func adjusted(_ start: CGRect, handle: Handle, dx: Double, dy: Double) -> CGRect {
        let aspect = aspect
        func moved(_ fraction: Double) -> CGRect {
            let dx = dx * fraction, dy = dy * fraction
            if handle == .middle {
                return start.offsetBy(dx: dx / aspect, dy: dy)
            }
            // The drag in the frame's own directions: the frame is turned counterclockwise by `angle`.
            let radians = angle * .pi / 180
            let along = dx * cos(radians) - dy * sin(radians)
            let across = dx * sin(radians) + dy * cos(radians)
            var left = -start.width * aspect / 2, right = start.width * aspect / 2
            var top = -start.height / 2, bottom = start.height / 2
            let smallestWidth = 0.1 * aspect, smallestHeight = 0.1
            if [.topLeft, .left, .bottomLeft].contains(handle) { left = min(left + along, right - smallestWidth) }
            if [.topRight, .right, .bottomRight].contains(handle) { right = max(right + along, left + smallestWidth) }
            if [.topLeft, .top, .topRight].contains(handle) { top = min(top + across, bottom - smallestHeight) }
            if [.bottomLeft, .bottom, .bottomRight].contains(handle) { bottom = max(bottom + across, top + smallestHeight) }
            // The frame's new middle, turned back onto the photo.
            let shiftX = (left + right) / 2, shiftY = (top + bottom) / 2
            let centerX = start.midX * aspect + shiftX * cos(-radians) - shiftY * sin(-radians)
            let centerY = start.midY + shiftX * sin(-radians) + shiftY * cos(-radians)
            let width = right - left, height = bottom - top
            return CGRect(x: (centerX - width / 2) / aspect, y: centerY - height / 2,
                          width: width / aspect, height: height)
        }
        if handle == .middle {
            // Moving keeps the size; it stops at the photo's edges.
            let target = moved(1)
            return TiltedCrop.fitted(target, degrees: angle, aspect: aspect)
        }
        if TiltedCrop.fits(moved(1), degrees: angle, aspect: aspect) { return moved(1) }
        // As far along the drag as still fits.
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if TiltedCrop.fits(moved(middle), degrees: angle, aspect: aspect) { low = middle } else { high = middle }
        }
        return TiltedCrop.fits(moved(low), degrees: angle, aspect: aspect) ? moved(low) : start
    }
}

public struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var apiKey = ""
    @ViewState private var keyMessage: String?
    @ViewState private var password = ""
    @ViewState private var confirmation = ""
    @ViewState private var passwordMessage: String?

    public init() {}

    private var canChangePassword: Bool {
        password.count >= Vault.minimumPasswordLength && password == confirmation && !model.isWorking
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.system(size: 24, weight: .semibold, design: .serif))

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance").font(.headline)
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 10) {
                    Text("Color").foregroundStyle(.secondary)
                    ForEach(AccentChoice.allCases) { choice in
                        Button { model.accent = choice } label: {
                            Circle()
                                .fill(Theme.swatch(choice))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.primary.opacity(model.accent == choice ? 0.8 : 0), lineWidth: 2).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .help(choice.label)
                        .accessibilityLabel(choice.label)
                    }
                }
                .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("View").font(.headline)
                Toggle("Accurate Line Breaks", isOn: $model.accurateLineBreaks)
                Text("Shows each line where it falls on the page. Turn off to read in flowing paragraphs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show Reading Confidence", isOn: $model.showConfidence)
                Text("Highlights words read on this Mac that the model wasn't sure of, and underlines ones it changed. Click one to fix it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show Page Photo", isOn: $model.showPhoto)
                Toggle("Show Two Pages", isOn: $model.twoPageSpread)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Anthropic API key").font(.headline)
                Text(model.hasAPIKey
                     ? "A key is saved, encrypted with your password."
                     : "Needed to read pages. Create one at console.anthropic.com. It's stored encrypted with your password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField(model.hasAPIKey ? "Replace key" : "sk-ant-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        Task {
                            keyMessage = nil
                            if await model.saveAPIKey(apiKey) {
                                apiKey = ""
                                keyMessage = "Key saved."
                            } else {
                                keyMessage = model.errorMessage ?? "That key couldn't be saved."
                                model.errorMessage = nil
                            }
                        }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
                    if model.hasAPIKey {
                        Button("Remove", role: .destructive) {
                            model.removeAPIKey()
                            keyMessage = "Key removed."
                        }
                    }
                }
                if let keyMessage { Text(keyMessage).font(.caption).foregroundStyle(.secondary) }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Change password").font(.headline)
                SecureField("New password (\(Vault.minimumPasswordLength)+ characters)", text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField("Type it again", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    if let passwordMessage { Text(passwordMessage).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Change Password") {
                        Task {
                            let changed = await model.setNewPassword(password)
                            passwordMessage = changed ? "Password changed." : (model.errorMessage ?? "Couldn't change it.")
                            model.errorMessage = nil
                            if changed {
                                password = ""
                                confirmation = ""
                            }
                        }
                    }
                    .disabled(!canChangePassword)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.card)
    }
}
