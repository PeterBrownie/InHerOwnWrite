import AppKit
import SwiftUI
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WriteApp
import WriteCore

// Checks for reading on this Mac. `runLocalReadingChecks` needs no model; `runLocalModelCheck` reads the
// invented handwritten page with the real decision model (`swift run WriteCheck --local`).

func runLocalReadingChecks() async throws {
    print("\nReading on this Mac")
    let parts = WordParts("\"finally,")
    check("splits punctuation off a word", parts.prefix == "\"" && parts.core == "finally" && parts.suffix == ",")
    check("puts punctuation back", parts.joined(core: "fiually") == "\"fiually,")
    check("keeps a word made only of punctuation", WordParts("-").core.isEmpty && WordParts("-").prefix == "-")

    let upper = CandidateMaker.letterOptions(for: "M", limit: 4)
    check("letter options start with the letter read", upper.first == "M")
    check("letter options keep capitals", upper == ["M", "N", "W", "RN"])
    check("letter options respect the limit", CandidateMaker.letterOptions(for: "a", limit: 10).count == 10)
    check("unknown symbols get no look-alikes", CandidateMaker.letterOptions(for: "&", limit: 6) == ["&"])
    check("a word's first letter can change case", CandidateMaker.letterOptions(for: "w", limit: 3, offerOtherCase: true) == ["w", "W", "m"])

    let maker = CandidateMaker(words: ["bread", "broad", "breed", "bead", "the", "she"])
    let options = maker.wordOptions(reading: "bread", alternatives: ["brcad"], limit: 6)
    check("word options lead with Vision's reading", options.first == "bread")
    check("word options include Vision's other readings", options.contains("brcad"))
    check("word options add real look-alike words", options.contains("breed") && options.contains("broad"))
    check("word options skip non-words", !options.contains("brezd"))
    check("word options respect the limit", maker.wordOptions(reading: "bread", alternatives: [], limit: 2).count == 2)
    let dictionary = CandidateMaker(words: CandidateMaker.loadDictionary())
    let guesses = await MainActor.run { SpellingSuggestions.guesses(for: "beautful") }
    check("the spell checker offers a word with a dropped letter", guesses.contains("beautiful"))
    let capitalized = await MainActor.run { SpellingSuggestions.guesses(for: "Freind") }
    check("its guesses keep a leading capital", capitalized.contains("Friend"))
    check("a dropped letter becomes a word option",
          dictionary.wordOptions(reading: "beautful", alternatives: [], suggestions: guesses, limit: 6).contains("beautiful"))
    check("guesses that aren't real words aren't offered",
          !maker.wordOptions(reading: "brexd", alternatives: [], suggestions: ["brexed"], limit: 6).contains("brexed"))
    check("guesses of two words or far from the reading are dropped",
          SpellingSuggestions.usable(["beau tful", "bathtub", "beautiful"], for: "beautful") == ["beautiful"])
    check("journal words join the dictionary",
          CandidateMaker(words: CandidateMaker.loadDictionary(extraText: ["Marguerite came"])).isWord("Marguerite"))

    let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
    let even = LetterSplitter.evenly(text: "mill", box: box)
    check("one box per letter", even.count == 4)
    check("letter boxes fill the word", abs((even.last?.maxX ?? 0) - box.maxX) < 1e-9 && even.first?.minX == box.minX)
    check("wide letters get wide boxes", even[0].width > even[1].width)

    let transcription = LocalReader.transcription(of: "Tuesday, March 3, 2026\nWe walked.")
    check("local readings find date headings", transcription.structure.markers.first?.month == 3)
    check("local readings name no one", transcription.structure.names.isEmpty)

    // Vision runs on this Mac, so the layout check uses the invented page.
    let jpeg = try PagePhoto.prepare(handwrittenPage())
    let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let layout = try await PageLayoutFinder.find(in: image)
    let written = handwrittenLines.filter { !$0.isEmpty }
    if layout.lines.count != written.count {
        print("        pitch \(InkMap(image: image)?.linePitch() ?? -1)")
        layout.lines.forEach { line in print(String(format: "        | %.3f ", line.box.midY) + line.words.map(\.text).joined(separator: " ")) }
    }
    check("finds every written line", layout.lines.count == written.count)
    check("lines run top to bottom", zip(layout.lines, layout.lines.dropFirst()).allSatisfy { $0.box.minY < $1.box.minY })
    let words = layout.lines.flatMap(\.words)
    check("finds the words", abs(words.count - written.joined(separator: " ").split(separator: " ").count) <= 3)
    check("every word has a box per letter", words.allSatisfy { $0.letters.count == $0.text.count })
    check("letter boxes stay inside their word", words.allSatisfy { word in
        word.letters.allSatisfy { $0.minX >= word.box.minX - 1e-6 && $0.maxX <= word.box.maxX + 1e-6 }
    })
    check("letter boxes are in order", words.allSatisfy { word in
        zip(word.letters, word.letters.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 1e-6 }
    })
}

func runLocalModelCheck() async -> Bool {
    print("Reading the invented page with the decision model on this Mac")
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("In Her Own Write/Models", isDirectory: true)
    let files = DecisionModelFiles(directory: directory)
    guard files.isDownloaded else {
        print("  The model isn't downloaded. Open the app and choose Read on This Mac to download it.")
        return false
    }
    let server = DecisionServer(files: files)
    let before = failures
    do {
        let start = Date()
        try await server.start()
        print(String(format: "  model loaded in %.1f s", Date().timeIntervalSince(start)))

        let jpeg = try PagePhoto.prepare(handwrittenPage())
        let page = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)!
        let visionOnly = try await PageLayoutFinder.find(in: page).lines
            .map { $0.words.map(\.text).joined(separator: " ") }
        let expected = handwrittenLines.filter { !$0.isEmpty && !$0.hasPrefix("plum") }
        func exactLines(_ lines: [String]) -> Int {
            // Spacing around dashes varies with the font, so only the characters are compared.
            let squeezed = Set(lines.map { $0.filter { !$0.isWhitespace } })
            return expected.filter { squeezed.contains($0.filter { !$0.isWhitespace }) }.count
        }
        let baseline = exactLines(visionOnly)
        print("  Vision alone: \(baseline) of \(expected.count) clean lines exactly")
        let depths: [LocalReadDepth] = CommandLine.arguments.contains("--thorough") ? [.quick, .thorough] : [.quick]
        for depth in depths {
            let reader = LocalReader(server: server, candidates: CandidateMaker(words: CandidateMaker.loadDictionary()),
                                     settings: LocalReadSettings(depth: depth))
            let counter = DecisionCounter()
            let began = Date()
            let text = try await reader.read(jpeg: jpeg) { event in
                await counter.record(event)
            }.text
            let seconds = Date().timeIntervalSince(began)
            let (decisions, cached, changed) = await counter.totals()
            let lines = EntryBuilder.lines(of: text)
            let exact = exactLines(lines)
            print("  \(depth.rawValue): \(decisions) decisions (\(cached) reused), \(changed) letters changed, "
                  + String(format: "%.1f s, %.0f ms each", seconds, seconds * 1000 / Double(max(decisions, 1))))
            print("  \(exact) of \(expected.count) clean lines read exactly")
            for line in lines { print("    | \(line)") }
            check("\(depth.rawValue) reading keeps every line", lines.count == handwrittenLines.filter { !$0.isEmpty }.count)
            check("\(depth.rawValue) reading is at least as good as Vision alone", exact >= baseline)

            // Stopped after two lines, then read again: the two lines are kept and the rest is read the same.
            if let partway = await counter.progress(afterLines: 2) {
                let again = DecisionCounter()
                let resumed = try await reader.read(jpeg: jpeg, resume: partway) { event in
                    await again.record(event)
                }.text
                let (resumedDecisions, _, _) = await again.totals()
                print("  resumed after 2 lines: \(resumedDecisions) decisions")
                check("\(depth.rawValue) reading resumed partway gives the same text", resumed == text)
                let wasResumed = await again.wasResumed
                check("\(depth.rawValue) reading resumed partway skips the lines already read",
                      resumedDecisions < decisions && wasResumed)
            } else {
                check("\(depth.rawValue) reading saves progress line by line", false)
            }
        }
    } catch {
        check("local reading runs: \(error.localizedDescription)", false)
    }
    await server.stop()
    return failures == before
}

