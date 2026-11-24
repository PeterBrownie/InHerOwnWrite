import CoreGraphics
import Foundation
import Vision

/// Where the writing is on a page. Rectangles are normalized to the page, with the origin at the top left.
public struct PageLayout: Sendable, Equatable {
    public var lines: [LayoutLine]
    /// A printed or handwritten page number, left out of `lines`.
    public var pageNumber: Int?
    /// How far the photo was turned to level its lines before they were found, in radians, counterclockwise
    /// as Vision measures slant. The rectangles refer to the turned photo.
    public var tilt: Double
    /// The photo's width over its height.
    public var aspect: Double

    public init(lines: [LayoutLine], pageNumber: Int? = nil, tilt: Double = 0, aspect: Double = 1) {
        self.lines = lines
        self.pageNumber = pageNumber
        self.tilt = tilt
        self.aspect = aspect
    }

    public var wordCount: Int { lines.reduce(0) { $0 + $1.words.count } }

    /// A rectangle of the levelled page as four corners on the photo as saved, normalized with the origin at
    /// the top left, starting at the top left and going clockwise. The page is levelled by turning it about
    /// its center without changing its size, so this turns the corners back.
    public func photoOutline(of box: CGRect) -> [CGPoint] {
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        guard tilt != 0 else { return corners }
        // In pixels of a photo one unit tall, with y pointing down, the levelled page is the photo turned by
        // the tilt; going back is a turn by minus the tilt.
        let cosine = cos(-tilt), sine = sin(-tilt)
        return corners.map { point in
            let x = (point.x - 0.5) * aspect, y = point.y - 0.5
            return CGPoint(x: (x * cosine - y * sine) / aspect + 0.5, y: x * sine + y * cosine + 0.5)
        }
    }

