import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// What a first look at a photo finds: the part to keep, and the page number if one is written or printed.
public struct PageScanResult: Sendable, Equatable {
    /// The page to keep, normalized to the photo with the origin at the top left.
    public var crop: CGRect
    public var pageNumber: Int?
    public var pageNumberBox: CGRect?

    public init(crop: CGRect, pageNumber: Int? = nil, pageNumberBox: CGRect? = nil) {
        self.crop = crop
        self.pageNumber = pageNumber
        self.pageNumberBox = pageNumberBox
    }

    public static let whole = PageScanResult(crop: CGRect(x: 0, y: 0, width: 1, height: 1))
}

/// What a first look at a photo of both pages of an open journal finds: the two pages together, and where
/// the fold divides them.
public struct SpreadScanResult: Sendable, Equatable {
    /// Both pages, normalized to the photo with the origin at the top left.
    public var crop: CGRect
    /// Where the fold falls across `crop`, as a fraction of its width from the left.
    public var split: Double
    public var leftNumber: Int?
    public var rightNumber: Int?

    public init(crop: CGRect, split: Double, leftNumber: Int? = nil, rightNumber: Int? = nil) {
        self.crop = crop
        self.split = split
        self.leftNumber = leftNumber
        self.rightNumber = rightNumber
    }

    public static let whole = SpreadScanResult(crop: CGRect(x: 0, y: 0, width: 1, height: 1), split: 0.5)

    /// The left page's number: as read, or one before the right page's. When both were read but they don't
    /// follow on, the one with more digits wins, since a smudged digit is lost far more often than one is
    /// added (a printed "240" with a faint 0 reads as "24").
    public var leftPageNumber: Int? {
        let fromRight = rightNumber.flatMap { $0 > 1 ? $0 - 1 : nil }
        guard let leftNumber else { return fromRight }
        guard let rightNumber, let fromRight, rightNumber != leftNumber + 1 else { return leftNumber }
        return String(rightNumber).count > String(leftNumber).count ? fromRight : leftNumber
    }

    /// The split can't come closer than this to either side of the crop.
    public static let splitLimits = 0.15...0.85

    /// The left and right pages of an upright crop divided at `split`, a fraction of its width.
    public static func halves(of crop: CGRect, split: Double) -> (left: CGRect, right: CGRect) {
        let split = min(max(split, splitLimits.lowerBound), splitLimits.upperBound)
        let leftWidth = crop.width * split
        return (CGRect(x: crop.minX, y: crop.minY, width: leftWidth, height: crop.height),
                CGRect(x: crop.minX + leftWidth, y: crop.minY, width: crop.width - leftWidth, height: crop.height))
    }
}

/// A line of text Vision found, in top-left normalized coordinates.
struct FoundText: Sendable {
    let text: String
    let box: CGRect
}

/// Finds the page being added in a photo of an open journal. Photos often catch a strip of the
/// facing page; its text forms a separate column, which is left out of the suggested crop.
public enum PageScan {
    /// Vision can take half a minute to load its text model after a while unused. Reading a tiny blank
    /// image loads it early, so the real photo doesn't wait.
    public static func warmUp() async {
        guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        guard let image = context.makeImage() else { return }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        _ = try? await request.perform(on: image)
    }
    /// Which way up a photo reads best, and how far its writing slants once turned that way.
    public struct Orientation: Sendable, Equatable {
        /// Quarter turns clockwise that put the writing upright.
        public var quarterTurns: Int
        /// Degrees clockwise that then level the writing.
        public var tilt: Double

        public init(quarterTurns: Int, tilt: Double) {
            self.quarterTurns = quarterTurns
            self.tilt = tilt
        }

        public static let upright = Orientation(quarterTurns: 0, tilt: 0)
    }