actor DecisionCounter {
    private var decisions = 0
    private var cached = 0
    private var changed = 0

    func record(_ event: LocalReadEvent) {
        switch event {
        case .scored(_, _, _, _, let wasCached):
            if wasCached { cached += 1 } else { decisions += 1 }
        case .lettersMoved:
            changed += 1
        case .lineFinished(_, let progress):
            saved.append(progress)
        case .resumed:
            wasResumed = true
        default:
            break
        }
    }

    private var saved: [LocalReadProgress] = []
    private(set) var wasResumed = false

    func progress(afterLines count: Int) -> LocalReadProgress? {
        saved.first { $0.lines.count == count }
    }

    func totals() -> (Int, Int, Int) { (decisions, cached, changed) }
}

/// A reading caught partway through, built from the invented page's real layout, for screenshots.
@MainActor
func sampleLocalSession(photo: Data) async throws -> LocalReadSession {
    let source = CGImageSourceCreateWithData(photo as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let layout = try await PageLayoutFinder.find(in: image)
    let session = LocalReadSession(pageID: UUID(), pageNumber: 3, journalName: "Green Notebook",
                                   photo: NSImage(data: photo), settings: LocalReadSettings(depth: .thorough))
    session.setPhase(.findingWords)
    session.apply(.started(layout, image: image))
    var id = 0
    let stopAt = (line: 3, word: 2)
    for (lineIndex, line) in layout.lines.enumerated() {
        for (wordIndex, word) in line.words.enumerated() {
            if lineIndex == stopAt.line && wordIndex == stopAt.word {
                let crop = WordCropPreview.make(page: image, box: word.box)
                session.apply(.wordStarted(line: lineIndex, word: wordIndex, crop: crop))
                id += 1
                let parts = WordParts(word.text)
                let letter = min(2, parts.core.count - 1)
                let options = CandidateMaker.letterOptions(for: Array(parts.core)[letter], limit: 6)
                let candidates = options.map { option -> String in
                    var characters = Array(parts.core)
                    characters.replaceSubrange(letter...letter, with: Array(option))
                    return parts.joined(core: String(characters))
                }
                session.apply(.asked(DecisionQuestion(id: id, line: lineIndex, word: wordIndex, letter: parts.coreOffset + letter,
                                                      labels: options, candidates: candidates)))
                for (index, probability) in [0.031, 0.004, 0.0012, 0.0009].enumerated() {
                    session.apply(.scored(question: id, option: index, probability: probability, milliseconds: 166, cached: index == 0))
                }
                return session
            }
            session.apply(.wordStarted(line: lineIndex, word: wordIndex, crop: nil))
            id += 1
            session.apply(.asked(DecisionQuestion(id: id, line: lineIndex, word: wordIndex, letter: nil,
                                                  labels: [word.text, word.text + "s"], candidates: [word.text, word.text + "s"])))
            let close = (lineIndex + wordIndex) % 7 == 3
            session.apply(.scored(question: id, option: 0, probability: 0.04, milliseconds: 168, cached: false))
            session.apply(.scored(question: id, option: 1, probability: close ? 0.03 : 0.004, milliseconds: 165, cached: false))
            session.apply(.answered(question: id, choice: 0, shares: close ? [0.57, 0.43] : [0.91, 0.09]))
            session.apply(.wordFinished(line: lineIndex, word: wordIndex, text: word.text, confidence: close ? 0.57 : 0.91))
        }
    }
    return session
}

enum WordCropPreview {
    static func make(page: CGImage, box: CGRect) -> CGImage? {
        let width = Double(page.width), height = Double(page.height)
        let pad = box.height * height * 0.15
        let rect = CGRect(x: box.minX * width - pad, y: box.minY * height - pad,
                          width: box.width * width + 2 * pad, height: box.height * height + 2 * pad).integral
        return page.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)))
    }
}

/// An invented two-page spread on a dark table: the page being added on the left, a strip of the facing
/// page on the right past a shadowed fold, and a small printed page number. No real journal content.
func twoPageSpread() -> Data {
    let width = 1800, height = 2400
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Paper, with the fold at x = 1470 shaded like a real gutter.
    context.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.88, alpha: 1))
    context.fill(CGRect(x: 120, y: 150, width: 1680, height: 2150))
    for offset in 0..<60 {
        let shade = 0.95 - 0.35 * (1 - Double(offset) / 60)
        context.setFillColor(CGColor(red: shade, green: shade * 0.99, blue: shade * 0.93, alpha: 1))
        context.fill(CGRect(x: 1470 - offset, y: 150, width: 1, height: 2150))
        context.fill(CGRect(x: 1470 + offset, y: 150, width: 1, height: 2150))
    }
    let font = NSFont(name: "Bradley Hand", size: 64) ?? .systemFont(ofSize: 60)
    let ink = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.16, alpha: 1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let main = ["We walked down to the river early", "and watched the herons fish for a", "while before the rain came in.",
                "Later we baked bread and read", "on the porch until it got dark.", "Tomorrow we drive back home."]
    let facing = ["Sunday", "the old", "garden", "planted", "seeds", "maybe"]
    for (index, line) in main.enumerated() {
        let y = CGFloat(2050 - index * 150)
        NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: ink]).draw(at: CGPoint(x: 200, y: y))
        NSAttributedString(string: facing[index], attributes: [.font: font, .foregroundColor: ink])
            .draw(at: CGPoint(x: 1540, y: y - 10))
    }
    NSAttributedString(string: "212", attributes: [.font: NSFont(name: "Times New Roman", size: 30) ?? .systemFont(ofSize: 30),
                                                   .foregroundColor: NSColor(white: 0.35, alpha: 1)])
        .draw(at: CGPoint(x: 210, y: 230))
    NSGraphicsContext.restoreGraphicsState()
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// An invented photo of both pages of an open journal on a dark table: the fold a little right of the
/// photo's middle, writing on both pages, and a printed page number at the bottom outer corner of each.
func openJournal() -> Data {
    let width = 2400, height = 1800
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // The left page sits a little lower than the right, as an open book does.
    context.setFillColor(CGColor(red: 0.95, green: 0.94, blue: 0.88, alpha: 1))
    context.fill(CGRect(x: 160, y: 110, width: 1140, height: 1580))
    context.fill(CGRect(x: 1300, y: 130, width: 1000, height: 1580))
    let fold = 1300
    for offset in 0..<50 {
        let shade = 0.95 - 0.38 * (1 - Double(offset) / 50)
        context.setFillColor(CGColor(red: shade, green: shade * 0.99, blue: shade * 0.93, alpha: 1))
        context.fill(CGRect(x: fold - offset, y: 130, width: 1, height: 1560))
        context.fill(CGRect(x: fold + offset, y: 130, width: 1, height: 1560))
    }
    let font = NSFont(name: "Bradley Hand", size: 52) ?? .systemFont(ofSize: 50)
    let ink = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.16, alpha: 1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let left = ["The ferry left at seven and", "the gulls followed it out", "past the lighthouse rocks.",
                "We ate apples on deck and", "counted the sailboats."]
    let right = ["By noon the island was", "close enough to see the", "little white church and", "the harbor wall."]
    for (index, line) in left.enumerated() {
        NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: ink])
            .draw(at: CGPoint(x: 250, y: CGFloat(1500 - index * 130)))
    }
    for (index, line) in right.enumerated() {
        NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: ink])
            .draw(at: CGPoint(x: 1390, y: CGFloat(1520 - index * 130)))
    }
    let printed: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Times New Roman", size: 30) ?? .systemFont(ofSize: 30),
                                                  .foregroundColor: NSColor(white: 0.35, alpha: 1)]
    NSAttributedString(string: "48", attributes: printed).draw(at: CGPoint(x: 230, y: 170))
    NSAttributedString(string: "49", attributes: printed).draw(at: CGPoint(x: 2200, y: 190))
    NSGraphicsContext.restoreGraphicsState()
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