    /// Identifies a layout, so a reading saved partway can tell whether it still lines up with the page.
    public var key: String {
        lines.map { line in
            line.words.map { word in
                String(format: "%@@%.2f,%.2f", word.text, word.box.midX, word.box.midY)
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

public struct LayoutLine: Sendable, Equatable {
    public var box: CGRect
    public var words: [LayoutWord]

    public init(box: CGRect, words: [LayoutWord]) {
        self.box = box
        self.words = words
    }
}

public struct LayoutWord: Sendable, Equatable {
    /// Vision's reading, including any punctuation attached to the word.
    public var text: String
    /// Other readings Vision considered for the same word.
    public var alternatives: [String]
    public var box: CGRect
    /// One rectangle per character of `text`.
    public var letters: [CGRect]

    public init(text: String, alternatives: [String], box: CGRect, letters: [CGRect]) {
        self.text = text
        self.alternatives = alternatives
        self.box = box
        self.letters = letters
    }
}

/// Finds lines and words with Apple's on-device Vision framework, then splits each word into letters.
public enum PageLayoutFinder {
    /// Reads the page in overlapping strips about one line tall. Asked about a whole page of handwriting
    /// on ruled paper, Vision skips whole bands of lines and merges neighbors into one; asked about a strip,
    /// it reliably reads the line in it. Overlapping strips also read each line more than once, and those
    /// readings become options for the decision model.
    public static func find(in image: CGImage) async throws -> PageLayout {
        try await read(image).layout
    }

    /// Straightens the page, then finds its lines. The layout's rectangles refer to the returned image.
    public static func read(_ original: CGImage) async throws -> (layout: PageLayout, image: CGImage) {
        var image = original
        var overview = try await recognize(image)
        var turned = 0.0
        let tilt = Straightener.tilt(of: overview, width: image.width, height: image.height)
        if abs(tilt) > 0.004, let level = Straightener.rotate(image, by: -tilt) {
            image = level
            turned = tilt
            overview = try await recognize(image)
        }
        let found = overview.compactMap { observation -> FoundText? in
            observation.topCandidates(1).first.map {
                FoundText(text: $0.string, box: topLeft(observation.boundingBox.cgRect))
            }
        }
        let number = PageNumberFinder.find(in: found)
        let ink = InkMap(image: image)
        // Lines of writing repeat down the page at a steady pitch; Vision's boxes for slanted lines are too tall.
        let lineHeight = ink?.linePitch() ?? estimateLineHeight(found.filter { $0.box != number?.box })

        let tall = lineHeight * 1.5
        let step = lineHeight * 0.5
        var readings: [StripReading] = []
        var top = 0.0
        while top < 1 {
            try Task.checkCancellation()
            let stripTop = min(top, max(0, 1 - tall))
            let rect = CGRect(x: 0, y: stripTop * Double(image.height), width: Double(image.width),
                              height: tall * Double(image.height)).integral
            if let strip = image.cropping(to: rect) {
                // One strip Vision can't read shouldn't cost the page; its neighbors overlap it.
                let observations: [RecognizedTextObservation]
                do {
                    observations = try await recognize(strip)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    observations = []
                }
                readings += StripReading.make(from: observations, stripTop: stripTop, stripHeight: tall,
                                              lineHeight: lineHeight)
            }
            if stripTop + tall >= 1 { break }
            top += step
        }

        let lines = StripReading.cluster(readings, lineHeight: lineHeight)
            .compactMap { group -> LayoutLine? in
                let line = makeLine(group, lineHeight: lineHeight, ink: ink)
                guard let line, !line.words.isEmpty else { return nil }
                // The page number is kept out of the text; it's offered when the page is added.
                if let number, PageNumberFinder.number(in: line.words.map(\.text).joined(separator: " ")) == number.value {
                    return nil
                }
                return line
            }
            .sorted { $0.box.minY < $1.box.minY }
        // A first or last line that is only a number is the page number, even if the overview missed it.
        var pageNumber = number?.value
        var kept = Scribbles.mark(Scribbles.find(in: image, lineHeight: lineHeight), in: lines)
        for index in [kept.count - 1, 0] where kept.indices.contains(index) {
            if let value = PageNumberFinder.number(in: kept[index].words.map(\.text).joined(separator: " ")) {
                pageNumber = pageNumber ?? value
                kept.remove(at: index)
            }
        }
        return (PageLayout(lines: kept, pageNumber: pageNumber, tilt: turned,
                           aspect: Double(original.width) / Double(max(original.height, 1))), image)
    }

    static func recognize(_ image: CGImage) async throws -> [RecognizedTextObservation] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        return try await request.perform(on: image)
    }

    /// Typical height of one line of writing. Vision's merged lines are taller, so a low percentile is used.
    static func estimateLineHeight(_ found: [FoundText]) -> Double {
        let heights = found
            .filter { $0.box.width > 0.08 && $0.text.split(separator: " ").count >= 2 }
            .map(\.box.height)
            .sorted()
        guard !heights.isEmpty else { return 0.03 }
        return min(max(heights[heights.count * 3 / 10], 0.012), 0.12)
    }

    /// Picks the best-framed full reading of a line, and keeps the others as alternatives for each word.
    static func makeLine(_ group: [StripReading], lineHeight: Double, ink: InkMap?) -> LayoutLine? {
        // The reading that agrees most with the others, among those that span the whole line.
        let widest = group.map(\.box.width).max() ?? 0
        let full = group.filter { $0.box.width >= widest * 0.85 }
        func agreement(_ reading: StripReading) -> Double {
            let mine = Set(reading.words.map { $0.text.lowercased() })
            let shared = group.filter { $0.id != reading.id }.reduce(0) { total, other in
                total + other.words.filter { mine.contains($0.text.lowercased()) }.count
            }
            return Double(shared) - reading.offCenter * 0.5
        }
        guard let best = full.max(by: { agreement($0) < agreement($1) }) else { return nil }
        let words = best.words.map { word -> LayoutWord in
            var others: [String] = []
            // Only readings centered on the same line; others can belong to the line above or below.
            for reading in group where reading.id != best.id && abs(reading.center - best.center) < lineHeight * 0.35 {
                let match = reading.words.max { overlap($0.box, word.box) < overlap($1.box, word.box) }
                if let match, overlap(match.box, word.box) >= 0.5 * min(match.box.width, word.box.width),
                   match.text != word.text, !others.contains(match.text) {
                    others.append(match.text)
                }
            }
            let letters = ink.map { LetterSplitter.split(text: word.text, box: word.box, ink: $0) }
                ?? LetterSplitter.evenly(text: word.text, box: word.box)
            return LayoutWord(text: word.text, alternatives: others, box: word.box, letters: letters)
        }
        return LayoutLine(box: best.box, words: words)
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }

    static func tokenRanges(_ string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = string.startIndex
        while index < string.endIndex {
            if string[index].isWhitespace {
                if let open = start { ranges.append(open..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
            index = string.index(after: index)
        }
        if let open = start { ranges.append(open..<string.endIndex) }
        return ranges
    }

    /// Vision's rectangles start at the bottom left.
    static func topLeft(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Finds writing that has been scribbled out. Vision reads a scribble as stray letters or skips it, so it is
/// found from the ink itself instead: a scribble is a blot whose box is mostly ink, while letters, even
/// joined-up words, leave most of their box empty. Scribbles become "###", as in readings from Claude.
public enum Scribbles {
    public static let mark = "###"

    /// Boxes of scribbled-out writing, normalized to the page with the origin at the top left.
    public static func find(in image: CGImage, lineHeight: Double) -> [CGRect] {
        blots(in: image, lineHeight: lineHeight).filter(isScribble).map(\.box)
    }

    struct Blot {
        let box: CGRect
        /// Share of the box that is ink.
        let fill: Double
        /// Size relative to the line pitch.
        let height: Double
        let width: Double
        /// Share of the blot's ink that is solid: inside a run of ink at least a pen stroke and a half wide.
        let solid: Double
    }

    /// Tested on three real pages: scribbles had a solid core of 0.3 to 0.4, and letters, even heavy ones,
    /// 0.15 or less. Ink touching the photo's edge is paper edges, binding, or shadow.
    static func isScribble(_ blot: Blot) -> Bool {
        let edge = 0.01
        return blot.solid >= 0.2 && blot.fill >= 0.4 && blot.height >= 0.45 && blot.width >= 0.45
            && blot.height <= 2.5 && blot.width <= 8
            && blot.box.minX > edge && blot.box.maxX < 1 - edge && blot.box.minY > edge && blot.box.maxY < 1 - edge
    }

    static func blots(in image: CGImage, lineHeight: Double) -> [Blot] {
        guard let ink = InkMap(image: image, maxDimension: 1000) else { return [] }
        let width = ink.width, height = ink.height
        let threshold = ink.middleThreshold()
        let pitch = lineHeight * Double(height)
        var seen = [Bool](repeating: false, count: width * height)
        var found: [Blot] = []
        var stack: [Int] = []
        for start in 0..<(width * height) where !seen[start] && ink.pixels[start] < threshold {
            seen[start] = true
            stack.append(start)
            var minX = width, maxX = 0, minY = height, maxY = 0, count = 0
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for neighbor in [index - 1, index + 1, index - width, index + width] {
                    guard neighbor >= 0, neighbor < width * height, !seen[neighbor] else { continue }
                    if (neighbor == index - 1 && x == 0) || (neighbor == index + 1 && x == width - 1) { continue }
                    if ink.pixels[neighbor] < threshold {
                        seen[neighbor] = true
                        stack.append(neighbor)
                    }
                }
            }
            let boxWidth = Double(maxX - minX + 1), boxHeight = Double(maxY - minY + 1)
            guard boxHeight >= pitch * 0.3, boxWidth >= pitch * 0.3, count > 20 else { continue }
            let fill = Double(count) / (boxWidth * boxHeight)
            // How much of the ink is solid, rather than strokes: ink with ink a few pixels away on all sides.
            let reach = max(2, Int(pitch * 0.06))
            var solid = 0
            for y in minY...maxY {
                for x in minX...maxX where ink.pixels[y * width + x] < threshold {
                    let around = [(x - reach, y), (x + reach, y), (x, y - reach), (x, y + reach)]
                    if around.allSatisfy({ $0.0 >= 0 && $0.0 < width && $0.1 >= 0 && $0.1 < height
                        && ink.pixels[$0.1 * width + $0.0] < threshold }) { solid += 1 }
                }
            }
            found.append(Blot(box: CGRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
                                          width: boxWidth / Double(width), height: boxHeight / Double(height)),
                              fill: fill, height: boxHeight / pitch, width: boxWidth / pitch,
                              solid: Double(solid) / Double(count)))
        }
        return found
    }

    /// Replaces the words a scribble covers with "###", or adds "###" where it sits between words.
    static func mark(_ scribbles: [CGRect], in lines: [LayoutLine]) -> [LayoutLine] {
        var lines = lines
        for scribble in scribbles {
            // The line it sits on: the most vertical overlap.
            let overlaps = lines.map { line -> Double in
                max(0, min(line.box.maxY, scribble.maxY) - max(line.box.minY, scribble.minY))
            }
            guard let index = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }),
                  overlaps[index] > scribble.height * 0.3,
                  // Within the line's own span, not off in the margin.
                  scribble.midX >= lines[index].box.minX - scribble.width, scribble.midX <= lines[index].box.maxX
            else { continue }
            var words = lines[index].words
            let covered = words.indices.filter { word in
                let box = words[word].box
                let shared = max(0, min(box.maxX, scribble.maxX) - max(box.minX, scribble.minX))
                return shared >= box.width * 0.4
            }
            let note = LayoutWord(text: mark, alternatives: [], box: scribble,
                                  letters: LetterSplitter.evenly(text: mark, box: scribble))
            if let first = covered.first, let last = covered.last {
                words.replaceSubrange(first...last, with: [note])
            } else {
                let position = words.firstIndex { $0.box.midX > scribble.midX } ?? words.count
                words.insert(note, at: position)
            }
            lines[index].words = words
        }
        return lines
    }
}

/// Levels a photographed page so its lines of writing run straight across.
public enum Straightener {
    /// The median slant of the longer lines Vision found, in radians, counterclockwise.
    static func tilt(of observations: [RecognizedTextObservation], width: Int, height: Int) -> Double {
        let angles = observations.compactMap { observation -> Double? in
            let left = observation.bottomLeft.cgPoint, right = observation.bottomRight.cgPoint
            let dx = (right.x - left.x) * Double(width), dy = (right.y - left.y) * Double(height)
            guard dx > Double(width) * 0.25 else { return nil }
            return atan2(dy, dx)
        }.sorted()
        guard angles.count >= 3 else { return 0 }
        let middle = angles[angles.count / 2]
        return abs(middle) < 0.2 ? middle : 0
    }

    /// Rotates around the center, keeping the size. Corners are filled with the page's own edge color.
    public static func rotate(_ image: CGImage, by radians: Double) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(edgeColor(image))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.translateBy(x: Double(width) / 2, y: Double(height) / 2)
        context.rotate(by: radians)
        context.draw(image, in: CGRect(x: -Double(width) / 2, y: -Double(height) / 2,
                                       width: Double(width), height: Double(height)))
        return context.makeImage()
    }

    static func edgeColor(_ image: CGImage) -> CGColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return CGColor(gray: 0.9, alpha: 1) }
        return CGColor(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255, alpha: 1)
    }
}

/// One line as read from one strip, in page coordinates.
struct StripReading {
    struct Word {
        let text: String
        let box: CGRect
    }

