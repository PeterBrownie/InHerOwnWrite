import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Straightens lines of writing that curve or slope, as on a page bending into a book's fold or photographed
/// at an angle. The page is measured in vertical bands: lines of writing repeat at a steady pitch, so
/// comparing each band's rows of ink with its neighbor's shows how far the lines drift up or down across the
/// page. Each column of the photo is then shifted to put every line back on the level.
public enum PageFlattener {
    /// A grid of vertical drift, in pixels of the analyzed image, at the center of each cell.
    struct Drift {
        let columns: Int
        let rows: Int
        let values: [Double]
        /// The analyzed image's size, for scaling to the full photo.
        let width: Int
        let height: Int

        func value(column: Int, row: Int) -> Double { values[row * columns + column] }

        /// Drift at any point of the analyzed image, blending the four nearest cell centers.
        func at(x: Double, y: Double) -> Double {
            let cx = min(max(x / Double(width) * Double(columns) - 0.5, 0), Double(columns - 1))
            let cy = min(max(y / Double(height) * Double(rows) - 0.5, 0), Double(rows - 1))
            let x0 = Int(cx), y0 = Int(cy)
            let x1 = min(x0 + 1, columns - 1), y1 = min(y0 + 1, rows - 1)
            let fx = cx - Double(x0), fy = cy - Double(y0)
            let top = value(column: x0, row: y0) * (1 - fx) + value(column: x1, row: y0) * fx
            let bottom = value(column: x0, row: y1) * (1 - fx) + value(column: x1, row: y1) * fx
            return top * (1 - fy) + bottom * fy
        }

        var largest: Double { values.map(abs).max() ?? 0 }
    }