func runSpreadChecks() async throws {
    print("\nSplitting a photo of both pages")
    let halves = SpreadScanResult.halves(of: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6), split: 0.25)
    check("halves meet at the split", abs(halves.left.maxX - 0.3) < 1e-9 && abs(halves.right.minX - 0.3) < 1e-9)
    check("halves keep the crop's height", halves.left.height == 0.6 && halves.right.minY == 0.2)
    check("the split stays away from the edges",
          abs(SpreadScanResult.halves(of: CGRect(x: 0, y: 0, width: 1, height: 1), split: 0.01).left.width - 0.15) < 1e-9)
    check("the left page number comes from the right one when unread",
          SpreadScanResult(crop: .zero, split: 0.5, rightNumber: 49).leftPageNumber == 48
            && SpreadScanResult(crop: .zero, split: 0.5, rightNumber: 1).leftPageNumber == nil)
    check("a page number missing a digit gives way to its neighbor's",
          SpreadScanResult(crop: .zero, split: 0.5, leftNumber: 24, rightNumber: 241).leftPageNumber == 240
            && SpreadScanResult(crop: .zero, split: 0.5, leftNumber: 240, rightNumber: 24).leftPageNumber == 240
            && SpreadScanResult(crop: .zero, split: 0.5, leftNumber: 52, rightNumber: 61).leftPageNumber == 52)

    let photo = openJournal()
    let scan = await PageScan.analyzeSpread(jpeg: photo)
    let fold = scan.crop.minX + scan.crop.width * scan.split
    check("finds the fold between the pages", abs(fold - 1300.0 / 2400) < 0.015)
    check("keeps both pages", scan.crop.minX < 250.0 / 2400 && scan.crop.maxX > 2290.0 / 2400
            && scan.crop.minY < 120.0 / 1800 && scan.crop.maxY > 1680.0 / 1800)
    check("leaves out most of the table", scan.crop.minX > 0.03 && scan.crop.maxX < 0.99)
    check("reads both page numbers", scan.leftNumber == 48 && scan.rightNumber == 49)
    let bothShown = await PageScan.showsTwoPages(jpeg: photo)
    check("sees that a photo shows both pages", bothShown)

    let (left, right) = SpreadScanResult.halves(of: scan.crop, split: scan.split)
    for (name, half, has, lacks) in [("left", left, "ferry", "island"), ("right", right, "island", "ferry")] {
        let page = try PageFlattener.process(photo, crop: half, flatten: true)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(page as CFData, nil)!, 0, nil)!
        let (layout, _) = try await PageLayoutFinder.read(image)
        let text = layout.lines.map { $0.words.map(\.text).joined(separator: " ") }.joined(separator: " ")
        if !text.contains(has) || text.contains(lacks) { print("        | \(text)") }
        check("the \(name) page holds only its own writing", text.contains(has) && !text.contains(lacks))
    }

    // A photo of both pages is often taken with the phone upright, which leaves the pages sideways.
    let level = PageScan.orientation(ofLines: (0..<5).map { _ in (CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.21)) },
                                     width: 1000, height: 800)
    check("level lines need no turn", level.quarterTurns == 0 && abs(level.tilt - 0.65) < 0.1)
    let down = PageScan.orientation(ofLines: (0..<5).map { _ in (CGPoint(x: 0.3, y: 0.9), CGPoint(x: 0.31, y: 0.1)) },
                                    width: 800, height: 1000)
    check("lines running down the photo need a turn to the left", down.quarterTurns == 3 && abs(down.tilt) < 1.5)
    let few = PageScan.orientation(ofLines: [(CGPoint(x: 0.3, y: 0.9), CGPoint(x: 0.3, y: 0.1))], width: 800, height: 1000)
    check("one line isn't enough to turn a photo", few == .upright)
    let sideways = try PagePhoto.rotated(photo, degrees: 90)
    let found = await PageScan.orientation(jpeg: sideways)
    check("finds which way up a sideways photo of both pages goes", found.quarterTurns == 3 && abs(found.tilt) < 1)
    let asTaken = await PageScan.orientation(jpeg: photo)
    check("leaves an upright photo as it is", asTaken.quarterTurns == 0)
    let upright = await PageScan.analyzeSpread(jpeg: try PagePhoto.rotated(sideways, degrees: Double(found.quarterTurns) * 90))
    check("finds the same fold once turned upright", abs((upright.crop.minX + upright.crop.width * upright.split) - fold) < 0.01)

    // A crop found on the levelled photo becomes a frame over the photo as shown, and back.
    let frame = CGRect(x: 0.12, y: 0.18, width: 0.6, height: 0.55)
    let back = TiltedCrop.photoCrop(TiltedCrop.canvasCrop(frame, degrees: 4.5, aspect: 1.33), degrees: 4.5, aspect: 1.33)
    check("a levelled crop turns back into the same frame",
          abs(back.minX - frame.minX) + abs(back.minY - frame.minY) + abs(back.width - frame.width) + abs(back.height - frame.height) < 1e-9)
}

