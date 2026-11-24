import AppKit

/// Asks macOS's spell checker what a misread word might be. Vision's other readings and look-alike letters
/// can only swap one letter for another, so a reading with a letter missing or extra, like a dropped "c" in a
/// long word, has no right option among them. The spell checker's guesses fill that gap; they are then held
/// to the same rules as every other option.
public enum SpellingSuggestions {
    /// At most this many guesses are offered for one word.
    public static let limit = 3

    /// Guesses for a word that isn't in the dictionary, most likely first. The spell checker is meant to be
    /// used from the main thread.
    @MainActor
    public static func guesses(for word: String) -> [String] {
        guard word.count >= 3, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return [] }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        var found: [String] = []
        if let correction = checker.correction(forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) {
            found.append(correction)
        }
        found += checker.guesses(forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
        return usable(found, for: word)
    }

    /// Single words close to what was read: no spaces or hyphens, and at most two letters added, dropped, or
    /// changed. Keeps a leading capital.
    public static func usable(_ guesses: [String], for word: String) -> [String] {
        var kept: [String] = []
        for guess in guesses {
            guard guess.allSatisfy({ $0.isLetter || $0 == "'" }),
                  editDistance(guess.lowercased(), word.lowercased()) <= 2
            else { continue }
            var shaped = guess
            if word.first?.isUppercase == true, let first = guess.first, first.isLowercase {
                shaped = first.uppercased() + guess.dropFirst()
            }
            if shaped != word, !kept.contains(shaped) { kept.append(shaped) }
            if kept.count == limit { break }
        }
        return kept
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, right) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
