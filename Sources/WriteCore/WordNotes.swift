import CoreGraphics
import Foundation

/// A word the decision model changed, or wasn't sure of, with the other spellings it weighed. Words are
/// found by line and position, so a note stays attached while the text is edited elsewhere, and quietly
/// disappears once its word is changed.
public struct WordNote: Codable, Hashable, Sendable, Identifiable {
    /// The line in the page text, counting from 0.
    public var line: Int
    /// The word's position in that line, counting space-separated words from 0.
    public var word: Int
    /// The word as saved.
    public var text: String
    /// What Vision first read.
    public var read: String
    /// Other spellings to offer, most likely first.
    public var options: [String]
    /// The model's share for the saved word, from 0 to 1.
    public var confidence: Double
    /// Where the word is written on the page photo as saved: four corners, normalized with the origin at the
    /// top left, clockwise from the top left. Missing on notes saved before words were placed.
    public var outline: [CGPoint]?

    public init(line: Int, word: Int, text: String, read: String, options: [String], confidence: Double,
                outline: [CGPoint]? = nil) {
        self.line = line
        self.word = word
        self.text = text
        self.read = read
        self.options = options
        self.confidence = confidence
        self.outline = outline
    }

    public var id: String { "\(line):\(word):\(text)" }
    public var wasChanged: Bool { text != read }

    /// Where each note's word is in `text` now, as UTF-16 ranges for text views. A note whose word was
    /// edited away isn't returned.
    public static func locate(_ notes: [WordNote], in text: String) -> [(note: WordNote, range: NSRange)] {
        let lines = EntryBuilder.lines(of: text)
        var lineStarts: [Int] = []
        var offset = 0
        for line in lines {
            lineStarts.append(offset)
            offset += (line as NSString).length + 1
        }
        return notes.compactMap { note in
            guard lines.indices.contains(note.line) else { return nil }
            let line = lines[note.line] as NSString
            let words = tokens(in: line)
            // Its own place first; if words were added or removed earlier in the line, the same word nearby.
            let match = words.indices.contains(note.word) && line.substring(with: words[note.word]) == note.text
                ? words[note.word]
                : words.enumerated()
                    .filter { line.substring(with: $0.element) == note.text }
                    .min { abs($0.offset - note.word) < abs($1.offset - note.word) }?.element
            guard let match else { return nil }
            return (note, NSRange(location: lineStarts[note.line] + match.location, length: match.length))
        }
    }

    /// The text with one note's word replaced.
    public static func replacing(_ note: WordNote, with replacement: String, in text: String) -> String? {
        guard let found = locate([note], in: text).first else { return nil }
        return (text as NSString).replacingCharacters(in: found.range, with: replacement)
    }

    private static func tokens(in line: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start: Int?
        for index in 0..<line.length {
            let isSpace = line.character(at: index) == 32 || line.character(at: index) == 9
            if isSpace {
                if let open = start { ranges.append(NSRange(location: open, length: index - open)) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let open = start { ranges.append(NSRange(location: open, length: line.length - open)) }
        return ranges
    }
}
