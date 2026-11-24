import AppKit
import SwiftUI

/// A plain-text editor whose scroll bar appears only when the text is taller than the view.
/// SwiftUI's TextEditor always shows its scroll track when "Show scroll bars" is set to Always.
struct JournalTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true

    private static let attributes: [NSAttributedString.Key: Any] = {
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
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = scrollView.documentView as! NSTextView
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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
            let length = (text as NSString).length
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                return NSValue(range: NSRange(location: min(range.location, length), length: 0))
            }
        }
        textView.isEditable = isEditable
        textView.alphaValue = isEditable ? 1 : 0.6
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
