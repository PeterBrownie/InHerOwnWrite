import CoreGraphics
import Foundation

/// Colors the handwriting itself: the ink of chosen words, recolored in an overlay laid over the page photo.
/// Within each word's outline, a pixel counts as ink when it is much nearer the word's darkest strokes than
/// the paper around them, so faint marks, like show-through or ink from the facing page, stay out of the tint.
public enum InkTint {
    public struct Region: Sendable, Equatable {
        /// Corners of the word on the photo, normalized with the origin at the top left.
        public var outline: [CGPoint]
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(outline: [CGPoint], red: Double, green: Double, blue: Double) {
            self.outline = outline
            self.red = red
            self.green = green
            self.blue = blue
        }

        public init(box: CGRect, red: Double, green: Double, blue: Double) {
            self.init(outline: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)],
                      red: red, green: green, blue: blue)
        }
    }

    /// Colors for words the model changed and words it wasn't sure of, picked to stand apart from black and
    /// blue ink on paper.
    public static let changed = (red: 0.85, green: 0.20, blue: 0.16)
    public static let closeCall = (red: 0.10, green: 0.66, blue: 0.32)

    /// A clear image with the photo's shape, at most `maxDimension` on its longer side, holding only the
    /// recolored ink of each region. Nil when there is nothing to color.
    public static func overlay(for image: CGImage, regions: [Region], maxDimension: Int = 1600) -> CGImage? {
        guard !regions.isEmpty else { return nil }
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var gray = [UInt8](repeating: 255, count: width * height)
        let drawn = gray.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var colored = 0
        for region in regions where region.outline.count >= 3 {
            let corners = region.outline.map { CGPoint(x: $0.x * Double(width), y: $0.y * Double(height)) }
            let x0 = max(0, Int(corners.map(\.x).min()!.rounded(.down)))
            let x1 = min(width - 1, Int(corners.map(\.x).max()!.rounded(.up)))
            let y0 = max(0, Int(corners.map(\.y).min()!.rounded(.down)))
            let y1 = min(height - 1, Int(corners.map(\.y).max()!.rounded(.up)))
            guard x1 > x0, y1 > y0 else { continue }
            var inside: [Int] = []
            for y in y0...y1 {
                for x in x0...x1 where contains(corners, CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                    inside.append(y * width + x)
                }
            }
            guard inside.count >= 16 else { continue }
            let values = inside.map { gray[$0] }.sorted()
            // Most of a word's box is paper; its darkest few pixels are the pen.
            let paper = Double(values[values.count * 3 / 4])
            let ink = Double(values[values.count / 50])
            guard paper - ink >= 40 else { continue }
            let threshold = ink + (paper - ink) * 0.55
            for index in inside {
                let value = Double(gray[index])
                guard value < threshold else { continue }
                // Stronger strokes get more color; the soft edges of a stroke stay soft.
                let alpha = min(1, (paper - value) / (paper - ink) * 1.25)
                let offset = index * 4
                // Premultiplied, as the bitmap stores it.
                pixels[offset] = UInt8((region.red * alpha * 255).rounded())
                pixels[offset + 1] = UInt8((region.green * alpha * 255).rounded())
                pixels[offset + 2] = UInt8((region.blue * alpha * 255).rounded())
                pixels[offset + 3] = UInt8((alpha * 255).rounded())
                colored += 1
            }
        }
        guard colored > 0 else { return nil }
        // Rows were filled top first, which is how a bitmap's memory is laid out.
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Whether a point is inside a convex outline, whichever way round its corners go.
    static func contains(_ corners: [CGPoint], _ point: CGPoint) -> Bool {
        var sign = 0.0
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if cross != 0 {
                if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
            }
        }
        return true
    }
}
