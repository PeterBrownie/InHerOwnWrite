import Foundation

/// Proposes the options the decision model chooses between: letters that are easy to confuse in
/// handwriting, and real words one confusion away from what Vision read.
public struct CandidateMaker: Sendable {
    /// Letters often mistaken for each other in handwriting, most likely first.
    static let lookAlikes: [Character: [String]] = [
        "a": ["o", "u", "e", "d", "c", "q", "n", "s", "g"],
        "b": ["h", "l", "k", "f", "d", "p", "6", "t", "o"],
        "c": ["e", "o", "a", "r", "i", "s", "l", "u", "x"],
        "d": ["a", "cl", "ol", "b", "o", "q", "g", "l", "t"],
        "e": ["c", "o", "a", "i", "l", "r", "s", "u", "n"],
        "f": ["t", "r", "l", "j", "b", "h", "k", "s", "p", "g"],
        "g": ["y", "q", "j", "a", "z", "s", "o", "p", "f"],
        "h": ["k", "b", "n", "li", "l", "m", "r", "u", "f"],
        "i": ["l", "e", "j", "t", "r", "c", "u", "y", "1"],
        "j": ["i", "y", "g", "f", "l", "q", "z", "p", "s"],
        "k": ["h", "b", "l", "le", "x", "f", "t", "r", "n"],
        "l": ["t", "i", "e", "b", "f", "k", "h", "1", "d"],
        "m": ["n", "w", "rn", "u", "in", "nn", "r", "v", "h"],
        "n": ["m", "u", "r", "h", "v", "a", "ri", "s", "o"],
        "o": ["a", "e", "u", "c", "d", "0", "v", "s", "n"],
        "p": ["f", "q", "g", "j", "b", "y", "n", "r", "s"],
        "q": ["g", "a", "y", "p", "d", "o", "j", "z", "u"],
        "r": ["n", "v", "s", "e", "i", "c", "t", "x", "u"],
        "s": ["r", "a", "e", "o", "z", "c", "n", "g", "5"],
        "t": ["l", "f", "i", "k", "h", "x", "r", "e", "d"],
        "u": ["n", "v", "a", "w", "o", "ee", "ii", "e", "r"],
        "v": ["u", "r", "w", "n", "y", "x", "b", "o", "s"],
        "w": ["m", "u", "v", "ur", "uu", "n", "vv", "o", "e"],
        "x": ["r", "y", "k", "t", "v", "z", "n", "s", "c"],
        "y": ["g", "q", "j", "z", "v", "u", "f", "p", "x"],
        "z": ["g", "y", "s", "j", "x", "r", "q", "e", "2"],
        "0": ["o", "6", "8", "9", "a", "d", "u", "c", "3"],
        "1": ["l", "7", "i", "I", "t", "4", "/", "2", "j"],
        "2": ["z", "3", "7", "a", "q", "d", "1", "5", "e"],
        "3": ["5", "8", "2", "9", "z", "s", "b", "7", "e"],
        "4": ["9", "1", "7", "u", "y", "a", "h", "6", "q"],
        "5": ["s", "3", "6", "8", "9", "b", "a", "e", "2"],
        "6": ["b", "0", "5", "8", "a", "g", "4", "9", "e"],
        "7": ["1", "2", "9", "4", "t", "f", "j", "z", "y"],
        "8": ["3", "0", "6", "9", "5", "s", "a", "g", "b"],
        "9": ["g", "q", "4", "7", "a", "8", "0", "3", "y"],
    ]

    private let words: Set<String>

    public init(words: Set<String>) {
        self.words = words
    }

    /// The system word list plus every word already in her journals.
    public static func loadDictionary(extraText: [String] = []) -> Set<String> {
        var words = Set<String>()
        if let list = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
            // The system list is an old, complete dictionary full of rare short words ("nou", "sov") that
            // would make look-alikes seem real, so short words must also be common ones.
            for line in list.split(separator: "\n") {
                let word = line.lowercased()
                if word.count > 3 || commonShortWords.contains(word) { words.insert(word) }
            }
        }
        words.formUnion(commonShortWords)
        // The word list has no contractions, but lists some without their apostrophe ("didnt"), which would
        // make the fix look like a swap between two real words. Bare forms that are words of their own stay.
        let ownWords: Set<String> = ["its", "were", "well", "ill", "hell", "shell", "shed", "wed", "lets", "id"]
        for contraction in contractions {
            let bare = contraction.replacingOccurrences(of: "'", with: "")
            if !ownWords.contains(bare) { words.remove(bare) }
        }
        words.formUnion(contractions)
        // Dates are common in journals, and the word list leaves out their abbreviations.
        words.formUnion(["jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
                         "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
                         "am", "pm", "ok", "okay"])
        for text in extraText {
            for token in text.split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
                words.insert(token.lowercased())
            }
        }
        return words
    }

    public func isWord(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }

    /// How many times higher than the current reading another option must score to replace it. The model
    /// compares shapes, not meaning, and its small preferences are often wrong. In testing it turned "pm"
    /// into "prn" and swapped real words for other real words, like "bread" for "broad", while its best
    /// work was turning non-words into words, like "tbe" into "the". So a real word is never changed
    /// into a non-word, a swap between two real words needs strong evidence, and a fix that makes a non-word
    /// into a real word needs the least.
    public func switchMargin(from current: String, to option: String) -> Double {
        let wasWord = isWord(current), becomesWord = isWord(option)
        if wasWord && !becomesWord { return .infinity }
        var margin = 1.5
        if wasWord && becomesWord { margin *= 1.7 }
        if !wasWord && becomesWord { margin *= 0.8 }
        if current.count != option.count { margin *= 1.4 }
        if current.lowercased() == option.lowercased() { margin *= 2 }
        return margin
    }

    /// Up to `limit` letters that might be in place of `character`, keeping its case.
    /// With `offerOtherCase`, the same letter in the other case comes second, for the start of a word.
    public static func letterOptions(for character: Character, limit: Int, offerOtherCase: Bool = false) -> [String] {
        let lower = Character(character.lowercased())
        var options = [String(character)]
        if offerOtherCase, character.isLetter {
            let other = character.isUppercase ? character.lowercased() : character.uppercased()
            if other != String(character) { options.append(other) }
        }
        for alternative in lookAlikes[lower] ?? [] {
            let shaped = character.isUppercase ? alternative.uppercased() : alternative
            if !options.contains(shaped) { options.append(shaped) }
        }
        return Array(options.prefix(max(limit, 1)))
    }

    /// Vision's reading first, then its other readings, then contractions it may have read without the
    /// apostrophe, then the spell checker's guesses that are real words, then real words a single look-alike
    /// away.
    public func wordOptions(reading: String, alternatives: [String], suggestions: [String] = [], limit: Int) -> [String] {
        var options = [reading]
        func add(_ word: String) {
            if options.count < limit, !word.isEmpty, !options.contains(word) { options.append(word) }
        }
        alternatives.forEach(add)
        Self.apostropheOptions(for: reading).forEach(add)
        suggestions.filter(isWord).forEach(add)
        let characters = Array(reading)
        for (index, character) in characters.enumerated() where character.isLetter {
            for alternative in Self.letterOptions(for: character, limit: 12).dropFirst() {
                var changed = characters
                changed.replaceSubrange(index...index, with: Array(alternative))
                let word = String(changed)
                if isWord(word) { add(word) }
            }
        }
        return options
    }
}