    public static func orientation(jpeg: Data) async -> Orientation {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return .upright }
        return await orientation(of: image)
    }

    /// Which way the writing runs. Vision reads sideways and upside-down handwriting by itself, and each line
    /// it finds runs along the writing, so one look at the photo as it is tells which way is up: each long
    /// line votes for the quarter turn closest to leveling it, and what's left over in the winning lines is
    /// the tilt. Reading the photo each way up and comparing confidence was tried first; Vision read all four
    /// ways nearly as well, and it chose upside down for one of two real photos.
    public static func orientation(of image: CGImage) async -> Orientation {
        // A smaller copy is plenty to see which way lines run.
        let scale = min(1, 1400 / Double(max(image.width, image.height)))
        let small = scale < 1 ? PagePhoto.scaled(image, by: scale) ?? image : image
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard let observations = try? await request.perform(on: small) else { return .upright }
        return orientation(ofLines: observations.map { ($0.bottomLeft.cgPoint, $0.bottomRight.cgPoint) },
                           width: Double(small.width), height: Double(small.height))
    }

    /// The quarter turn and tilt from lines' baselines, as start and end points normalized to the photo with
    /// the origin at the bottom left (as Vision gives them).
    public static func orientation(ofLines lines: [(start: CGPoint, end: CGPoint)], width: Double, height: Double) -> Orientation {
        // Counterclockwise angles, in degrees, of lines long enough to show their direction.
        let angles = lines.compactMap { line -> Double? in
            let dx = (line.end.x - line.start.x) * width, dy = (line.end.y - line.start.y) * height
            guard hypot(dx, dy) > min(width, height) * 0.2 else { return nil }
            return atan2(dy, dx) * 180 / .pi
        }
        // A line running at angle a is leveled by turning the photo clockwise by a.
        let votes = Dictionary(grouping: angles) { (((Int(($0 / 90).rounded()) % 4) + 4) % 4) }
        guard let (turns, chosen) = votes.max(by: { $0.value.count < $1.value.count }), chosen.count >= 3 else {
            return .upright
        }
        let leftover = chosen.map { angle -> Double in
            var rest = (angle - Double(turns) * 90).truncatingRemainder(dividingBy: 360)
            if rest > 180 { rest -= 360 }
            if rest < -180 { rest += 360 }
            return rest
        }.sorted()
        let tilt = leftover[leftover.count / 2]
        return Orientation(quarterTurns: turns, tilt: abs(tilt) <= 15 ? tilt : 0)
    }

    public static func analyze(jpeg: Data) async -> PageScanResult {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return .whole }
        return (try? await analyze(image: image)) ?? .whole
    }

    public static func analyze(image: CGImage) async throws -> PageScanResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let found = try await request.perform(on: image).compactMap { observation -> FoundText? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return FoundText(text: text, box: PageLayoutFinder.topLeft(observation.boundingBox.cgRect))
        }
        var number = PageNumberFinder.find(in: found)
        let writing = found.filter { $0.box != number?.box }
        var crop = suggestCrop(text: writing, pageNumberBox: number?.box, paper: PaperMap(image: image))
        if number == nil, let closer = try await PageNumberFinder.lookCloser(in: image, crop: crop) {
            number = closer
            crop = crop.union(closer.box.insetBy(dx: -0.01, dy: -0.01)).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return PageScanResult(crop: crop, pageNumber: number?.value, pageNumberBox: number?.box)
    }

    public static func analyzeSpread(jpeg: Data) async -> SpreadScanResult {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return .whole }
        return (try? await analyzeSpread(image: image)) ?? .whole
    }

    /// Whether an upright photo shows both pages of an open journal, judged from a quick read of it.
    public static func showsTwoPages(jpeg: Data) async -> Bool {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        let scale = min(1, 1400 / Double(max(image.width, image.height)))
        let small = scale < 1 ? PagePhoto.scaled(image, by: scale) ?? image : image
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard let found = try? await request.perform(on: small) else { return false }
        let text = found.compactMap { observation -> FoundText? in
            guard let string = observation.topCandidates(1).first?.string else { return nil }
            return FoundText(text: string, box: PageLayoutFinder.topLeft(observation.boundingBox.cgRect))
        }
        return showsTwoPages(text: text, paper: PaperMap(image: small))
    }

    /// Two pages when the writing parts at a fold near the middle of the paper: on one page, lines run
    /// across the middle; on two, they stop at the fold, with writing on both sides. A single page that
    /// shows a strip of the facing page has its fold near an edge, so it doesn't count.
    static func showsTwoPages(text: [FoundText], paper: PaperMap?) -> Bool {
        let lines = text.filter { $0.box.width > 0.03 && $0.text.count >= 3 }
        guard lines.count >= 6 else { return false }
        let span = paper?.columnProfile()?.paper ?? 0...1
        let width = span.upperBound - span.lowerBound
        guard width > 0.3 else { return false }
        let middle = span.lowerBound + width / 2
        let window = (middle - 0.2 * width)...(middle + 0.2 * width)
        let shadow = paper?.spreadFold(within: span)
        // A shadowed fold near an edge is the facing page's strip beside a single page.
        if let shadow, !window.contains(shadow) { return false }
        guard let fold = writingGap(text: lines, within: window, favoring: shadow ?? middle) else { return false }
        let crossing = lines.filter { $0.box.minX < fold - 0.01 && $0.box.maxX > fold + 0.01 }.count
        let left = lines.filter { $0.box.maxX <= fold + 0.01 }
        let right = lines.filter { $0.box.minX >= fold - 0.01 }
        let share = Double(min(left.count, right.count)) / Double(lines.count)
        // Each page's writing spans a similar width; a few words peeking in from the facing page don't.
        func extent(_ side: [FoundText]) -> Double {
            (side.map(\.box.maxX).max() ?? 0) - (side.map(\.box.minX).min() ?? 0)
        }
        let widths = [extent(left), extent(right)]
        let balanced = (widths.min() ?? 0) >= 0.45 * (widths.max() ?? 1)
        return Double(crossing) <= Double(lines.count) * 0.1 && share >= 0.2 && balanced
    }

    /// Both pages of an open journal: the paper of both, split at the fold, with each page's number.
    public static func analyzeSpread(image: CGImage) async throws -> SpreadScanResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let found = try await request.perform(on: image).compactMap { observation -> FoundText? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return FoundText(text: text, box: PageLayoutFinder.topLeft(observation.boundingBox.cgRect))
        }
        let paper = PaperMap(image: image)
        var spread = spreadCrop(text: found, paper: paper)
        let fold = spread.crop.minX + spread.crop.width * spread.split
        let (left, right) = SpreadScanResult.halves(of: spread.crop, split: spread.split)

        var boxes: [CGRect] = []
        func number(on side: CGRect) async throws -> Int? {
            let text = found.filter { side.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
            var number = PageNumberFinder.find(in: text)
            if number == nil { number = try await PageNumberFinder.lookCloser(in: image, crop: side) }
            if let number { boxes.append(number.box) }
            return number?.value
        }
        spread.leftNumber = try await number(on: left)
        spread.rightNumber = try await number(on: right)
        // A page number at the very edge stays inside, and the split stays at the fold.
        for box in boxes {
            spread.crop = spread.crop.union(box.insetBy(dx: -0.01, dy: -0.01))
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        spread.split = (fold - spread.crop.minX) / max(spread.crop.width, 1e-9)
        return spread
    }

    /// Both pages' paper, and the fold between them: a shadowed valley in brightness near the middle of the
    /// paper, or failing that, the clearest gap in the writing there.
    static func spreadCrop(text: [FoundText], paper: PaperMap?) -> SpreadScanResult {
        let room = 0.02
        let profile = paper?.columnProfile()
        let span = profile?.paper ?? 0...1
        let width = span.upperBound - span.lowerBound, middle = span.lowerBound + width / 2
        var fold = middle
        if let shadow = paper?.spreadFold(within: span) {
            // Writing runs right up to the fold, so a nudge keeps the split out of words.
            fold = writingGap(text: text, within: (shadow - 0.015)...(shadow + 0.015), favoring: shadow) ?? shadow
        } else if let gap = writingGap(text: text, within: (middle - 0.2 * width)...(middle + 0.2 * width), favoring: middle) {
            fold = gap
        }
        let left = max(0, span.lowerBound - room), right = min(1, span.upperBound + room)
        var top = 0.0, bottom = 1.0
        // The pages may sit at different heights; keep all of both.
        let rows = [paper?.paperRows(from: left, to: fold), paper?.paperRows(from: fold, to: right)].compactMap { $0 }
        if !rows.isEmpty {
            top = max(0, (rows.map(\.lowerBound).min() ?? 0) - room)
            bottom = min(1, (rows.map(\.upperBound).max() ?? 1) + room)
        }
        // Vision can miss handwriting, but the writing it did find stays inside.
        if let writing = text.map(\.box).reduce(nil, { (total: CGRect?, box) in total?.union(box) ?? box }) {
            top = min(top, max(0, writing.minY - 0.01))
            bottom = max(bottom, min(1, writing.maxY + 0.01))
        }
        let crop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let split = min(max((fold - left) / crop.width, SpreadScanResult.splitLimits.lowerBound),
                        SpreadScanResult.splitLimits.upperBound)
        return SpreadScanResult(crop: crop, split: split)
    }

    /// Where a range across the photo is least covered by writing, nearest `middle` when it's a tie.
    static func writingGap(text: [FoundText], within range: ClosedRange<Double>, favoring middle: Double) -> Double? {
        guard !text.isEmpty else { return nil }
        let positions = (0...120).map { range.lowerBound + (range.upperBound - range.lowerBound) * Double($0) / 120 }
        func covered(_ x: Double) -> Double {
            text.reduce(0) { $0 + ($1.box.minX <= x && $1.box.maxX >= x ? $1.box.height : 0) }
        }
        return positions.min { a, b in
            let ca = covered(a), cb = covered(b)
            return ca != cb ? ca < cb : abs(a - middle) < abs(b - middle)
        }
    }

    /// The page's paper, cut at the fold when the facing page shows. The fold is a shadowed valley in
    /// brightness with paper on both sides; the side holding more writing is the page being added.
    static func suggestCrop(text: [FoundText], pageNumberBox: CGRect?, paper: PaperMap?) -> CGRect {
        guard let paper, let profile = paper.columnProfile() else {
            return textCrop(text: text, pageNumberBox: pageNumberBox, paper: paper)
        }
        // A little room past the paper's outer edges, where light falls off and page numbers sit.
        let room = 0.02
        var left = max(0, profile.paper.lowerBound - room), right = min(1, profile.paper.upperBound + room)
        if let fold = profile.fold {
            func writing(_ side: ClosedRange<Double>) -> Double {
                text.reduce(0) { total, item in
                    let width = max(0, min(item.box.maxX, side.upperBound) - max(item.box.minX, side.lowerBound))
                    return total + width * item.box.height
                }
            }
            // Writing can run right up to the fold, so the cut moves a little past it, short of the
            // facing page's text.
            let reach = 0.03
            if writing(left...fold) >= writing(fold...right) {
                let facing = text.filter { $0.box.minX > fold }.map(\.box.minX).min() ?? 1
                right = max(fold, min(fold + reach, facing - 0.005))
            } else {
                let facing = text.filter { $0.box.maxX < fold }.map(\.box.maxX).max() ?? 0
                left = min(fold, max(fold - reach, facing + 0.005))
            }
        } else {
            let fromText = textCrop(text: text, pageNumberBox: pageNumberBox, paper: nil)
            left = max(left, fromText.minX)
            right = min(right, fromText.maxX)
        }
        var top = 0.0, bottom = 1.0
        if let rows = paper.paperRows(from: left, to: right) {
            top = rows.lowerBound - room
            bottom = rows.upperBound + room
        }
        if let box = pageNumberBox, box.midX > left, box.midX < right {
            top = min(top, box.minY - 0.01)
            bottom = max(bottom, box.maxY + 0.01)
        }
        top = max(0, top)
        bottom = min(1, bottom)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Without a clear fold: the main column of writing, stopping short of any other column.
    static func textCrop(text: [FoundText], pageNumberBox: CGRect?, paper: PaperMap?) -> CGRect {
        let columns = Columns.group(text.map(\.box))
        guard let main = columns.max(by: { $0.weight < $1.weight }) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let margin = 0.04
        var left = max(0, main.span.minX - margin)
        var right = min(1, main.span.maxX + margin)
        for other in columns where other.span != main.span {
            if other.span.midX < main.span.minX { left = max(left, min(other.span.maxX + 0.01, main.span.minX)) }
            if other.span.midX > main.span.maxX { right = min(right, max(other.span.minX - 0.01, main.span.maxX)) }
        }

        // Up and down, keep the paper. Vision can miss lines of handwriting, so text alone isn't enough.
        var top = 0.0, bottom = 1.0
        if let rows = paper?.paperRows(from: left, to: right) {
            top = rows.lowerBound
            bottom = rows.upperBound
        }
        var keep = main.span
        if let pageNumberBox { keep = keep.union(pageNumberBox) }
        top = max(0, min(top, keep.minY - 0.02))
        bottom = min(1, max(bottom, keep.maxY + 0.02))
        left = min(left, keep.minX)
        right = max(right, keep.maxX)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// Groups line boxes into side-by-side columns.
struct Columns {
    var span: CGRect
    var weight: Double

    static func group(_ boxes: [CGRect]) -> [Columns] {
        var columns: [Columns] = []
        for box in boxes.sorted(by: { $0.width > $1.width }) {
            if let index = columns.firstIndex(where: { overlapX($0.span, box) >= 0.5 * min($0.span.width, box.width) }) {
                columns[index].span = columns[index].span.union(box)
                columns[index].weight += box.width * box.height
            } else {
                columns.append(Columns(span: box, weight: box.width * box.height))
            }
        }
        return columns
    }

    static func overlapX(_ a: CGRect, _ b: CGRect) -> Double {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    }
}

/// Finds a page number: a short number alone near the top or bottom of the page, printed or handwritten.
public enum PageNumberFinder {
    struct Found: Sendable {
        let value: Int
        let box: CGRect
    }

    static func find(in text: [FoundText]) -> Found? {
        guard !text.isEmpty else { return nil }
        let top = text.map(\.box.minY).min() ?? 0
        let bottom = text.map(\.box.maxY).max() ?? 1
        let candidates = text.compactMap { item -> (Found, Double)? in
            guard let value = number(in: item.text), (1...9999).contains(value) else { return nil }
            // How close it sits to the top or bottom of the writing, and to the page's edge.
            let fromEdge = min(item.box.minY - top, bottom - item.box.maxY)
            let nearEdge = item.box.midY < 0.2 || item.box.midY > 0.8
            guard fromEdge < 0.04 || nearEdge else { return nil }
            return (Found(value: value, box: item.box), min(fromEdge, min(item.box.midY, 1 - item.box.midY)))
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    /// Printed page numbers are small, so the page's top and bottom are read again up close.
    static func lookCloser(in image: CGImage, crop: CGRect) async throws -> Found? {
        let bands = [CGRect(x: crop.minX, y: crop.maxY - crop.height * 0.16, width: crop.width, height: crop.height * 0.16),
                     CGRect(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height * 0.12)]
        for band in bands {
            let pixels = CGRect(x: band.minX * Double(image.width), y: band.minY * Double(image.height),
                                width: band.width * Double(image.width), height: band.height * Double(image.height)).integral
            guard let cut = image.cropping(to: pixels) else { continue }
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            for observation in try await request.perform(on: cut) {
                guard let text = observation.topCandidates(1).first?.string, let value = number(in: text),
                      (1...9999).contains(value)
                else { continue }
                let local = PageLayoutFinder.topLeft(observation.boundingBox.cgRect)
                let box = CGRect(x: band.minX + local.minX * band.width, y: band.minY + local.minY * band.height,
                                 width: local.width * band.width, height: local.height * band.height)
                return Found(value: value, box: box)
            }
        }
        return nil
    }

    /// "58", "- 58 -", "p. 58", or "Page 58", but not a date or a sentence.
    public static func number(in text: String) -> Int? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["page", "pg.", "pg", "p."] where trimmed.lowercased().hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
        }
        let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " -–—.·•()[]|"))
        guard (1...4).contains(core.count), core.allSatisfy(\.isNumber) else { return nil }
        return Int(core)
    }
}

/// Brightness of the photo, used to tell paper from a darker background.
struct PaperMap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(image: CGImage, maxDimension: Int = 600) {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        pixels = buffer
    }

    struct ColumnProfile {
        /// Where the paper is, left to right.
        let paper: ClosedRange<Double>
        /// The fold between two pages, if one shows.
        let fold: Double?
    }

    /// The mean brightness of each column across the photo's middle rows, lightly smoothed.
    private func smoothedColumns() -> [Double]? {
        let rows = (height / 5)..<(height * 4 / 5)
        guard width > 20, !rows.isEmpty else { return nil }
        let raw = (0..<width).map { x -> Double in
            Double(rows.reduce(0) { $0 + Int(pixels[$1 * width + x]) }) / Double(rows.count)
        }
        let radius = max(1, width / 150)
        let smooth = raw.indices.map { x -> Double in
            let window = raw[max(0, x - radius)...min(width - 1, x + radius)]
            return window.reduce(0, +) / Double(window.count)
        }
        return smooth
    }

    /// Brightness across the photo's middle rows, used to find the paper's edges and the fold.
    func columnProfile() -> ColumnProfile? {
        guard let smooth = smoothedColumns() else { return nil }
        let sorted = smooth.sorted()
        let dark = sorted[sorted.count / 20], light = sorted[sorted.count * 19 / 20]
        var paper = 0.0...1.0
        if light - dark > 40 {
            let threshold = (dark + light) / 2
            if let first = smooth.firstIndex(where: { $0 > threshold }),
               let last = smooth.lastIndex(where: { $0 > threshold }), last > first {
                paper = Double(first) / Double(width)...Double(last + 1) / Double(width)
            }
        }

        // A fold sits near one side, with paper on both sides of it.
        let reach = max(3, width * 8 / 100)
        var best: (x: Int, depth: Double)?
        for x in reach..<(width - reach) {
            let position = Double(x) / Double(width)
            guard paper.contains(position), position < 0.42 || position > 0.58 else { continue }
            guard smooth[x] <= smooth[x - 1], smooth[x] <= smooth[x + 1] else { continue }
            let leftPeak = smooth[(x - reach)..<x].max() ?? 0
            let rightPeak = smooth[(x + 1)...(x + reach)].max() ?? 0
            let depth = min(leftPeak, rightPeak) - smooth[x]
            if depth > (best?.depth ?? 12) { best = (x, depth) }
        }
        return ColumnProfile(paper: paper, fold: best.map { Double($0.x) / Double(width) })
    }

    /// The fold of an open journal photographed with both pages: the deepest shadowed valley in the middle
    /// two-fifths of the paper, with paper on both sides, favoring the middle. Nil when there's no clear one.
    func spreadFold(within paper: ClosedRange<Double>) -> Double? {
        guard let smooth = smoothedColumns() else { return nil }
        let span = paper.upperBound - paper.lowerBound
        let middle = paper.lowerBound + span / 2
        let reach = max(3, width * 8 / 100)
        var best: (x: Int, score: Double)?
        for x in reach..<(width - reach) {
            let position = Double(x) / Double(width)
            let offCenter = abs(position - middle) / span
            guard offCenter <= 0.2 else { continue }
            guard smooth[x] <= smooth[x - 1], smooth[x] <= smooth[x + 1] else { continue }
            let leftPeak = smooth[(x - reach)..<x].max() ?? 0
            let rightPeak = smooth[(x + 1)...(x + reach)].max() ?? 0
            let depth = min(leftPeak, rightPeak) - smooth[x]
            guard depth > 12 else { continue }
            // A valley off to one side has to be deeper to win.
            let score = depth * (1 - 2 * offCenter)
            if score > (best?.score ?? 0) { best = (x, score) }
        }
        guard let valley = best?.x else { return nil }
        return Double(foldInside(valley: valley, smooth: smooth, reach: reach)) / Double(width)
    }

    /// Where in a valley the fold is. Lit evenly, the fold is the darkest column. Lit from one side, one page
    /// stays bright right up to the fold and drops sharply into the other page's shadow, which brightens only
    /// slowly away from the fold; the darkest column is then well inside the shaded page, and the fold is at
    /// the foot of the sharp drop.
    private func foldInside(valley: Int, smooth: [Double], reach: Int) -> Int {
        let floor = smooth[valley]
        /// How many columns it takes, going one way, to climb from the floor to most of the way to that
        /// side's brightest, and where the climb starts.
        func climb(_ step: Int) -> (foot: Int, length: Int)? {
            let end = valley + step * reach
            guard end > 0, end < smooth.count - 1 else { return nil }
            let peak = stride(from: valley, through: end, by: step).map { smooth[$0] }.max() ?? floor
            guard peak - floor > 12 else { return nil }
            var foot = valley
            while foot != end, smooth[foot + step] < floor + 0.2 * (peak - floor) { foot += step }
            var top = foot
            while top != end, smooth[top] < floor + 0.8 * (peak - floor) { top += step }
            return (foot, max(1, abs(top - foot)))
        }
        guard let left = climb(-1), let right = climb(1) else { return valley }
        if left.length * 3 <= right.length { return left.foot }
        if right.length * 3 <= left.length { return right.foot }
        return valley
    }

    /// The first and last rows, top-left normalized, that are mostly paper between two columns.
    /// Nil when paper and background are too alike to tell apart.
    func paperRows(from left: Double, to right: Double) -> ClosedRange<Double>? {
        let x0 = max(0, Int(left * Double(width))), x1 = min(width, Int(right * Double(width)))
        guard x1 > x0 else { return nil }
        let means = (0..<height).map { y -> Double in
            let row = pixels[(y * width + x0)..<(y * width + x1)]
            return Double(row.reduce(0) { $0 + Int($1) }) / Double(row.count)
        }
        let sorted = means.sorted()
        let dark = sorted[sorted.count / 10], light = sorted[sorted.count * 9 / 10]
        guard light - dark > 40 else { return nil }
        let threshold = (dark + light) / 2
        guard let first = means.firstIndex(where: { $0 > threshold }),
              let last = means.lastIndex(where: { $0 > threshold })
        else { return nil }
        return Double(first) / Double(height)...Double(last + 1) / Double(height)
    }
}

