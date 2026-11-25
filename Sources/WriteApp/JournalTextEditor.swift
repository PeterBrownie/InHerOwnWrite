import AppKit
import SwiftUI
import WriteCore

/// A plain-text editor whose scroll bar appears only when the text is taller than the view.
/// SwiftUI's TextEditor always shows its scroll track when "Show scroll bars" is set to Always.
/// Words a reading on this Mac changed or wasn't sure of can be marked; clicking one offers corrections.
struct JournalTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    /// Marked words: green where the model wasn't sure, underlined where it changed what Vision read.
    var notes: [(note: WordNote, range: NSRange)] = []
    /// Called with a replacement, or nil to keep the word as read.
    var onResolve: (WordNote, String?) -> Void = { _, _ in }
    /// Called with the marked word just clicked, to show it on the photo, or nil when a click lands elsewhere.
    var onFocus: (WordNote?) -> Void = { _ in }
    /// Words being searched for, highlighted wherever they appear; the first is scrolled into view.
    var find = ""

    static let attributes: [NSAttributedString.Key: Any] = {
        let base = NSFont.systemFont(ofSize: 15)
        let font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 15) } ?? base
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        return [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NotedTextView(usingTextLayoutManager: false)
        textView.coordinator = context.coordinator
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        // Her spelling and punctuation are kept exactly as written.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.writingToolsBehavior = .none
        textView.typingAttributes = Self.attributes
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        textView.isEditable = isEditable
        context.coordinator.notes = notes
        context.coordinator.onResolve = onResolve
        context.coordinator.onFocus = onFocus
        context.coordinator.find = find
        context.coordinator.mark(textView)
        context.coordinator.revealFound(in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onResolve = onResolve
        context.coordinator.onFocus = onFocus
        guard let textView = scrollView.documentView as? NSTextView else { return }
        var needsMarking = context.coordinator.notes.map(\.range) != notes.map(\.range)
            || context.coordinator.notes.map(\.note) != notes.map(\.note)
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
            let length = (text as NSString).length
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                return NSValue(range: NSRange(location: min(range.location, length), length: 0))
            }
            needsMarking = true
        }
        context.coordinator.notes = notes
        let findChanged = context.coordinator.find != find
        context.coordinator.find = find
        if needsMarking || findChanged { context.coordinator.mark(textView) }
        if findChanged { context.coordinator.revealFound(in: textView) }
        textView.isEditable = isEditable
        textView.alphaValue = isEditable ? 1 : 0.6
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var notes: [(note: WordNote, range: NSRange)] = []
        var onResolve: (WordNote, String?) -> Void = { _, _ in }
        var onFocus: (WordNote?) -> Void = { _ in }
        var find = ""

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        /// Paints the marks as display-only attributes; the saved text stays plain.
        func mark(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            for key in [NSAttributedString.Key.backgroundColor, .underlineStyle, .underlineColor, .toolTip] {
                storage.removeAttribute(key, range: whole)
            }
            for range in TextSearch.ranges(of: find, in: storage.string) where NSMaxRange(range) <= storage.length {
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.45), range: range)
            }
            for (note, range) in notes where NSMaxRange(range) <= storage.length {
                let percent = Int((note.confidence * 100).rounded())
                if note.wasChanged {
                    storage.addAttributes([
                        .underlineStyle: NSUnderlineStyle.thick.rawValue,
                        .underlineColor: NSColor(Theme.accent),
                        .toolTip: "Changed from “\(note.read)” when read on this Mac (\(percent)% sure). Click for other readings.",
                    ], range: range)
                }
                if note.confidence < LocalReader.closeCall {
                    storage.addAttribute(.backgroundColor, value: NSColor(Theme.highlight).withAlphaComponent(0.28), range: range)
                    if !note.wasChanged {
                        storage.addAttribute(.toolTip, value: "Read on this Mac with \(percent)% confidence. Click for other readings.",
                                             range: range)
                    }
                }
            }
            storage.endEditing()
        }

        /// Scrolls the first match into view, once the text has been laid out.
        func revealFound(in textView: NSTextView) {
            guard let first = TextSearch.ranges(of: find, in: textView.string).first else { return }
            DispatchQueue.main.async { textView.scrollRangeToVisible(first) }
        }

        func note(at index: Int) -> (note: WordNote, range: NSRange)? {
            notes.first { NSLocationInRange(index, $0.range) }
        }

        /// The quick fix menu for a marked word.
        func menu(for found: (note: WordNote, range: NSRange), in textView: NSTextView) -> NSMenu {
            let menu = NSMenu()
            let note = found.note
            let percent = Int((note.confidence * 100).rounded())
            let heading = note.wasChanged
                ? "Corrected from “\(note.read)” (\(percent)% sure of “\(note.text)”)"
                : "\(percent)% sure of “\(note.text)”"
            let title = NSMenuItem(title: heading, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
            for option in note.options {
                let title = option == note.read ? "Restore the original, “\(option)”" : "Replace with “\(option)”"
                menu.addItem(ActionItem(title: title) { [weak self] in self?.onResolve(note, option) })
            }
            menu.addItem(ActionItem(title: "Keep “\(note.text)”") { [weak self] in self?.onResolve(note, nil) })
            menu.addItem(.separator())
            menu.addItem(ActionItem(title: "Type a Correction…") { [weak self, weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(found.range)
                self?.onResolve(note, nil)
            })
            return menu
        }
    }
}

/// Opens the quick fix menu when a marked word is clicked; everywhere else it edits as usual.
final class NotedTextView: NSTextView {
    weak var coordinator: JournalTextEditor.Coordinator?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if event.clickCount == 1, let coordinator, isEditable,
           let found = coordinator.note(at: index) ?? coordinator.note(at: index - 1),
           let rect = firstRect(for: found.range), rect.insetBy(dx: -2, dy: -3).contains(point) {
            coordinator.onFocus(found.note)
            let menu = coordinator.menu(for: found, in: self)
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: self)
            return
        }
        coordinator?.onFocus(nil)
        super.mouseDown(with: event)
    }

    /// The word's rectangle in this view, so only clicks on the word itself open the menu.
    private func firstRect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