    /// Crops a prepared photo and, if asked, flattens it. Returns a JPEG.
    public static func process(_ jpeg: Data, crop: CGRect, flatten: Bool) throws -> Data {
        let cropped = try PagePhoto.crop(jpeg, to: crop)
        guard flatten,
              let source = CGImageSourceCreateWithData(cropped as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let flat = self.flatten(image)
        else { return cropped }
        return try encode(flat)
    }

    /// The flattened page, or nil when the lines are already straight or can't be measured with confidence.
    public static func flatten(_ image: CGImage) -> CGImage? {
        guard let drift = measure(image), drift.largest > 2 else { return nil }
        return apply(drift, to: image)
    }

    /// How far, in pixels of the photo, lines drift up or down across the page at most. For checks.
    public static func largestDrift(in image: CGImage) -> Double? {
        guard let drift = measure(image) else { return nil }
        return drift.largest * Double(image.height) / Double(drift.height)
    }

    /// Bends a flat page the way a page curls into a fold on its right side, by up to `depth` pixels. For checks.
    public static func curled(_ image: CGImage, depth: Double) -> CGImage? {
        let columns = 14
        let values = (0..<(columns * 3)).map { index -> Double in
            let x = (Double(index % columns) + 0.5) / Double(columns)
            return -depth * pow(max(0, x - 0.4) / 0.6, 2)
        }
        let drift = Drift(columns: columns, rows: 3, values: values, width: image.width, height: image.height)
        return apply(drift, to: image)
    }

    // MARK: Measuring

    static func measure(_ image: CGImage) -> Drift? {
        guard let ink = InkMap(image: image, maxDimension: 1200),
              let pitchFraction = ink.linePitch()
        else { return nil }
        let width = ink.width, height = ink.height
        let pitch = pitchFraction * Double(height)
        guard pitch >= 6 else { return nil }
        let threshold = ink.middleThreshold()
        let columns = 14
        // Each row of cells is a few lines tall, so its profile has several peaks to match.
        let rows = max(1, min(5, Int(Double(height) / (pitch * 5))))
        let bandWidth = width / columns
        let cellHeight = height / rows
        let reach = max(1, Int(pitch * 0.45))

        var values = [Double](repeating: 0, count: columns * rows)
        var measured = 0
        for row in 0..<rows {
            let y0 = row * cellHeight, y1 = row == rows - 1 ? height : y0 + cellHeight
            let profiles = (0..<columns).map { column -> [Double] in
                let x0 = column * bandWidth, x1 = column == columns - 1 ? width : x0 + bandWidth
                return ink.rowInk(x: x0..<x1, y: y0..<y1, threshold: threshold)
            }
            let inkSums = profiles.map { $0.reduce(0, +) }
            let enough = (inkSums.max() ?? 0) * 0.15
            // Start from the band with the most writing and work outward in both directions.
            guard let anchor = inkSums.indices.max(by: { inkSums[$0] < inkSums[$1] }), inkSums[anchor] > 0 else { continue }
            var offsets = [Double?](repeating: nil, count: columns)
            offsets[anchor] = 0
            for direction in [1, -1] {
                var last = anchor
                var column = anchor + direction
                while column >= 0 && column < columns {
                    if inkSums[column] >= enough, let previous = offsets[last] {
                        let shift = bestShift(from: profiles[last], to: profiles[column], reach: reach)
                        // Hops over blank bands can drift further.
                        let allowed = Double(reach * abs(column - last))
                        if abs(shift) <= allowed {
                            offsets[column] = previous + shift
                            last = column
                        }
                    }
                    column += direction
                }
            }
            let known = offsets.indices.compactMap { column in offsets[column].map { (column, $0, inkSums[column]) } }
            guard known.count >= columns / 2 else { continue }
            measured += 1
            // A page curls smoothly, so a gentle curve through the measurements replaces them, after
            // dropping any far off it, such as a band catching the page's edge.
            var points = known
            var curve = fitCurve(points)
            for _ in 0..<2 {
                let kept = points.filter { abs(evaluate(curve, at: $0.0) - $0.1) < pitch * 0.25 }
                guard kept.count >= 4, kept.count < points.count else { break }
                points = kept
                curve = fitCurve(points)
            }
            // The page's middle stays put; everything else moves to meet it.
            let center = evaluate(curve, at: columns / 2)
            for column in 0..<columns { values[row * columns + column] = evaluate(curve, at: column) - center }
        }
        guard measured > 0 else { return nil }
        // Rows of cells that couldn't be measured borrow from the nearest one that could.
        fillMissingRows(&values, columns: columns, rows: rows)
        return Drift(columns: columns, rows: rows, values: smoothed(values, columns: columns, rows: rows),
                     width: width, height: height)
    }

    /// The shift, in rows, that best lines up `next` with `previous`, with sub-row precision.
    static func bestShift(from previous: [Double], to next: [Double], reach: Int) -> Double {
        func centered(_ values: [Double]) -> [Double] {
            let mean = values.reduce(0, +) / Double(max(values.count, 1))
            return values.map { $0 - mean }
        }
        let previous = centered(previous), next = centered(next)
        func score(_ shift: Int) -> Double {
            var sum = 0.0
            for y in max(0, -shift)..<min(previous.count, next.count - shift) {
                sum += previous[y] * next[y + shift]
            }
            return sum
        }
        let scores = (-reach...reach).map(score)
        guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return 0 }
        var shift = Double(bestIndex - reach)
        // A parabola through the peak and its neighbors refines it between rows.
        if bestIndex > 0 && bestIndex < scores.count - 1 {
            let a = scores[bestIndex - 1], b = scores[bestIndex], c = scores[bestIndex + 1]
            let curve = a - 2 * b + c
            if curve < 0 { shift += 0.5 * (a - c) / curve }
        }
        return shift
    }