extension PagePhoto {
    /// Turns a photo clockwise by `degrees`. Quarter turns are exact; other angles widen the canvas to keep
    /// every corner, filling the new space with the photo's own edge color.
    public static func rotated(_ image: CGImage, degrees: Double) -> CGImage? {
        let turns = degrees / 90
        let quarter = abs(turns - turns.rounded()) < 1e-9
        let radians = -degrees * .pi / 180
        let width = Double(image.width), height = Double(image.height)
        let newWidth = Int((abs(width * cos(radians)) + abs(height * sin(radians))).rounded())
        let newHeight = Int((abs(width * sin(radians)) + abs(height * cos(radians))).rounded())
        guard newWidth > 0, newHeight > 0,
              let context = CGContext(data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        if !quarter {
            context.setFillColor(Straightener.edgeColor(image))
            context.fill(CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        }
        context.interpolationQuality = .high
        context.translateBy(x: Double(newWidth) / 2, y: Double(newHeight) / 2)
        context.rotate(by: radians)
        context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        return context.makeImage()
    }

    /// A smaller copy of an image.
    static func scaled(_ image: CGImage, by scale: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A prepared photo turned clockwise by `degrees`, as a JPEG.
    public static func rotated(_ jpeg: Data, degrees: Double) throws -> Data {
        guard abs(degrees.truncatingRemainder(dividingBy: 360)) > 0.01 else { return jpeg }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let turned = rotated(image, degrees: degrees)
        else { throw PagePhotoError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PagePhotoError.unreadable }
        CGImageDestinationAddImage(destination, turned, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PagePhotoError.unreadable }
        return output as Data
    }

    /// A normalized crop carried through a quarter turn clockwise (`quarters` = 1) or counterclockwise (-1).
    public static func rotatedCrop(_ crop: CGRect, quarters: Int) -> CGRect {
        var rect = crop
        for _ in 0..<((quarters % 4 + 4) % 4) {
            rect = CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        }
        return rect
    }

    /// Cuts a prepared photo down to a normalized, top-left rectangle.
    public static func crop(_ jpeg: Data, to rect: CGRect) throws -> Data {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rect = rect.intersection(unit)
        guard !rect.isNull, rect.width > 0.05, rect.height > 0.05 else { throw PagePhotoError.unreadable }
        if rect.width > 0.995 && rect.height > 0.995 { return jpeg }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw PagePhotoError.unreadable }
        let pixels = CGRect(x: rect.minX * Double(image.width), y: rect.minY * Double(image.height),
                            width: rect.width * Double(image.width), height: rect.height * Double(image.height)).integral
        guard let cut = image.cropping(to: pixels) else { throw PagePhotoError.unreadable }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PagePhotoError.unreadable }
        CGImageDestinationAddImage(destination, cut, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PagePhotoError.unreadable }
        return output as Data
    }
}

/// A crop frame turned over a still photo by the Straighten slider. The crop is stored as an upright
/// rectangle, normalized to the photo, whose center and size the frame keeps; the frame is drawn turned
/// counterclockwise by the straightening angle, so that turning the photo clockwise by that angle makes it
/// upright again. Only when the page is saved or shown as a result is the photo turned and cut, once.
public enum TiltedCrop {
    /// The frame's corners, normalized to the photo, starting at its top left and going clockwise.
    /// `aspect` is the photo's width over its height; `degrees` is the clockwise turn that levels the page.
    public static func corners(_ crop: CGRect, degrees: Double, aspect: Double) -> [CGPoint] {
        let (cosine, sine) = turn(-degrees)
        let center = CGPoint(x: crop.midX * aspect, y: crop.midY)
        let halfWidth = crop.width * aspect / 2, halfHeight = crop.height / 2
        return [(-halfWidth, -halfHeight), (halfWidth, -halfHeight), (halfWidth, halfHeight), (-halfWidth, halfHeight)]
            .map { x, y in
                CGPoint(x: (center.x + x * cosine - y * sine) / aspect, y: center.y + x * sine + y * cosine)
            }
    }