/// Contractions Vision often reads without their apostrophe, or with it as a stray letter.
let contractions: Set<String> = [
    "i'm", "i've", "i'd", "i'll", "you're", "you've", "you'd", "you'll", "he's", "he'd", "he'll", "she's", "she'd",
    "she'll", "it's", "it'd", "it'll", "we're", "we've", "we'd", "we'll", "they're", "they've", "they'd", "they'll",
    "that's", "that'd", "that'll", "there's", "here's", "what's", "where's", "who's", "how's", "let's",
    "don't", "doesn't", "didn't", "can't", "couldn't", "won't", "wouldn't", "shouldn't", "isn't", "aren't",
    "wasn't", "weren't", "hasn't", "haven't", "hadn't", "mustn't", "needn't", "ain't", "y'all", "ma'am", "o'clock",
]

extension CandidateMaker {
    /// The contraction a reading may stand for: "didnt" or "Im" missing the apostrophe, or "wasnit" with it
    /// read as a letter. Keeps a leading capital.
    public static func apostropheOptions(for reading: String) -> [String] {
        let lower = reading.lowercased()
        guard lower.count >= 2, lower.allSatisfy({ $0.isLetter || $0 == "'" }) else { return [] }
        var found: [String] = []
        for contraction in contractions where contraction != lower {
            let bare = contraction.replacingOccurrences(of: "'", with: "")
            let misread = contraction.count == lower.count
                && zip(contraction, lower).filter { $0 != $1 }.count == 1
                && zip(contraction, lower).contains { $0 == "'" && $1 != "'" }
            if bare == lower || misread { found.append(contraction) }
        }
        let capitalized = reading.first?.isUppercase == true
        // "I'm", "I've", and the rest always take a capital I.
        return found.sorted().map { capitalized || $0.hasPrefix("i'") ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
    }
}

/// Everyday English words of three letters or fewer.
let commonShortWords: Set<String> = Set("""
    a i an as at be by do go he if in is it me my no of oh on or so to up us we am are and any ask ate bad \
    bag bed big bit box boy bus but buy can car cat cry cup cut dad day did die dog dry due ear eat egg end \
    eye far fat few fit fix fly for fun got gun guy had has hat her hey him his hit hot how hug ice ill its \
    job joy key kid lay led leg let lie lip lot low mad man map may men met mix mom mud new nod nor not now \
    odd off oil old one our out own pay pen pet pie pig pin pop pot put ran raw red rid row rub run sad sat \
    saw say sea see set sew she shy sit six sky son spa sun tab tea ten the tie tin tip toe too top toy try \
    two use van via war was way web wet who why win won yes yet you zoo ago age aid aim air all art bar bay \
    bet bow cap cow dam den dig dot ego era eve fan fee fig fin fox gap gas gem god gum hip hop ink inn jam \
    jar jet jog kit lab lap law log mat mob mug nap net nut oak oar opt owl pad pal pan paw pea pub rag rat \
    ray rib rim rod rug rye sip sum tag tan tap tar tax tub vet vow wax wig wit yay yea yell yep ugh huh hmm \
    lol omg tv dr mr mrs ms st jr pm am ok
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

/// Splits leading and trailing punctuation off a word so only the letters are decided.
public struct WordParts: Sendable, Equatable {
    public var prefix: String
    public var core: String
    public var suffix: String

    public init(_ text: String) {
        let characters = Array(text)
        let first = characters.firstIndex { $0.isLetter || $0.isNumber } ?? characters.count
        let last = characters.lastIndex { $0.isLetter || $0.isNumber } ?? -1
        if first > last {
            prefix = text
            core = ""
            suffix = ""
        } else {
            prefix = String(characters[..<first])
            core = String(characters[first...last])
            suffix = String(characters[(last + 1)...])
        }
    }

    /// Where the core starts inside the full text, for lining up letter boxes.
    public var coreOffset: Int { prefix.count }

    public func joined(core newCore: String) -> String { prefix + newCore + suffix }
}
