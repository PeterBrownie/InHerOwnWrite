import CoreGraphics
import Foundation
import ImageIO

public enum LocalReadDepth: String, CaseIterable, Identifiable, Sendable {
    /// One question per word, plus letter questions only where the word was a close call.
    case quick
    /// A word question, then a question for every letter, unless the model was already sure of the word.
    case thorough

    public var id: String { rawValue }
}

public struct LocalReadSettings: Sendable, Equatable {
    public var depth: LocalReadDepth
    /// How many letters each letter question chooses between, including the one Vision read.
    public var letterOptions: Int
    /// How many spellings each word question chooses between.
    public var wordOptions: Int

    public init(depth: LocalReadDepth = .quick, letterOptions: Int = 6, wordOptions: Int = 6) {
        self.depth = depth
        self.letterOptions = letterOptions
        self.wordOptions = wordOptions
    }
}

/// One multiple-choice question put to the decision model.
public struct DecisionQuestion: Sendable, Identifiable, Equatable {
    public let id: Int
    public let line: Int
    public let word: Int
    /// The letter being decided, as an index into the word's text, or nil for a whole-word question.
    public let letter: Int?
    /// What each option looks like on its own: a letter, or a whole word.
    public let labels: [String]
    /// The full text rendered for each option. "Something else" has none.
    public let candidates: [String]
    /// Set when re-checking a correction on another crop, such as "Check 2 of 4: shifted left".
    public let note: String?

    public init(id: Int, line: Int, word: Int, letter: Int?, labels: [String], candidates: [String], note: String? = nil) {
        self.id = id
        self.line = line
        self.word = word
        self.letter = letter
        self.labels = labels
        self.candidates = candidates
        self.note = note
    }
}

public enum LocalReadEvent: Sendable {
    /// `image` is the page as read: straightened, so the layout's rectangles line up with it.
    case started(PageLayout, image: CGImage)
    case wordStarted(line: Int, word: Int, crop: CGImage?)
    case asked(DecisionQuestion)
    case scored(question: Int, option: Int, probability: Double, milliseconds: Double, cached: Bool)
    /// `shares` are the option scores scaled to add up to 1.
    case answered(question: Int, choice: Int, shares: [Double])
    case lettersMoved(line: Int, word: Int, text: String, letters: [CGRect])
    case wordFinished(line: Int, word: Int, text: String, confidence: Double)
    case finished(String)
}

/// A finished local reading: the text, and notes on the words worth a second look.
public struct LocalReadResult: Sendable, Equatable {
    public var text: String
    public var notes: [WordNote]

    public init(text: String, notes: [WordNote]) {
        self.text = text
        self.notes = notes
    }

    /// The reading with words fixed by hand while it ran, keyed by line and then word position. Notes on
    /// those words are dropped, since she has settled them.
    public func applying(_ edits: [Int: [Int: String]]) -> LocalReadResult {
        guard !edits.isEmpty else { return self }
        var lines = EntryBuilder.lines(of: text).map { $0.components(separatedBy: " ") }
        for (line, words) in edits where lines.indices.contains(line) {
            for (word, replacement) in words where lines[line].indices.contains(word) {
                lines[line][word] = replacement
            }
        }
        let kept = notes.filter { edits[$0.line]?[$0.word] == nil }
        return LocalReadResult(text: lines.map { $0.joined(separator: " ") }.joined(separator: "\n"), notes: kept)
    }
}

/// Reads a page on this Mac. Vision finds the lines, words, and letters, and proposes a reading; the
/// decision model then checks each word, and each letter, against look-alike options.
public struct LocalReader: Sendable {
    /// Below this share the word counts as a close call.
    public static let closeCall = 0.6
    /// At or above this share, against at least one other spelling, the word is settled without asking
    /// about its letters.
    public static let sure = 0.9
    /// The label for the option that neither spelling is right.
    public static let somethingElse = "Something else"