    /// Whether the frame lies inside the photo at its angle.
    public static func fits(_ crop: CGRect, degrees: Double, aspect: Double) -> Bool {
        corners(crop, degrees: degrees, aspect: aspect).allSatisfy {
            $0.x >= -1e-6 && $0.x <= 1 + 1e-6 && $0.y >= -1e-6 && $0.y <= 1 + 1e-6
        }
    }

    /// The crop shrunk about its center, then moved, just enough that the turned frame stays inside the photo.
    public static func fitted(_ crop: CGRect, degrees: Double, aspect: Double) -> CGRect {
        guard abs(degrees) > 1e-9, aspect > 0 else { return crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let (cosine, sine) = turn(degrees)
        var halfWidth = crop.width * aspect / 2, halfHeight = crop.height / 2
        var extentX = halfWidth * abs(cosine) + halfHeight * abs(sine)
        var extentY = halfWidth * abs(sine) + halfHeight * abs(cosine)
        let shrink = min(1, aspect / (2 * extentX), 1 / (2 * extentY))
        halfWidth *= shrink; halfHeight *= shrink; extentX *= shrink; extentY *= shrink
        let centerX = min(max(crop.midX * aspect, extentX), aspect - extentX)
        let centerY = min(max(crop.midY, extentY), 1 - extentY)
        return CGRect(x: (centerX - halfWidth) / aspect, y: centerY - halfHeight,
                      width: 2 * halfWidth / aspect, height: 2 * halfHeight)
    }

    /// Which sides of the frame a drag moves.
    public struct Edges: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Edges(rawValue: 1), right = Edges(rawValue: 2)
        public static let top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    /// The frame with `edges` moved along its own sides by a drag of (`dx`, `dy`) on the photo, in units of the
    /// photo's height, with the frame turned by `degrees`. The other sides stay put, and the frame keeps at
    /// least a tenth of the photo in each direction. It may reach past the photo; see `fits`.
    public static func resized(_ start: CGRect, edges: Edges, dx: Double, dy: Double, degrees: Double,
                               aspect: Double) -> CGRect {
        // The drag in the frame's own directions: the frame is turned counterclockwise by `degrees`.
        let radians = degrees * .pi / 180
        let along = dx * cos(radians) - dy * sin(radians)
        let across = dx * sin(radians) + dy * cos(radians)
        var left = -start.width * aspect / 2, right = start.width * aspect / 2
        var top = -start.height / 2, bottom = start.height / 2
        let smallestWidth = 0.1 * aspect, smallestHeight = 0.1
        if edges.contains(.left) { left = min(left + along, right - smallestWidth) }
        if edges.contains(.right) { right = max(right + along, left + smallestWidth) }
        if edges.contains(.top) { top = min(top + across, bottom - smallestHeight) }
        if edges.contains(.bottom) { bottom = max(bottom + across, top + smallestHeight) }
        // The frame's new middle, turned back onto the photo.
        let shiftX = (left + right) / 2, shiftY = (top + bottom) / 2
        let centerX = start.midX * aspect + shiftX * cos(radians) + shiftY * sin(radians)
        let centerY = start.midY - shiftX * sin(radians) + shiftY * cos(radians)
        let width = right - left, height = bottom - top
        return CGRect(x: (centerX - width / 2) / aspect, y: centerY - height / 2, width: width / aspect, height: height)
    }

    /// Resizes the frame as far as the drag goes. When the turned frame would reach past the photo, the turn is
    /// eased toward level, only as much as it takes to make room (a level frame has the most). A drag past the
    /// photo itself stops at its edge, level there. Returns the frame and the turn it fits at.
    public static func resizedMakingRoom(_ start: CGRect, edges: Edges, dx: Double, dy: Double, degrees: Double,
                                         aspect: Double) -> (crop: CGRect, degrees: Double) {
        func frame(_ fraction: Double, _ angle: Double) -> CGRect {
            resized(start, edges: edges, dx: dx * fraction, dy: dy * fraction, degrees: angle, aspect: aspect)
        }
        let whole = frame(1, degrees)
        if fits(whole, degrees: degrees, aspect: aspect) { return (whole, degrees) }
        // How much of the drag fits at all: all of it if it fits level, or else up to the photo's edge.
        var reach = 1.0
        if !fits(frame(1, 0), degrees: 0, aspect: aspect) {
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let middle = (low + high) / 2
                if fits(frame(middle, 0), degrees: 0, aspect: aspect) { low = middle } else { high = middle }
            }
            reach = low
        }
        guard reach > 0, fits(frame(reach, 0), degrees: 0, aspect: aspect) else {
            // Not even level makes room (a long, thin frame): go as far as fits at this turn.
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let middle = (low + high) / 2
                if fits(frame(middle, degrees), degrees: degrees, aspect: aspect) { low = middle } else { high = middle }
            }
            let kept = frame(low, degrees)
            return (fits(kept, degrees: degrees, aspect: aspect) ? kept : start, degrees)
        }
        // The turn nearest the one asked for at which that much of the drag fits.
        // Fractions of the turn kept: none (level) fits, all of it doesn't.
        var fitting = 0.0, tooMuch = 1.0
        for _ in 0..<24 {
            let middle = (fitting + tooMuch) / 2
            if fits(frame(reach, degrees * middle), degrees: degrees * middle, aspect: aspect) { fitting = middle }
            else { tooMuch = middle }
        }
        // To a tenth of a degree, rounded toward level, when that still fits.
        let rounded = (degrees * fitting * 10).rounded(.towardZero) / 10
        let angle = fits(frame(reach, rounded), degrees: rounded, aspect: aspect) ? rounded : degrees * fitting
        return (frame(reach, angle), angle)
    }