/// Photos dropped together are added in the order they were taken.
func runPhotoOrderChecks() throws {
    print("\nAdding several photos")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("photo-order-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let image = context.makeImage()!
    func write(_ name: String, taken: String?) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let properties = taken.map { [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: $0]] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        CGImageDestinationFinalize(destination)
        return url
    }
    let a = try write("a.jpg", taken: "2026:02:14 09:30:00")
    let b = try write("b.jpg", taken: "2026:02:13 21:05:00")
    let c = try write("c.jpg", taken: "2026:02:14 09:29:59")
    let undated = try write("d.jpg", taken: nil)
    check("reads when a photo was taken", PagePhoto.dateTaken(b).map { Calendar.current.component(.hour, from: $0) } == 21)
    check("a photo without camera metadata falls back to when the file was made", PagePhoto.dateTaken(undated) != nil)
    let sorted = PagePhoto.sortedByDate([a, undated, b, c]).map(\.lastPathComponent)
    check("photos are taken in order, by camera time first", Array(sorted.prefix(3)) == ["b.jpg", "c.jpg", "a.jpg"])
}

func runPageScanChecks() async throws {
    print("\nFinding the page in a photo")
    check("reads a bare page number", PageNumberFinder.number(in: "58") == 58)
    check("reads a decorated page number", PageNumberFinder.number(in: "- 12 -") == 12 && PageNumberFinder.number(in: "p. 7") == 7)
    check("ignores dates and sentences", PageNumberFinder.number(in: "1/16/26") == nil && PageNumberFinder.number(in: "I ate 3") == nil)

    let spread = twoPageSpread()
    let scan = await PageScan.analyze(jpeg: spread)
    let stripShown = await PageScan.showsTwoPages(jpeg: spread)
    check("a page with a strip of the next isn't two pages", !stripShown)
    let foldX = 1470.0 / 1800
    check("finds the page number", scan.pageNumber == 212)
    check("cuts at the fold, leaving out the facing page", scan.crop.maxX < (1540.0 / 1800) && scan.crop.maxX > foldX - 0.02)
    check("keeps the page's writing", scan.crop.minX < 200.0 / 1800 && scan.crop.minY < 0.15 && scan.crop.maxY > 0.88)
    check("keeps the page number inside the crop", scan.pageNumberBox.map { scan.crop.contains(CGPoint(x: $0.midX, y: $0.midY)) } == true)

    let cropped = try PagePhoto.crop(spread, to: scan.crop)
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(cropped as CFData, nil)!, 0, nil)!
    check("crops the saved photo", abs(Double(image.width) - scan.crop.width * 1800) < 3)
    let (layout, _) = try await PageLayoutFinder.read(image)
    let text = layout.lines.map { $0.words.map(\.text).joined(separator: " ") }
    if layout.lines.count != 6 { text.forEach { print("        | \($0)") } }
    check("reads each line of the cropped page once", layout.lines.count == 6)
    check("leaves the facing page out", !text.joined(separator: " ").contains("planted"))
    check("leaves the page number out of the text", !text.contains { $0.contains("212") })
}