    /// Weighted least squares through (column, offset, weight) points: a cubic when there are enough
    /// points, otherwise a straight line.
    static func fitCurve(_ points: [(Int, Double, Double)]) -> [Double] {
        let degree = points.count >= 6 ? 3 : 1
        let size = degree + 1
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: size + 1), count: size)
        for (column, offset, weight) in points {
            let x = Double(column) / 10
            let w = max(weight, 1e-6)
            let powers = (0..<(2 * size)).map { pow(x, Double($0)) }
            for i in 0..<size {
                for j in 0..<size { matrix[i][j] += w * powers[i + j] }
                matrix[i][size] += w * powers[i] * offset
            }
        }
        // Gaussian elimination with partial pivoting.
        for column in 0..<size {
            guard let pivot = (column..<size).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) }),
                  abs(matrix[pivot][column]) > 1e-12
            else { return [points.map(\.1).reduce(0, +) / Double(max(points.count, 1))] }
            matrix.swapAt(column, pivot)
            for row in 0..<size where row != column {
                let factor = matrix[row][column] / matrix[column][column]
                for k in column...size { matrix[row][k] -= factor * matrix[column][k] }
            }
        }
        return (0..<size).map { matrix[$0][size] / matrix[$0][$0] }
    }

    static func evaluate(_ curve: [Double], at column: Int) -> Double {
        let x = Double(column) / 10
        return curve.enumerated().reduce(0) { $0 + $1.element * pow(x, Double($1.offset)) }
    }

    private static func fillMissingRows(_ values: inout [Double], columns: Int, rows: Int) {
        let measured = (0..<rows).filter { row in (0..<columns).contains { values[row * columns + $0] != 0 } }
        guard !measured.isEmpty else { return }
        for row in 0..<rows where !measured.contains(row) {
            let nearest = measured.min { abs($0 - row) < abs($1 - row) }!
            for column in 0..<columns { values[row * columns + column] = values[nearest * columns + column] }
        }
    }

    /// Evens out single-cell jumps so one misread band can't kink a line.
    private static func smoothed(_ values: [Double], columns: Int, rows: Int) -> [Double] {
        var result = values
        for row in 0..<rows {
            for column in 0..<columns {
                let neighbors = [column - 1, column, column + 1].filter { (0..<columns).contains($0) }
                    .map { values[row * columns + $0] }.sorted()
                result[row * columns + column] = neighbors[neighbors.count / 2]
            }
        }
        return result
    }

    // MARK: Applying

    /// Moves each pixel up or down by the drift at its place, blending between rows.
    static func apply(_ drift: Drift, to image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        var source = [UInt8](repeating: 0, count: bytesPerRow * height)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        let drawn = source.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space, bitmapInfo: info)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        // Drift is measured on a smaller copy; work it out on a coarse grid of the full photo and blend.
        let scaleX = Double(drift.width) / Double(width), scaleY = Double(drift.height) / Double(height)
        let step = 16
        let gridColumns = width / step + 2, gridRows = height / step + 2
        var grid = [Double](repeating: 0, count: gridColumns * gridRows)
        for gy in 0..<gridRows {
            for gx in 0..<gridColumns {
                grid[gy * gridColumns + gx] = drift.at(x: Double(gx * step) * scaleX, y: Double(gy * step) * scaleY) / scaleY
            }
        }

        var output = [UInt8](repeating: 0, count: bytesPerRow * height)
        source.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let gy = y / step, fy = Double(y % step) / Double(step)
                    for x in 0..<width {
                        let gx = x / step, fx = Double(x % step) / Double(step)
                        let top = grid[gy * gridColumns + gx] * (1 - fx) + grid[gy * gridColumns + gx + 1] * fx
                        let bottom = grid[(gy + 1) * gridColumns + gx] * (1 - fx) + grid[(gy + 1) * gridColumns + gx + 1] * fx
                        let sourceY = min(max(Double(y) + top * (1 - fy) + bottom * fy, 0), Double(height - 1))
                        let y0 = Int(sourceY), y1 = min(y0 + 1, height - 1)
                        let t = sourceY - Double(y0)
                        let a = y0 * bytesPerRow + x * 4, b = y1 * bytesPerRow + x * 4, o = y * bytesPerRow + x * 4
                        for channel in 0..<3 {
                            out[o + channel] = UInt8(Double(input[a + channel]) * (1 - t) + Double(input[b + channel]) * t)
                        }
                        out[o + 3] = 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    static func encode(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PagePhotoError.unreadable }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PagePhotoError.unreadable }
        return output as Data
    }
}

extension InkMap {
    /// The ink threshold from the middle of the page, where there's no background to skew it.
    func middleThreshold() -> UInt8 {
        let x0 = width / 4, x1 = width - width / 4, y0 = height / 10, y1 = height - height / 10
        guard x1 > x0, y1 > y0 else { return threshold }
        var middle: [UInt8] = []
        middle.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { middle += pixels[(y * width + x0)..<(y * width + x1)] }
        return Self.otsu(middle)
    }

    /// Ink per row within a block, lightly smoothed.
    func rowInk(x: Range<Int>, y: Range<Int>, threshold: UInt8) -> [Double] {
        var rows = [Double](repeating: 0, count: y.count)
        for row in y {
            let start = row * width
            var count = 0
            for column in x where pixels[start + column] < threshold { count += 1 }
            // A row that is mostly dark is the table or a shadow past the paper, not writing.
            rows[row - y.lowerBound] = count > x.count * 6 / 10 ? 0 : Double(count)
        }
        return rows.indices.map { index in
            let window = rows[max(0, index - 1)...min(rows.count - 1, index + 1)]
            return window.reduce(0, +) / Double(window.count)
        }
    }
}