    /// The reverse of `canvasCrop`: an upright crop of the photo turned clockwise by `degrees`, as a frame
    /// over the still photo.
    public static func photoCrop(_ canvas: CGRect, degrees: Double, aspect: Double) -> CGRect {
        guard abs(degrees) > 1e-9 else { return canvas }
        let (cosine, sine) = turn(degrees)
        let width = aspect, height = 1.0
        let canvasWidth = width * abs(cosine) + height * abs(sine)
        let canvasHeight = width * abs(sine) + height * abs(cosine)
        let x = canvas.midX * canvasWidth - canvasWidth / 2, y = canvas.midY * canvasHeight - canvasHeight / 2
        let centerX = width / 2 + x * cosine + y * sine
        let centerY = height / 2 - x * sine + y * cosine
        let frameWidth = canvas.width * canvasWidth, frameHeight = canvas.height * canvasHeight
        return CGRect(x: (centerX - frameWidth / 2) / width, y: (centerY - frameHeight / 2) / height,
                      width: frameWidth / width, height: frameHeight / height)
    }

    /// The same frame as an upright crop of the photo after `PagePhoto.rotated(_:degrees:)` has turned it
    /// clockwise by `degrees`, for `PageFlattener.process`.
    public static func canvasCrop(_ crop: CGRect, degrees: Double, aspect: Double) -> CGRect {
        guard abs(degrees) > 1e-9 else { return crop }
        let (cosine, sine) = turn(degrees)
        let width = aspect, height = 1.0
        let canvasWidth = width * abs(cosine) + height * abs(sine)
        let canvasHeight = width * abs(sine) + height * abs(cosine)
        let x = crop.midX * width - width / 2, y = crop.midY * height - height / 2
        let centerX = canvasWidth / 2 + x * cosine - y * sine
        let centerY = canvasHeight / 2 + x * sine + y * cosine
        let frameWidth = crop.width * width, frameHeight = crop.height * height
        return CGRect(x: (centerX - frameWidth / 2) / canvasWidth, y: (centerY - frameHeight / 2) / canvasHeight,
                      width: frameWidth / canvasWidth, height: frameHeight / canvasHeight)
    }

    /// Cosine and sine of a clockwise turn on a picture whose y axis points down.
    private static func turn(_ degrees: Double) -> (Double, Double) {
        let radians = degrees * .pi / 180
        return (cos(radians), sin(radians))
    }
}