    let id: Int
    let box: CGRect
    let words: [Word]
    /// How far the line sits from the middle of its strip, in line heights. Lower is better framed.
    let offCenter: Double

    var center: Double { box.midY }

    static func make(from observations: [RecognizedTextObservation], stripTop: Double, stripHeight: Double,
                     lineHeight: Double) -> [StripReading] {
        func toPage(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: stripTop + (1 - rect.maxY) * stripHeight,
                   width: rect.width, height: rect.height * stripHeight)
        }
        // Lines cut off by the strip's edge are read better by a neighboring strip.
        let pieces = observations.compactMap { observation -> (box: CGRect, words: [Word])? in
            let box = observation.boundingBox.cgRect
            // Skip slivers of lines cut off by the strip's edge; a neighboring strip holds all of it. Handwriting
            // fills most of a strip, while small, widely spaced writing sits clear of both edges.
            let clear = box.minY > 0.03 && box.maxY < 0.97
            guard box.height >= 0.4 || clear, let best = observation.topCandidates(1).first else { return nil }
            let words = PageLayoutFinder.tokenRanges(best.string).compactMap { range -> Word? in
                guard let region = best.boundingBox(for: range) else { return nil }
                return Word(text: String(best.string[range]), box: toPage(region.boundingBox.cgRect))
            }
            return words.isEmpty ? nil : (toPage(box), words)
        }
        // Pieces of one line side by side, such as a date and a time, become one reading.
        var rows: [(box: CGRect, words: [Word])] = []
        for piece in pieces.sorted(by: { $0.box.minX < $1.box.minX }) {
            // Side by side, not stacked: pieces of two different lines overlap left to right.
            if let index = rows.firstIndex(where: {
                abs($0.box.midY - piece.box.midY) < lineHeight * 0.5
                    && PageLayoutFinder.overlap($0.box, piece.box) < 0.2 * min($0.box.width, piece.box.width)
            }) {
                rows[index].box = rows[index].box.union(piece.box)
                rows[index].words += piece.words
            } else {
                rows.append(piece)
            }
        }
        let middle = stripTop + stripHeight / 2
        let firstID = Int((stripTop * 1_000_000).rounded()) * 100
        return rows.enumerated().map { index, row in
            StripReading(id: firstID + index, box: row.box, words: row.words,
                         offCenter: abs(row.box.midY - middle) / lineHeight)
        }
    }