    let server: DecisionServer
    let candidates: CandidateMaker
    let settings: LocalReadSettings
    /// Other spellings for a word that isn't in the dictionary, from macOS's spell checker.
    let suggest: @Sendable (String) async -> [String]

    public init(server: DecisionServer, candidates: CandidateMaker, settings: LocalReadSettings,
                suggest: @escaping @Sendable (String) async -> [String] = { await SpellingSuggestions.guesses(for: $0) }) {
        self.server = server
        self.candidates = candidates
        self.settings = settings
        self.suggest = suggest
    }

    public func read(jpeg: Data, report: @escaping @Sendable (LocalReadEvent) async -> Void) async throws -> LocalReadResult {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let photo = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw PagePhotoError.unreadable }
        let (layout, level) = try await PageLayoutFinder.read(photo)
        let page = level
        let ink = InkMap(image: page)
        await report(.started(layout, image: page))

        var questionID = 0
        var lines: [String] = []
        // How well the best spelling of each word matched, so "Something else" can be judged against what
        // a good match looks like on this page.
        var bestMatches: [Double] = []
        var notes: [WordNote] = []
        for (lineIndex, line) in layout.lines.enumerated() {
            var words: [String] = []
            for (wordIndex, word) in line.words.enumerated() {
                try Task.checkCancellation()
                let crop = WordCrop.make(page: page, box: word.box)
                await report(.wordStarted(line: lineIndex, word: wordIndex, crop: crop?.preview))
                guard let crop else {
                    words.append(word.text)
                    await report(.wordFinished(line: lineIndex, word: wordIndex, text: word.text, confidence: 0))
                    continue
                }
                let parts = WordParts(word.text)
                guard !parts.core.isEmpty else {
                    words.append(word.text)
                    await report(.wordFinished(line: lineIndex, word: wordIndex, text: word.text, confidence: 1))
                    continue
                }

                var scores: [String: Double] = [:]
                func ask(letter: Int?, labels: [String], cores: [String]) async throws -> (Int, [Double]) {
                    questionID += 1
                    let id = questionID
                    let texts = cores.map(parts.joined(core:))
                    await report(.asked(DecisionQuestion(id: id, line: lineIndex, word: wordIndex, letter: letter,
                                                         labels: labels, candidates: texts)))
                    var probabilities: [Double] = []
                    for (index, text) in texts.enumerated() {
                        try Task.checkCancellation()
                        if let known = scores[text] {
                            probabilities.append(known)
                            await report(.scored(question: id, option: index, probability: known, milliseconds: 0, cached: true))
                            continue
                        }
                        let start = Date()
                        let probability = try await server.score(crop: crop.png, candidate: text)
                        scores[text] = probability
                        probabilities.append(probability)
                        await report(.scored(question: id, option: index, probability: probability,
                                             milliseconds: Date().timeIntervalSince(start) * 1000, cached: false))
                    }
                    bestMatches.append(probabilities.max() ?? 0)
                    let total = probabilities.reduce(0, +)
                    let shares = probabilities.map { total > 0 ? $0 / total : 1 / Double(probabilities.count) }
                    // The strongest option that clears its own bar for replacing what was read.
                    let current = cores[0]
                    let choice = shares.indices
                        .filter { $0 == 0 || shares[$0] >= shares[0] * candidates.switchMargin(from: current, to: cores[$0]) }
                        .max { shares[$0] < shares[$1] } ?? 0
                    await report(.answered(question: id, choice: choice, shares: shares))
                    return (choice, shares)
                }

                // Whole-word question first.
                let alternatives = word.alternatives.map { WordParts($0).core }.filter { !$0.isEmpty }
                // Only a non-word gets the spell checker's guesses; changing one real word into another needs
                // more evidence than the model's shape comparison gives.
                let suggestions = candidates.isWord(parts.core) ? [] : await suggest(parts.core)
                let spellings = candidates.wordOptions(reading: parts.core, alternatives: alternatives,
                                                       suggestions: suggestions, limit: settings.wordOptions)
                var core = parts.core
                var confidence = 1.0
                var compared = false
                // Every spelling weighed for this word, with its best share, to offer as corrections.
                var weighed: [String: Double] = [:]
                if spellings.count > 1 {
                    let (choice, shares) = try await ask(letter: nil, labels: spellings, cores: spellings)
                    core = spellings[choice]
                    confidence = shares[choice]
                    compared = true
                    for (spelling, share) in zip(spellings, shares) { weighed[spelling] = max(weighed[spelling] ?? 0, share) }
                }

                // Then letter by letter, where the word is in doubt. A word with no other spelling to
                // compare against has no measure of doubt, so careful reading checks its letters too.
                let settled = compared && confidence >= Self.sure
                let checkLetters = settings.depth == .thorough ? !settled : confidence < Self.closeCall
                if checkLetters {
                    var characters = Array(core)
                    var index = 0
                    while index < characters.count {
                        let character = characters[index]
                        guard character.isLetter || character.isNumber else {
                            index += 1
                            continue
                        }
                        let options = CandidateMaker.letterOptions(for: character, limit: settings.letterOptions,
                                                                   offerOtherCase: index == 0)
                        let cores = options.map { option -> String in
                            var changed = characters
                            changed.replaceSubrange(index...index, with: Array(option))
                            return String(changed)
                        }
                        let (choice, shares) = try await ask(letter: parts.coreOffset + index, labels: options, cores: cores)
                        for (option, share) in zip(cores, shares) where share >= 0.1 {
                            weighed[option] = max(weighed[option] ?? 0, share)
                        }
                        let picked = Array(options[choice])
                        if choice != 0 {
                            characters.replaceSubrange(index...index, with: picked)
                            let text = parts.joined(core: String(characters))
                            let letters = ink.map { LetterSplitter.split(text: text, box: word.box, ink: $0) }
                                ?? LetterSplitter.evenly(text: text, box: word.box)
                            await report(.lettersMoved(line: lineIndex, word: wordIndex, text: text, letters: letters))
                        }
                        confidence = min(confidence, shares[choice])
                        index += picked.count
                    }
                    core = String(characters)
                }

                // A correction must hold up on other crops of the same word, against Vision's reading and
                // against neither being right.
                if core != parts.core {
                    let floor = Self.somethingElseScore(bestMatches)
                    let original = parts.joined(core: parts.core), corrected = parts.joined(core: core)
                    var totals = [0.0, 0.0, 0.0]
                    let variants = WordCrop.variants
                    for (number, variant) in variants.enumerated() {
                        try Task.checkCancellation()
                        guard let cut = WordCrop.make(page: page, box: word.box, pad: variant.pad, shift: variant.shift)
                        else { continue }
                        await report(.wordStarted(line: lineIndex, word: wordIndex, crop: cut.preview))
                        questionID += 1
                        let id = questionID
                        await report(.asked(DecisionQuestion(
                            id: id, line: lineIndex, word: wordIndex, letter: nil,
                            labels: [parts.core, core, Self.somethingElse], candidates: [original, corrected, ""],
                            note: "Check \(number + 1) of \(variants.count): \(variant.name)")))
                        var probabilities: [Double] = []
                        for (index, text) in [original, corrected].enumerated() {
                            let start = Date()
                            let probability = try await server.score(crop: cut.png, candidate: text)
                            probabilities.append(probability)
                            await report(.scored(question: id, option: index, probability: probability,
                                                 milliseconds: Date().timeIntervalSince(start) * 1000, cached: false))
                        }
                        probabilities.append(floor)
                        await report(.scored(question: id, option: 2, probability: floor, milliseconds: 0, cached: true))
                        let total = probabilities.reduce(0, +)
                        let shares = probabilities.map { $0 / total }
                        for index in 0..<3 { totals[index] += shares[index] }
                        let best = shares.indices.max { shares[$0] < shares[$1] } ?? 0
                        await report(.answered(question: id, choice: best, shares: shares))
                    }
                    let checks = Double(variants.count)
                    let average = totals.map { $0 / checks }
                    if average[2] > average[0] && average[2] > average[1] {
                        // Neither spelling fits well: keep what Vision read, flagged as a close call.
                        core = parts.core
                        confidence = min(confidence, 0.3)
                    } else if average[1] >= average[0] * candidates.switchMargin(from: parts.core, to: core) {
                        confidence = min(confidence, average[1] / (average[0] + average[1]))
                    } else {
                        core = parts.core
                        confidence = min(confidence, average[0] / (average[0] + average[1]))
                    }
                }

                let text = parts.joined(core: core)
                if core != parts.core || confidence < Self.closeCall {
                    weighed[parts.core] = max(weighed[parts.core] ?? 0, core != parts.core ? 1 : 0)
                    let options = weighed
                        .filter { $0.key != core && !$0.key.isEmpty }
                        .sorted { $0.value > $1.value }
                        .prefix(4)
                        .map { parts.joined(core: $0.key) }
                    notes.append(WordNote(line: lineIndex, word: wordIndex, text: text, read: word.text,
                                          options: Array(options), confidence: confidence))
                }
                words.append(text)
                await report(.wordFinished(line: lineIndex, word: wordIndex, text: text, confidence: confidence))
            }
            lines.append(words.joined(separator: " "))
        }
        let text = lines.joined(separator: "\n")
        await report(.finished(text))
        return LocalReadResult(text: text, notes: notes)
    }

    /// What "Something else" scores: a quarter of a typical good match on this page. If both spellings score
    /// below that, neither is likely what's written.
    static func somethingElseScore(_ bestMatches: [Double]) -> Double {
        guard bestMatches.count >= 5 else { return 0.005 }
        let sorted = bestMatches.sorted()
        return sorted[sorted.count / 2] * 0.25
    }

    /// Packages a local reading like one from Claude. Date lines become entry headings; names aren't found.
    public static func transcription(of text: String, notes: [WordNote] = []) -> Transcription {
        let markers = EntryBuilder.lines(of: text).compactMap(DateHeadingParser.parse)
        return Transcription(text: text, wasCutOff: false,
                             structure: PageStructure(markers: markers, names: [], text: text,
                                                      wordNotes: notes.isEmpty ? nil : notes))
    }
}

