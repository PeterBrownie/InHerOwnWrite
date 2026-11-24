import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WriteCore

/// The upload screen: add a photo, fit the crop to the page, then choose the journal and page number.
/// With no journals yet, it asks only for the first journal's name until one exists.
public struct UploadSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @ViewState private var journalID: UUID?
    @ViewState private var numberText = ""
    @ViewState private var numberWasTyped = false
    @ViewState private var jpeg: Data?
    @ViewState private var preview: NSImage?
    @ViewState private var crop = PageScanResult.whole.crop
    @ViewState private var suggestion: PageScanResult?
    @AppStorage("flattenPages") private var flattenPages = true
    @ViewState private var showResult = false
    @ViewState private var result: NSImage?
    @ViewState private var isProcessing = false
    /// Quarter turns clockwise, for photos taken sideways or upside down.
    @ViewState private var quarterTurns = 0
    /// A small extra turn, in degrees clockwise, to level a tilted page.
    @ViewState private var straighten = 0.0
    /// The photo as turned, shown in the crop editor so the crop lines up with what will be saved.
    @ViewState private var turned: NSImage?
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

    private var isTaken: Bool {
        guard let journalID, let number else { return false }
        return model.isPageTaken(journalID: journalID, number: number)
    }

    private var canSave: Bool {
        journalID != nil && number != nil && jpeg != nil && !isPreparing
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
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { load(url) }
        }
        .confirmationDialog(
            "Replace page \(numberText)?",
            isPresented: $confirmReplace,
            titleVisibility: .visible
        ) {
            Button("Replace Page", role: .destructive) { save(replacing: true) }
        } message: {
            Text("The saved photo and text for this page will be permanently removed.")
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
                            if let result, !isProcessing {
                                Image(nsImage: result).resizable().scaledToFit()
                            } else {
                                ProgressView("Preparing the page…")
                            }
                        }
                        .padding(10)
                    } else {
                        CropEditor(image: turned ?? preview, crop: $crop)
                            .padding(10)
                    }
                } else if isPreparing {
                    ProgressView("Preparing photo…")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Theme.accent)
                        Text("Drop a photo of the page here")
                            .font(.system(size: 15, design: .serif))
                        Button("Choose Photo…") { isChoosingFile = true }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                load(url)
                return true
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
                .onChange(of: straighten) { refreshTurned() }
                HStack(spacing: 10) {
                    Toggle("Flatten curved pages", isOn: $flattenPages)
                        .toggleStyle(.checkbox)
                        .help("Straightens lines of writing that bend toward the fold or slope across the photo")
                    Spacer()
                    if let suggestion, crop != suggestion.crop {
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
                        Text("Drag the edges so only this page is bright.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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
                Text("Page number").font(.subheadline.weight(.medium))
                HStack {
                    TextField("1", text: numberBinding)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                    Stepper("Page number", value: stepperBinding, in: 1...Vault.maximumPageNumber)
                        .labelsHidden()
                }
                if let found = suggestion?.pageNumber, !numberWasTyped, number == found {
                    Label("Read from the photo.", systemImage: "text.viewfinder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isTaken {
                    Label("Already saved. Saving will ask before replacing it.", systemImage: "exclamationmark.triangle")
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

    private func suggestNumber() {
        if let found = suggestion?.pageNumber, (1...Vault.maximumPageNumber).contains(found) {
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

    private func load(_ url: URL) {
        problem = nil
        savedMessage = nil
        isPreparing = true
        preview = nil
        jpeg = nil
        suggestion = nil
        result = nil
        showResult = false
        quarterTurns = 0
        straighten = 0
        turned = nil
        crop = PageScanResult.whole.crop
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { () -> Data in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try PagePhoto.prepare(try Data(contentsOf: url))
                }.value
                show(prepared)
            } catch {
                problem = error.localizedDescription
                isPreparing = false
                isScanning = false
            }
        }
    }

    /// Shows a prepared photo and looks for the page in it.
    private func show(_ prepared: Data) {
        jpeg = prepared
        preview = NSImage(data: prepared)
        isPreparing = false
        isScanning = true
        Task {
            let found = await PageScan.analyze(jpeg: prepared)
            // Another photo may have been chosen meanwhile.
            guard jpeg == prepared else { return }
            suggestion = found
            crop = found.crop
            isScanning = false
            if !numberWasTyped { suggestNumber() }
        }
    }

    private var rotation: Double { Double(quarterTurns) * 90 + straighten }

    /// Crops and flattens off the main thread for the Result view.
    private func refreshResult() {
        guard showResult, let jpeg else { return }
        isProcessing = true
        let crop = crop, flatten = flattenPages, rotation = rotation
        Task {
            let processed = await Task.detached(priority: .userInitiated) {
                try? PageFlattener.process(jpeg, crop: crop, flatten: flatten, rotation: rotation)
            }.value
            // Only the newest request counts.
            guard self.jpeg == jpeg, self.crop == crop, self.flattenPages == flatten, self.rotation == rotation else { return }
            result = processed.flatMap(NSImage.init(data:))
            isProcessing = false
        }
    }

    /// Redraws the turned photo for the crop editor.
    private func refreshTurned() {
        guard let jpeg else { return }
        let rotation = rotation
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
            guard self.jpeg == jpeg, self.rotation == rotation else { return }
            turned = image
            refreshResult()
        }
    }

    /// A quarter turn carries the crop around with the photo, then looks for the page again, since a
    /// sideways photo hides it from the first look.
    private func turn(by quarters: Int) {
        guard let jpeg else { return }
        quarterTurns = (quarterTurns + quarters + 4) % 4
        crop = PagePhoto.rotatedCrop(crop, quarters: quarters)
        refreshTurned()
        let rotation = rotation
        isScanning = true
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> PageScanResult? in
                guard let turnedJPEG = try? PagePhoto.rotated(jpeg, degrees: rotation) else { return nil }
                return await PageScan.analyze(jpeg: turnedJPEG)
            }.value
            guard self.jpeg == jpeg, self.rotation == rotation else { return }
            isScanning = false
            if let found {
                suggestion = found
                crop = found.crop
                if !numberWasTyped { suggestNumber() }
            }
        }
    }

    private func save(replacing: Bool) {
        guard let journalID, let number, let jpeg else { return }
        let page: Data
        do {
            page = try PageFlattener.process(jpeg, crop: crop, flatten: flattenPages, rotation: rotation)
        } catch {
            problem = error.localizedDescription
            return
        }
        guard model.addPage(journalID: journalID, number: number, jpeg: page, replacing: replacing,
                            readLocally: model.readsLocally) else {
            problem = model.errorMessage
            model.errorMessage = nil
            return
        }
        problem = nil
        savedMessage = model.readsLocally
            ? "Page \(number) saved and being read on this Mac."
            : model.hasAPIKey
            ? "Page \(number) saved and being read."
            : "Page \(number) saved. Add an API key to read it."
        self.jpeg = nil
        preview = nil
        suggestion = nil
        result = nil
        showResult = false
        quarterTurns = 0
        straighten = 0
        turned = nil
        crop = PageScanResult.whole.crop
        numberWasTyped = false
        numberText = String(min(number + 1, Vault.maximumPageNumber))
    }
}

/// The photo with the part to keep left bright and everything else darkened. Drag an edge or corner to
/// adjust it, or drag inside to move it.
public struct CropEditor: View {
    let image: NSImage
    @Binding var crop: CGRect

    public init(image: NSImage, crop: Binding<CGRect>) {
        self.image = image
        _crop = crop
    }

    @ViewState private var dragStart: CGRect?

    /// The middle comes first so the edge and corner handles sit above it and get their drags.
    private enum Handle: CaseIterable {
        case middle, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    public var body: some View {
        GeometryReader { geometry in
            let frame = fitted(in: geometry.size)
            let keep = CGRect(x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
                              width: crop.width * frame.width, height: crop.height * frame.height)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                Path { path in
                    path.addRect(frame)
                    path.addRect(keep)
                }
                .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: keep.width, height: keep.height)
                    .offset(x: keep.minX, y: keep.minY)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                ForEach(Handle.allCases, id: \.self) { handle in
                    handleView(handle, keep: keep, frame: frame)
                }
            }
        }
    }

    private func fitted(in size: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    @ViewBuilder
    private func handleView(_ handle: Handle, keep: CGRect, frame: CGRect) -> some View {
        let point = position(of: handle, in: keep)
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
        .position(point)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStart ?? crop
                    if dragStart == nil { dragStart = crop }
                    let dx = value.translation.width / max(frame.width, 1)
                    let dy = value.translation.height / max(frame.height, 1)
                    crop = adjusted(start, handle: handle, dx: dx, dy: dy)
                }
                .onEnded { _ in dragStart = nil }
        )
        .pointerStyle(pointer(for: handle))
    }

    private func position(of handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .middle: return CGPoint(x: rect.midX, y: rect.midY)
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

    /// Moves the dragged edges, keeping the crop inside the photo and at least a tenth of it in each direction.
    private func adjusted(_ start: CGRect, handle: Handle, dx: Double, dy: Double) -> CGRect {
        let smallest = 0.1
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle == .middle {
            let x = min(max(start.minX + dx, 0), 1 - start.width)
            let y = min(max(start.minY + dy, 0), 1 - start.height)
            return CGRect(x: x, y: y, width: start.width, height: start.height)
        }
        if [.topLeft, .left, .bottomLeft].contains(handle) { minX = min(max(start.minX + dx, 0), maxX - smallest) }
        if [.topRight, .right, .bottomRight].contains(handle) { maxX = max(min(start.maxX + dx, 1), minX + smallest) }
        if [.topLeft, .top, .topRight].contains(handle) { minY = min(max(start.minY + dy, 0), maxY - smallest) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { maxY = max(min(start.maxY + dy, 1), minY + smallest) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