/// The update check against throwaway repositories: a bare one standing in for GitHub, and two copies.
func runUpdaterChecks() {
    print("\nUpdates")
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
          Updater.run("/usr/bin/xcode-select", ["-p"], timeout: 5)?.status == 0
    else {
        print("  skipped: git isn't available")
        return
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ arguments: [String], in directory: URL) -> String {
        let result = Updater.run("/usr/bin/git", ["-C", directory.path, "-c", "user.name=Check", "-c", "user.email=check@example.invalid",
                                                  "-c", "commit.gpgsign=false"] + arguments, timeout: 20)
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    let origin = root.appendingPathComponent("origin.git"), mine = root.appendingPathComponent("mine"),
        theirs = root.appendingPathComponent("theirs")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = Updater.run("/usr/bin/git", ["init", "--bare", "-b", "main", origin.path], timeout: 20)
    _ = Updater.run("/usr/bin/git", ["clone", "--quiet", origin.path, mine.path], timeout: 20)
    _ = git(["checkout", "-q", "-b", "main"], in: mine)
    _ = git(["commit", "-q", "--allow-empty", "-m", "one"], in: mine)
    _ = git(["push", "-q", "-u", "origin", "main"], in: mine)
    let built = git(["rev-parse", "HEAD"], in: mine)
    check("up to date when GitHub matches", isNewer(Updater.newerCommit(than: built, in: mine)) == false)

    _ = Updater.run("/usr/bin/git", ["clone", "--quiet", origin.path, theirs.path], timeout: 20)
    _ = git(["commit", "-q", "--allow-empty", "-m", "two"], in: theirs)
    _ = git(["push", "-q", "origin", "main"], in: theirs)
    check("finds a newer commit on GitHub", isNewer(Updater.newerCommit(than: built, in: mine)) == true)

    let latest = git(["rev-parse", "HEAD"], in: theirs)
    _ = git(["pull", "-q", "--ff-only"], in: mine)
    _ = git(["commit", "-q", "--allow-empty", "-m", "unpushed"], in: mine)
    let ahead = git(["rev-parse", "HEAD"], in: mine)
    check("a build ahead of GitHub stays put", isNewer(Updater.newerCommit(than: ahead, in: mine)) == false)
    check("a build of the latest commit stays put", isNewer(Updater.newerCommit(than: latest, in: mine)) == false)
    check("the helper swaps in the new copy and can put the old one back",
          Updater.helperScript.contains("ditto \"$staged\"") && Updater.helperScript.contains("mv \"$app.old\" \"$app\"")
          && Updater.helperScript.contains("open \"$app\""))
}

/// Updates from GitHub's releases, for a Mac that was sent the app: reading GitHub's answers, and checking a
/// download before it's installed. Nothing here goes online.
func runReleaseUpdateChecks() {
    print("\nUpdates from releases")
    let release = #"""
        {"tag_name": "build-12.1", "draft": false, "prerelease": false, "assets": [
          {"name": "notes.txt", "browser_download_url": "https://example.invalid/notes.txt"},
          {"name": "In-Her-Own-Write.zip", "browser_download_url": "https://example.invalid/build-12.1/In-Her-Own-Write.zip",
           "digest": "sha256:abc123"}]}
        """#
    let parsed = Updater.parseRelease(Data(release.utf8))
    check("reads the latest release", parsed?.tag == "build-12.1" && parsed?.digest == "sha256:abc123"
          && parsed?.download.absoluteString == "https://example.invalid/build-12.1/In-Her-Own-Write.zip")
    check("ignores a release without the app",
          Updater.parseRelease(Data(release.replacingOccurrences(of: "In-Her-Own-Write.zip\",", with: "Other.zip\",").utf8)) == nil)
    check("ignores a draft", Updater.parseRelease(Data(release.replacingOccurrences(of: #""draft": false"#, with: #""draft": true"#).utf8)) == nil)
    check("ignores a download that isn't https",
          Updater.parseRelease(Data(release.replacingOccurrences(of: "https://example.invalid/build", with: "http://example.invalid/build").utf8)) == nil)
    check("reads GitHub's comparison", Updater.parseCompareStatus(Data(#"{"status": "ahead", "ahead_by": 3}"#.utf8)) == "ahead")
    check("knows a repository name", Updater.isRepositoryName("Someone/Some-Repo.2")
          && !Updater.isRepositoryName("a/b/c") && !Updater.isRepositoryName("a") && !Updater.isRepositoryName("a b/c"))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("release-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    check("a copy sent to another Mac updates from releases",
          Updater.channel(commit: "abc1234", source: root.appendingPathComponent("gone"), repository: "Someone/Repo") == .releases("Someone/Repo"))
    check("a build that doesn't know its commit doesn't update",
          Updater.channel(commit: nil, source: nil, repository: "Someone/Repo") == nil)
    check("an app still in its download spot asks to be moved",
          Updater.installProblem(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/In Her Own Write.app")) != nil)
    check("an app in a folder it can write to can replace itself",
          Updater.installProblem(for: root.appendingPathComponent("In Her Own Write.app")) == nil)

    // A stand-in app, signed the way the release build signs it.
    let app = root.appendingPathComponent("In Her Own Write.app")
    let contents = app.appendingPathComponent("Contents")
    try? FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    try? FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/InHerOwnWrite").path)
    try? Data("icon".utf8).write(to: contents.appendingPathComponent("Resources/AppIcon.icns"))
    let info: NSDictionary = ["CFBundleIdentifier": "local.inherownwrite.journal", "CFBundleExecutable": "InHerOwnWrite",
                              "CFBundlePackageType": "APPL", "InHerOwnWriteCommit": "abc1234"]
    info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
    Updater.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path], timeout: 60)
    check("accepts a signed copy of the app", Updater.checkDownloadedApp(app, identifier: "local.inherownwrite.journal") == nil)
    check("refuses a different app", Updater.checkDownloadedApp(app, identifier: "some.other.app") != nil)
    try? Data("changed".utf8).write(to: contents.appendingPathComponent("Resources/AppIcon.icns"))
    check("refuses a copy changed after signing", Updater.checkDownloadedApp(app, identifier: "local.inherownwrite.journal") != nil)
}

/// A Mac without Homebrew or llama.cpp, such as one the app was just sent to: reading on this Mac says what's
/// missing and stops before touching anything, and pages stay readable with Claude.
@MainActor
func runMissingRuntimeChecks() async {
    print("\nReading on this Mac without llama.cpp")
    let saved = (DecisionModelFiles.runtimePaths, DecisionModelFiles.homebrewPaths, ProcessInfo.processInfo.environment["LLAMA_SERVER"])
    let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("nowhere-\(UUID().uuidString)")
    DecisionModelFiles.runtimePaths = [nowhere.appendingPathComponent("llama-server").path]
    DecisionModelFiles.homebrewPaths = [nowhere.appendingPathComponent("brew").path]
    unsetenv("LLAMA_SERVER")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("no-runtime-\(UUID().uuidString)")
    defer {
        (DecisionModelFiles.runtimePaths, DecisionModelFiles.homebrewPaths) = (saved.0, saved.1)
        if let custom = saved.2 { setenv("LLAMA_SERVER", custom, 1) }
        try? FileManager.default.removeItem(at: directory)
    }

    check("finds no llama.cpp", DecisionModelFiles.findRuntime() == nil)
    check("without Homebrew, says where to get it", DecisionModelFiles.runtimeHelp.contains("brew.sh"))
    DecisionModelFiles.homebrewPaths = ["/bin/sh"]  // Something that exists, standing in for brew.
    check("with Homebrew, only asks for llama.cpp",
          !DecisionModelFiles.runtimeHelp.contains("brew.sh") && DecisionModelFiles.runtimeHelp.contains("brew install llama.cpp"))
    DecisionModelFiles.homebrewPaths = [nowhere.appendingPathComponent("brew").path]

    let server = DecisionServer(files: DecisionModelFiles(directory: directory))
    var thrown: Error?
    do { try await server.start() } catch { thrown = error }
    check("the model won't start, and says why", (thrown as? DecisionModelError) == .runtimeMissing)
    let running = await server.isRunning
    check("nothing is left running", !running)

    let model = AppModel(directory: directory)
    await model.createVault(password: "synthetic password")
    model.confirmRecoveryKeySaved()
    model.showSettings = false
    guard let journal = model.createJournal(name: "Check Journal"), let jpeg = try? PagePhoto.prepare(handwrittenPage()),
          model.addPage(journalID: journal.id, number: 3, jpeg: jpeg, replacing: false, readLocally: true),
          let added = model.pages.first
    else {
        check("adds a page to read on this Mac", false)
        return
    }
    check("a new page waits instead of failing", added.status == .waiting && added.problem?.contains("brew.sh") == true)
    check("nothing is queued", model.localQueueCount == 0)
    check("adding a page doesn't also raise an alert", model.errorMessage == nil)

    try? model.saveLocalReading(LocalReadResult(text: "Already read", notes: []), pageID: added.id)
    model.readOnThisMac(added.id)
    check("a page already read keeps its reading", model.page(id: added.id)?.status == .done && model.texts[added.id] == "Already read")
    check("asking to read on this Mac says what's missing", model.errorMessage?.contains("brew.sh") == true)
    model.lock()
}

private func isNewer(_ result: Result<Bool, Updater.CheckError>?) -> Bool? {
    if case .success(let newer) = result { return newer }
    return nil
}

func runFlattenChecks() async throws {
    print("\nFlattening curved pages")
    let jpeg = try PagePhoto.prepare(handwrittenPage())
    let flat = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)!
    let pitch = Double(flat.height) * (InkMap(image: flat)?.linePitch() ?? 0.06)
    let straight = PageFlattener.largestDrift(in: flat) ?? 0
    check("a flat page measures as flat", straight < pitch * 0.25)
    check("a flat page is left alone", PageFlattener.flatten(flat) == nil || straight > 2)

    let curled = PageFlattener.curled(flat, depth: pitch * 0.8)!
    let bent = PageFlattener.largestDrift(in: curled) ?? 0
    check("measures a page curling into the fold", bent > pitch * 0.5)
    guard let fixed = PageFlattener.flatten(curled) else {
        check("flattens a curled page", false)
        return
    }
    let after = PageFlattener.largestDrift(in: fixed) ?? .infinity
    print(String(format: "        drift: %.0f px before, %.0f px after (line pitch %.0f px)", bent, after, pitch))
    // About 60% of the bend comes out; the measurement wobbles by a pixel or two between runs, which put the
    // old limit of 40% left right on the edge.
    check("flattening removes most of the curl", after < bent * 0.45)
    let lines = try await PageLayoutFinder.find(in: fixed).lines
    check("every line still reads after flattening", lines.count == handwrittenLines.filter { !$0.isEmpty }.count)
    let saved = try PageFlattener.process(jpeg, crop: PageScanResult.whole.crop, flatten: true)
    check("saving a flat page with flattening on still works", NSImage(data: saved) != nil)
}

func runSwitchRuleChecks() {
    print("\nWhen the model may change a reading")
    let maker = CandidateMaker(words: ["bread", "broad", "the", "house", "pm", "little"])
    check("never turns a real word into a non-word", maker.switchMargin(from: "pm", to: "prn") == .infinity
          && maker.switchMargin(from: "little", to: "littlo") == .infinity)
    check("a swap between real words needs strong evidence", maker.switchMargin(from: "bread", to: "broad") > 2.4)
    check("turning a non-word into a word is easiest", maker.switchMargin(from: "tbe", to: "the") < maker.switchMargin(from: "bread", to: "broad")
          && maker.switchMargin(from: "hause", to: "house") < 1.5)
    check("changing only capitals needs more", maker.switchMargin(from: "Chand", to: "chand") > maker.switchMargin(from: "chand", to: "chank"))
}

func runEditingChecks(in directory: URL) throws {
    print("\nFixing words and typos")
    // Flowing text edits land in the text as written.
    let written = "Tuesday, March 3\nWe walked to the riv-\ner and back. The sky\n  was grey.\n\nLater, tea."
    let flow = LineFlow.mapped(written, headingLines: [0])
    check("flowing text joins lines as before", flow.text == LineFlow.reflow(written, headingLines: [0])
          && flow.text == "Tuesday, March 3\n\nWe walked to the riv-er and back. The sky was grey.\n\nLater, tea.")
    let fixedTypo = flow.applying(flow.text.replacingOccurrences(of: "grey", with: "gray"), to: written)
    check("a typo fixed in flowing text keeps the line breaks", fixedTypo == written.replacingOccurrences(of: "grey", with: "gray"))
    let acrossHyphen = flow.applying(flow.text.replacingOccurrences(of: "riv-er", with: "rov-er"), to: written)
    check("a word hyphenated across lines can be fixed", acrossHyphen.contains("rov-\ner"))
    let atJoin = flow.applying(flow.text.replacingOccurrences(of: "sky was", with: "sky, it was"), to: written)
    check("typing at a joined line break lands at the end of the line", atJoin.contains("The sky, it\n  was grey."))
    check("finds a written word in the flowing text",
          flow.flowedRange(for: (written as NSString).range(of: "grey")).map { (flow.text as NSString).substring(with: $0) } == "grey")

    // Notes stay on their word and drop off when it's changed.
    let note = WordNote(line: 1, word: 3, text: "tbe", read: "the", options: ["the", "tho"], confidence: 0.4)
    let text = "Monday\nWe went to tbe lake"
    check("finds a noted word", WordNote.locate([note], in: text).first.map { (text as NSString).substring(with: $0.range) } == "tbe")
    check("follows a noted word when words are added before it",
          WordNote.locate([note], in: "Monday\nThen we went to tbe lake").count == 1)
    check("drops a note once its word is edited", WordNote.locate([note], in: "Monday\nWe went to the lake").isEmpty)
    check("replaces a noted word", WordNote.replacing(note, with: "the", in: text) == "Monday\nWe went to the lake")

    // Notes are saved with the page and can be cleared.
    let vault = try Vault.create(in: directory.appendingPathComponent("notes"), password: "synthetic password").vault
    let journal = try vault.createJournal(name: "Notes")
    let page = try vault.addPage(journalID: journal.id, number: 1, jpeg: syntheticPhoto())
    try vault.saveReading(pageID: page.id, transcription: LocalReader.transcription(of: text, notes: [note]))
    check("saves word notes with the page", try vault.pages().first?.structure?.wordNotes == [note])
    try vault.setWordNotes(pageID: page.id, notes: [])
    check("clears word notes", try vault.pages().first?.structure?.wordNotes == nil)

    // Words fixed in the reading window while the page was read.
    let reading = LocalReadResult(text: "We went to tbe lake\nlater on",
                                  notes: [WordNote(line: 0, word: 3, text: "tbe", read: "the", options: [], confidence: 0.4)])
    let fixed = reading.applying([0: [3: "the"]])
    check("fixes made while reading are saved", fixed.text == "We went to the lake\nlater on")
    check("a fixed word's note is dropped", fixed.notes.isEmpty)

    // Words removed in the reading window because they aren't on the page.
    let stray = LocalReadResult(text: "We xx went to tbe lake\nlater on", notes: [
        WordNote(line: 0, word: 1, text: "xx", read: "xx", options: [], confidence: 0.2),
        WordNote(line: 0, word: 4, text: "tbe", read: "the", options: ["the"], confidence: 0.4),
        WordNote(line: 1, word: 1, text: "on", read: "on", options: [], confidence: 0.3),
    ])
    let cleaned = stray.applying([0: [1: ""]])
    check("a removed word is left out", cleaned.text == "We went to tbe lake\nlater on")
    check("a removed word's note goes with it", !cleaned.notes.contains { $0.text == "xx" })
    check("later notes in the line move back to stay on their word",
          cleaned.notes.first { $0.text == "tbe" }.map { WordNote.locate([$0], in: cleaned.text).first?.note.word == 3 } == true
            && cleaned.notes.first { $0.text == "tbe" }?.word == 3)
    check("notes on other lines stay put", cleaned.notes.first { $0.text == "on" }?.word == 1)

    // A reading stopped partway is saved with the page, encrypted, and cleared once a reading finishes.
    let progress = LocalReadProgress(layoutKey: "key", lines: [[.init(text: "We", confidence: 0.9, changed: false)]],
                                     notes: [note], bestMatches: [0.04], edits: [0: [0: "Wee"], 2: [1: ""]])
    try vault.saveProgress(pageID: page.id, progress: progress)
    check("saves a reading partway", try vault.progress(pageID: page.id) == progress)
    check("knows which pages have a reading partway", try vault.pagesWithProgress() == [page.id])
    try vault.saveReading(pageID: page.id, transcription: LocalReader.transcription(of: text))
    check("a finished reading clears the saved progress", try vault.progress(pageID: page.id) == nil)
    try vault.saveProgress(pageID: page.id, progress: progress)
    try vault.deletePage(id: page.id)
    check("deleting a page deletes its saved progress", try vault.pagesWithProgress().isEmpty)
    let raw = try Data(contentsOf: Vault.databaseURL(in: directory.appendingPathComponent("notes")))
    check("saved progress isn't readable on disk", !fileContains(Vault.databaseURL(in: directory.appendingPathComponent("notes")),
                                                                  Data("layoutKey".utf8)) && !raw.isEmpty)

    // Apostrophes Vision dropped or read as a letter.
    check("offers didn't for didnt", CandidateMaker.apostropheOptions(for: "didnt") == ["didn't"])
    check("offers I'm for Im", CandidateMaker.apostropheOptions(for: "Im") == ["I'm"])
    check("offers wasn't for wasnit", CandidateMaker.apostropheOptions(for: "wasnit").contains("wasn't"))
    check("offers it's for its", CandidateMaker.apostropheOptions(for: "its") == ["it's"])
    check("leaves ordinary words alone", CandidateMaker.apostropheOptions(for: "house").isEmpty)
    let maker = CandidateMaker(words: CandidateMaker.loadDictionary())
    check("counts contractions as words", maker.isWord("didn't") && maker.isWord("I'm"))
    check("an obvious apostrophe fix is easy", maker.switchMargin(from: "didnt", to: "didn't") < 2)
}

func runScribbleChecks() async throws {
    print("\nScribbled-out writing")
    let jpeg = try PagePhoto.prepare(handwrittenPage())
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)!
    let lines = try await PageLayoutFinder.find(in: image).lines.map { $0.words.map(\.text).joined(separator: " ") }
    let marked = lines.filter { $0.contains(Scribbles.mark) }
    check("marks the crossed-out word with ###", marked.count == 1 && marked.first?.hasPrefix(Scribbles.mark) == true)
    check("marks nothing else", lines.joined(separator: " ").components(separatedBy: Scribbles.mark).count == 2)
    if marked.count != 1 { lines.forEach { print("        | \($0)") } }

    // A scribble drawn as a loose coil that touches a printed ruled line, beside a few letter-like strokes.
    let width = 1000, height = 700, pitch = 60.0
    let page = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    page.setFillColor(CGColor(gray: 0.95, alpha: 1))
    page.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Rules dark enough to count as ink at the usual threshold, as on the real ruled page.
    page.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
    page.setLineWidth(2)
    for row in stride(from: 50.0, to: Double(height) - 20, by: pitch) {
        page.move(to: CGPoint(x: 0, y: row)); page.addLine(to: CGPoint(x: Double(width), y: row))
    }
    page.strokePath()
    page.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
    page.setLineWidth(3)
    // Letters: open loops and upright strokes standing on a rule.
    for x in stride(from: 120.0, to: 900, by: 70) where abs(x - 470) > 80 {
        page.strokeEllipse(in: CGRect(x: x, y: 290, width: 26, height: 30))
        page.move(to: CGPoint(x: x + 30, y: 290)); page.addLine(to: CGPoint(x: x + 30, y: 335))
    }
    page.strokePath()
    // The coil: loop over loop, drifting sideways, its bottom on the rule at 290.
    for turn in 0..<22 {
        let shift = Double(turn) * 2.2
        page.strokeEllipse(in: CGRect(x: 440 + shift + 6 * sin(Double(turn)), y: 290 + 3 * cos(Double(turn) * 1.7),
                                      width: 30, height: 40))
    }
    let coiled = page.makeImage()!
    let found = Scribbles.find(in: coiled, lineHeight: pitch / Double(height))
    let coil = CGRect(x: 0.44, y: 1 - 335.0 / Double(height), width: 0.08, height: 50 / Double(height))
    check("finds a loose coil touching a ruled line", found.contains { $0.intersects(coil) })
    check("doesn't take letters for scribbles", found.allSatisfy { $0.intersects(coil) })
    if found.count != 1 { print("        found \(found)") }
}

/// The update bar must not ask for more height than a bar needs, or the window grows to fit it.
@MainActor
func runBannerChecks() {
    print("\nUpdate bar")
    for state in [Updater.State.preparing, .ready, .failed("The new version didn't build.")] {
        // SwiftUI asks how tall the bar is at small widths when working out the window's minimum size.
        let controller = NSHostingController(rootView: UpdateBanner(updater: .preview(state)))
        let narrow = controller.sizeThatFits(in: CGSize(width: 60, height: 100_000))
        let natural = controller.sizeThatFits(in: CGSize(width: 1240, height: 100_000))
        print(String(format: "        %@: %.0f tall at full width, %.0f tall when squeezed", "\(state)", natural.height, narrow.height))
        check("the update bar stays a bar (\(state))", natural.height < 90 && narrow.height < 90)
    }
}

func runRotationChecks() async throws {
    print("\nTurning photos")
    let crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
    check("four quarter turns bring a crop back", PagePhoto.rotatedCrop(crop, quarters: 4) == crop
          && abs(PagePhoto.rotatedCrop(PagePhoto.rotatedCrop(crop, quarters: 1), quarters: -1).minX - crop.minX) < 1e-9)
    let quarter = PagePhoto.rotatedCrop(crop, quarters: 1)
    check("a quarter turn moves the crop with the photo", abs(quarter.minX - 0.2) < 1e-9 && abs(quarter.minY - 0.1) < 1e-9
          && abs(quarter.width - 0.6) < 1e-9 && abs(quarter.height - 0.5) < 1e-9)

    let jpeg = try PagePhoto.prepare(handwrittenPage())
    let upright = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)!
    let sideways = try PagePhoto.rotated(jpeg, degrees: -90)
    let turned = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(sideways as CFData, nil)!, 0, nil)!
    check("a quarter turn swaps width and height", turned.width == upright.height && turned.height == upright.width)
    let tilted = PagePhoto.rotated(upright, degrees: 4)!
    check("a small turn keeps every corner", tilted.width > upright.width && tilted.height > upright.height)
    // A page photographed sideways, turned back by the same quarter turn, reads like the upright page.
    let restored = try PageFlattener.process(sideways, crop: PageScanResult.whole.crop, flatten: false, rotation: 90)
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(restored as CFData, nil)!, 0, nil)!
    let lines = try await PageLayoutFinder.find(in: image).lines
    check("a sideways photo turned upright reads every line", lines.count == handwrittenLines.filter { !$0.isEmpty }.count)
}

/// The Straighten slider turns the crop frame over a still photo; the photo is turned and cut only once.
func runTiltedCropChecks() throws {
    print("\nStraightening with a turned frame")
    let width = 900, height = 600
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A dark dot at (630, 210) from the top left; drawing coordinates start at the bottom left.
    let dot = CGPoint(x: 630, y: 210)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillEllipse(in: CGRect(x: dot.x - 8, y: Double(height) - dot.y - 8, width: 16, height: 16))
    let photo = context.makeImage()!
    let aspect = Double(width) / Double(height)
    for degrees in [-11.0, 7.5] {
        // A frame centered on the dot.
        let frame = CGRect(x: dot.x / Double(width) - 0.1, y: dot.y / Double(height) - 0.12, width: 0.2, height: 0.24)
        let canvas = TiltedCrop.canvasCrop(frame, degrees: degrees, aspect: aspect)
        let turned = PagePhoto.rotated(photo, degrees: degrees)!
        let cut = turned.cropping(to: CGRect(x: canvas.minX * Double(turned.width), y: canvas.minY * Double(turned.height),
                                             width: canvas.width * Double(turned.width),
                                             height: canvas.height * Double(turned.height)).integral)!
        let found = darkCenter(cut)
        let middleX = found.x, middleY = found.y
        check(String(format: "a frame turned %+.1f° cuts the spot it was centered on", degrees),
              abs(middleX - 0.5) < 0.03 && abs(middleY - 0.5) < 0.03)
        check(String(format: "the cut keeps the frame's size at %+.1f°", degrees),
              abs(Double(cut.width) - 0.2 * Double(width)) < 3 && abs(Double(cut.height) - 0.24 * Double(height)) < 3)
    }
    let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
    check("an unturned frame is the crop itself", TiltedCrop.canvasCrop(whole, degrees: 0, aspect: aspect) == whole)
    let fitted = TiltedCrop.fitted(whole, degrees: 6, aspect: aspect)
    check("a turned whole-photo frame shrinks to stay inside the photo",
          TiltedCrop.fits(fitted, degrees: 6, aspect: aspect) && fitted.width < 1 && fitted.width > 0.7)
    let small = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)
    let kept = TiltedCrop.fitted(small, degrees: 6, aspect: aspect)
    check("a frame that fits isn't changed", abs(kept.minX - small.minX) < 1e-9 && abs(kept.minY - small.minY) < 1e-9
          && abs(kept.width - small.width) < 1e-9 && abs(kept.height - small.height) < 1e-9)

    // The frame as drawn turns the way the photo will: a mark just inside its drawn top-left corner ends up
    // in the top-left corner of the cut.
    let frame = CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5)
    for degrees in [-12.0, 12.0] {
        let corners = TiltedCrop.corners(frame, degrees: degrees, aspect: aspect)
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        let mark = CGPoint(x: (corners[0].x * 0.85 + middle.x * 0.15) * Double(width),
                           y: (corners[0].y * 0.85 + middle.y * 0.15) * Double(height))
        let drawing = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        drawing.setFillColor(CGColor(gray: 1, alpha: 1))
        drawing.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawing.setFillColor(CGColor(gray: 0, alpha: 1))
        drawing.fillEllipse(in: CGRect(x: mark.x - 6, y: Double(height) - mark.y - 6, width: 12, height: 12))
        let turned = PagePhoto.rotated(drawing.makeImage()!, degrees: degrees)!
        let canvas = TiltedCrop.canvasCrop(frame, degrees: degrees, aspect: aspect)
        let cut = turned.cropping(to: CGRect(x: canvas.minX * Double(turned.width), y: canvas.minY * Double(turned.height),
                                             width: canvas.width * Double(turned.width),
                                             height: canvas.height * Double(turned.height)).integral)!
        let found = darkCenter(cut)
        check(String(format: "the drawn frame turns the way the photo is turned (%+.0f°)", degrees),
              abs(found.x - 0.075) < 0.03 && abs(found.y - 0.075) < 0.03)
    }
    let corner = TiltedCrop.fitted(CGRect(x: 0.75, y: 0.75, width: 0.3, height: 0.3), degrees: -9, aspect: aspect)
    check("a frame past the edge is moved back inside", TiltedCrop.fits(corner, degrees: -9, aspect: aspect)
          && abs(corner.width - 0.3) < 1e-9)
}

/// Where the dark pixels of an image sit, as fractions of its width and height from the top left.
func darkCenter(_ image: CGImage) -> CGPoint {
    let width = image.width, height = image.height
    var gray = [UInt8](repeating: 255, count: width * height)
    gray.withUnsafeMutableBytes { raw in
        let drawing = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        drawing.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var sumX = 0.0, sumY = 0.0, count = 0.0
    for (index, value) in gray.enumerated() where value < 128 {
        sumX += Double(index % width); sumY += Double(index / width); count += 1
    }
    guard count > 0 else { return CGPoint(x: -1, y: -1) }
    return CGPoint(x: sumX / count / Double(width), y: sumY / count / Double(height))
}

/// Words placed back on the photo as saved, and their ink colored by confidence.
@MainActor
func runWordPlacementChecks() async throws {
    print("\nPlacing words on the photo")
    // A dot on a page, levelled the way the reader levels a tilted page: the dot's place on the levelled page
    // turns back to its place on the photo.
    let width = 1000, height = 1400
    let dot = CGPoint(x: 700, y: 300)
    let drawing = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    drawing.setFillColor(CGColor(gray: 1, alpha: 1))
    drawing.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawing.setFillColor(CGColor(gray: 0, alpha: 1))
    drawing.fillEllipse(in: CGRect(x: dot.x - 7, y: Double(height) - dot.y - 7, width: 14, height: 14))
    let photo = drawing.makeImage()!
    for tilt in [0.06, -0.09] {
        let level = Straightener.rotate(photo, by: -tilt)!
        let found = darkCenter(level)
        let layout = PageLayout(lines: [], tilt: tilt, aspect: Double(width) / Double(height))
        let outline = layout.photoOutline(of: CGRect(x: found.x - 0.001, y: found.y - 0.001, width: 0.002, height: 0.002))
        let sumX: Double = outline.reduce(0) { $0 + $1.x }, sumY: Double = outline.reduce(0) { $0 + $1.y }
        let back = CGPoint(x: sumX / 4 * Double(width), y: sumY / 4 * Double(height))
        check(String(format: "a word on a page levelled by %.2f turns back to its place on the photo", tilt),
              hypot(back.x - dot.x, back.y - dot.y) < 3)
    }

    // Dark strokes in a word's outline are colored; faint marks and ink outside it aren't.
    let page = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    page.setFillColor(CGColor(gray: 0.95, alpha: 1))
    page.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
    page.setFillColor(CGColor(gray: 0.1, alpha: 1))
    page.fill(CGRect(x: 40, y: 80, width: 60, height: 8))      // a stroke in the word
    page.fill(CGRect(x: 300, y: 80, width: 60, height: 8))     // a stroke of another word
    page.setFillColor(CGColor(gray: 0.78, alpha: 1))
    page.fill(CGRect(x: 120, y: 80, width: 40, height: 8))     // show-through, inside the word's box
    let image = page.makeImage()!
    let box = CGRect(x: 0.05, y: 0.3, width: 0.45, height: 0.4)
    let overlay = InkTint.overlay(for: image, regions: [InkTint.Region(box: box, red: 1, green: 0, blue: 0)])
    func alpha(_ x: Int, _ yFromTop: Int) -> Int {
        guard let overlay, let data = overlay.dataProvider?.data as Data? else { return -1 }
        return Int(data[yFromTop * overlay.bytesPerRow + x * 4 + 3])
    }
    // Drawing rows count from the bottom; the strokes sit 116 to 120 from the top.
    check("colors the word's ink", alpha(70, 116) > 200)
    check("leaves the paper clear", alpha(70, 60) == 0)
    check("leaves faint show-through clear", alpha(140, 116) == 0)
    check("leaves other words alone", alpha(330, 116) == 0)
    check("nothing to color gives no overlay", InkTint.overlay(for: image, regions: []) == nil)

    // Removing a word in the reading window, and putting it back.
    let session = LocalReadSession(pageID: UUID(), pageNumber: 1, journalName: "Check", photo: nil, settings: .init())
    let words = ["We", "xx", "walked"].enumerated().map { index, text in
        LayoutWord(text: text, alternatives: [], box: CGRect(x: 0.1 + Double(index) * 0.2, y: 0.1, width: 0.15, height: 0.05),
                   letters: [])
    }
    let layout = PageLayout(lines: [LayoutLine(box: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.05), words: words)])
    session.apply(.started(layout, image: photo))
    var saved: [LocalReadProgress] = []
    session.onProgress = { saved.append($0) }
    for (index, word) in words.enumerated() {
        session.apply(.wordFinished(line: 0, word: index, text: word.text, confidence: 0.9))
    }
    session.edit(line: 0, word: 1, to: "  ")
    check("an emptied word is removed", session.lines[0][1].removed && session.transcript == "We walked")
    check("removing a word saves progress", saved.last?.edits[0]?[1] == "")
    session.restore(line: 0, word: 1)
    check("a removed word can be restored", !session.lines[0][1].removed && session.transcript == "We xx walked"
          && session.edits.isEmpty)

    // Picking up a reading stopped partway.
    let resumed = LocalReadSession(pageID: UUID(), pageNumber: 1, journalName: "Check", photo: nil, settings: .init())
    resumed.apply(.started(layout, image: photo))
    resumed.apply(.resumed(LocalReadProgress(layoutKey: layout.key,
                                             lines: [[.init(text: "We", confidence: 0.9, changed: false),
                                                      .init(text: "xx", confidence: 0.3, changed: false),
                                                      .init(text: "walked", confidence: 0.8, changed: true)]],
                                             edits: [0: [1: ""]])))
    check("a resumed reading shows the lines already read", resumed.wordsDone == 3 && resumed.transcript == "We walked")
    check("a resumed reading keeps her fixes", resumed.lines[0][1].removed && resumed.lines[0][2].changed)
}
