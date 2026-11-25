import SwiftUI

// "Hide Entry Text" hides what she wrote, and covers page text and photos, so Analysis can be shown to someone
// without them reading the journal. Counts, charts, top words, and names stay readable. No password: it's a
// screen-sharing courtesy, not a lock.

extension View {
    /// Hides journal writing shown as plain text, such as a snippet or a list preview, while text is hidden:
    /// the words become soft gray bars, which can't be read however the window is shown or captured.
    func entryText() -> some View { modifier(EntryTextBlur()) }

    /// Covers a page's text editor or photo while text is hidden. They're AppKit views, which SwiftUI can't
    /// blur or redact, so they get a solid cover that also keeps clicks from reaching them.
    func entryCover() -> some View { modifier(EntryTextCover()) }
}

private struct EntryTextBlur: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .redacted(reason: model.hidesEntryText ? .placeholder : [])
            .blur(radius: model.hidesEntryText ? 2 : 0)
            .accessibilityHidden(model.hidesEntryText)
    }
}

private struct EntryTextCover: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(model.hidesEntryText)
            .overlay {
                if model.hidesEntryText {
                    ZStack {
                        Rectangle().fill(Theme.card)
                        Label("Entry text hidden", systemImage: "eye.slash")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {}
                }
            }
    }
}