    /// Readings from overlapping strips that are the same line.
    static func cluster(_ readings: [StripReading], lineHeight: Double) -> [[StripReading]] {
        var groups: [(center: Double, members: [StripReading])] = []
        for reading in readings.sorted(by: { $0.center < $1.center }) {
            if let last = groups.indices.last, abs(groups[last].center - reading.center) < lineHeight * 0.55 {
                groups[last].members.append(reading)
                let centers = groups[last].members.map(\.center)
                groups[last].center = centers.reduce(0, +) / Double(centers.count)
            } else {
                groups.append((reading.center, [reading]))
            }
        }
        return groups.map(\.members)
    }
}

/// A grayscale copy of the page, used to find the gaps between letters.
public struct InkMap: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let threshold: UInt8

    public init?(image: CGImage, maxDimension: Int = 2400) {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 255, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        pixels = buffer
        threshold = Self.otsu(buffer)
    }

    /// The distance between lines of writing, as a fraction of the page height, from how the ink in each
    /// row repeats down the page. Nil when nothing repeats clearly.
    public func linePitch() -> Double? {
        // The middle of the page only: the edges can hold background, and slant smears long rows.
        let x0 = width / 4, x1 = width - width / 4
        let y0 = height / 10, y1 = height - height / 10
        guard x1 > x0, y1 - y0 > 50 else { return nil }
        var middle: [UInt8] = []
        middle.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { middle += pixels[(y * width + x0)..<(y * width + x1)] }
        let ink = Self.otsu(middle)
        var rows = [Double](repeating: 0, count: y1 - y0)
        for y in y0..<y1 {
            let row = y * width
            var count = 0
            for x in x0..<x1 where pixels[row + x] < ink { count += 1 }
            rows[y - y0] = Double(count)
        }
        let span = rows.count
        let mean = rows.reduce(0, +) / Double(span)
        let centered = rows.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return nil }
        let shortest = max(4, Int(Double(height) * 0.012)), longest = min(span / 3, Int(Double(height) * 0.1))
        guard longest > shortest + 2 else { return nil }
        let scores = (shortest...longest).map { lag -> Double in
            var sum = 0.0
            for y in 0..<(span - lag) { sum += centered[y] * centered[y + lag] }
            return sum / energy
        }
        // The first peak that is nearly as strong as the strongest, so a double spacing isn't chosen.
        guard let strongest = scores.max(), strongest > 0.1 else { return nil }
        for index in 1..<(scores.count - 1) where scores[index] >= strongest * 0.8
            && scores[index] >= scores[index - 1] && scores[index] >= scores[index + 1] {
            return Double(shortest + index) / Double(height)
        }
        return nil
    }

    /// How much ink each pixel column holds inside a normalized, top-left rectangle.
    func columnInk(in rect: CGRect) -> [Int] {
        let x0 = max(0, Int(rect.minX * Double(width)))
        let x1 = min(width, Int(rect.maxX * Double(width)) + 1)
        // Pixel rows run top to bottom, matching the top-left rectangles.
        let y0 = max(0, Int(rect.minY * Double(height)))
        let y1 = min(height, Int(rect.maxY * Double(height)) + 1)
        guard x1 > x0, y1 > y0 else { return [] }
        var columns = [Int](repeating: 0, count: x1 - x0)
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 where pixels[row + x] < threshold {
                columns[x - x0] += 1
            }
        }
        return columns
    }

    static func otsu(_ pixels: [UInt8]) -> UInt8 {
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels { histogram[Int(value)] += 1 }
        let total = Double(pixels.count)
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var background = 0.0, weightBackground = 0.0, best = 0.0
        var threshold = 128
        for level in 0..<256 {
            weightBackground += Double(histogram[level])
            guard weightBackground > 0 else { continue }
            let weightForeground = total - weightBackground
            guard weightForeground > 0 else { break }
            background += Double(level * histogram[level])
            let meanBackground = background / weightBackground
            let meanForeground = (sum - background) / weightForeground
            let between = weightBackground * weightForeground * pow(meanBackground - meanForeground, 2)
            if between > best {
                best = between
                threshold = level
            }
        }
        return UInt8(threshold)
    }
}

