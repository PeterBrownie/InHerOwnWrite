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

    /// Brightness across the photo's middle rows, used to find the paper's edges and the fold.
    func columnProfile() -> ColumnProfile? {
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