/// A word cut from the page with a little margin, scaled to the height the model reads fastest.
struct WordCrop {
    let png: Data
    let preview: CGImage

    /// Other ways to cut the same word, for re-checking a correction.
    static let variants: [(name: String, pad: Double, shift: Double)] = [
        ("tighter", 0.05, 0), ("wider", 0.35, 0), ("shifted left", 0.15, -0.06), ("shifted right", 0.15, 0.06),
    ]

    /// `pad` is the margin as a fraction of the word's height; `shift` moves the cut sideways by a fraction
    /// of the word's width.
    static func make(page: CGImage, box: CGRect, pad padFraction: Double = 0.15, shift: Double = 0) -> WordCrop? {
        let width = Double(page.width), height = Double(page.height)
        let pad = box.height * height * padFraction
        let box = box.offsetBy(dx: box.width * shift, dy: 0)
        let rect = CGRect(x: box.minX * width - pad, y: box.minY * height - pad,
                          width: box.width * width + 2 * pad, height: box.height * height + 2 * pad)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 2, rect.height >= 2, let cut = page.cropping(to: rect) else { return nil }
        let targetHeight = DecisionServer.cropHeight
        let targetWidth = max(8, Int(Double(cut.width) * Double(targetHeight) / Double(cut.height)))
        guard let context = CGContext(data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cut, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage(), let png = PNG.encode(scaled) else { return nil }
        return WordCrop(png: png, preview: cut)
    }
}