/// Splits a word's box into one box per character. Vision only places whole words, so each cut starts
/// where the letter widths predict and then moves to the faintest nearby column of ink.
public enum LetterSplitter {
    static func relativeWidth(_ character: Character) -> Double {
        switch character {
        case "i", "l", "j", "I", "!", "'", ".", ",", ":", ";", "|", "1": return 0.45
        case "t", "f", "r": return 0.7
        case "m", "w", "M", "W": return 1.5
        case _ where character.isUppercase: return 1.2
        default: return 1
        }
    }

    public static func evenly(text: String, box: CGRect) -> [CGRect] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        let weights = characters.map(relativeWidth)
        let total = weights.reduce(0, +)
        var x = box.minX
        return weights.map { weight in
            let width = box.width * weight / total
            defer { x += width }
            return CGRect(x: x, y: box.minY, width: width, height: box.height)
        }
    }

    public static func split(text: String, box: CGRect, ink: InkMap) -> [CGRect] {
        let even = evenly(text: text, box: box)
        let columns = ink.columnInk(in: box)
        guard even.count > 1, columns.count >= even.count * 2 else { return even }
        let scale = Double(columns.count) / box.width
        let averageWidth = Double(columns.count) / Double(even.count)
        let window = max(1, Int(averageWidth * 0.35))

        var cuts: [Int] = []
        for letter in even.dropLast() {
            let target = Int((letter.maxX - box.minX) * scale)
            let lower = max((cuts.last ?? 0) + 1, target - window)
            let upper = min(columns.count - 1, target + window)
            guard lower <= upper else {
                cuts.append(min(max(target, (cuts.last ?? 0) + 1), columns.count - 1))
                continue
            }
            // The faintest column wins; ties go to the column nearest the prediction.
            let best = (lower...upper).min { a, b in
                columns[a] != columns[b] ? columns[a] < columns[b] : abs(a - target) < abs(b - target)
            } ?? target
            cuts.append(best)
        }

        let edges = [0] + cuts + [columns.count]
        return zip(edges, edges.dropFirst()).map { start, end in
            CGRect(x: box.minX + Double(start) / scale, y: box.minY,
                   width: Double(max(end - start, 1)) / scale, height: box.height)
        }
    }
}
