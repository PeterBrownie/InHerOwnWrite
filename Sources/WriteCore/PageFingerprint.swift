import CryptoKit
import Foundation
import ImageIO
import Vision

/// What Vision reads on a saved page, for noticing the same page photographed twice.
///
/// Handwriting is often misread, but two photos of the same page are misread in much the same way, while
/// different pages share few pairs of words in a row. On real photos (November 25, 2026), the same pages in
/// different light and crops scored 0.47 to 0.80, and different pages 0.06 or less. A map of where the ink
/// sits was tried first and couldn't tell them apart reliably (as low as 0.32 against up to 0.42); see
/// docs/EXPERIMENTS.md.
public struct PageFingerprint: Codable, Hashable, Sendable {
    /// Scores at or above this mean the same page.
    public static let samePage = 0.25

    public let words: [String]

    public init(words: [String]) {
        self.words = words
    }

    /// The fingerprint of a page image (HEIC or JPEG); nil when Vision finds too little writing to compare.
    public static func make(image data: Data) async -> PageFingerprint? {
        let found = await words(image: data)
        return found.count >= 10 ? PageFingerprint(words: found) : nil
    }

    public func similarity(to other: PageFingerprint) -> Double {
        Self.wordSimilarity(words, other.words)
    }

    public func isSamePage(as other: PageFingerprint) -> Bool {
        similarity(to: other) >= Self.samePage
    }

    /// The words Vision reads on a page, in reading order, lowercased. Handwriting is often misread, but two
    /// photos of the same page are misread in much the same way, and different pages share few words in order.
    public static func words(image data: Data) async -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600,
              ] as CFDictionary)
        else { return [] }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let lines = try? await request.perform(on: image) else { return [] }
        let ordered = lines.sorted { ($0.boundingBox.cgRect.midY, $1.boundingBox.cgRect.minX) > ($1.boundingBox.cgRect.midY, $0.boundingBox.cgRect.minX) }
        return ordered.flatMap { line in
            WordTokenizer.tokens(in: line.topCandidates(1).first?.string ?? "").map(\.key)
        }
    }

    /// The share of word pairs on the shorter list that are also on the other, from 0 to 1.
    public static func wordSimilarity(_ a: [String], _ b: [String]) -> Double {
        func pairs(_ words: [String]) -> [String: Int] {
            var result: [String: Int] = [:]
            for index in words.indices.dropLast() { result[words[index] + " " + words[index + 1], default: 0] += 1 }
            return result
        }
        let left = pairs(a), right = pairs(b)
        let smaller = min(left.values.reduce(0, +), right.values.reduce(0, +))
        guard smaller >= 8 else { return 0 }
        let shared = left.reduce(0) { $0 + min($1.value, right[$1.key] ?? 0) }
        return Double(shared) / Double(smaller)
    }

    /// A digest of a photo file's bytes, for spotting the very same file dropped twice.
    public static func fileDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}

/// Pages whose read text is nearly the same, which happens when one page was saved twice under different
/// numbers. Compares runs of four words, so shared common phrases don't count.
public enum TextDuplicates {
    /// The share of the shorter page's word runs that must also be on the other page.
    public static let threshold = 0.6
    /// Pages shorter than this many words aren't compared; short pages share runs by chance.
    public static let minimumWords = 25

    /// For each page that looks like a copy of another, the page it copies. Both pages of a pair are listed.
    public static func find(_ texts: [UUID: String]) -> [UUID: UUID] {
        var shingles: [UUID: Set<Int>] = [:]
        var index: [Int: [UUID]] = [:]
        for (id, text) in texts {
            let keys = WordTokenizer.tokens(in: text).map(\.key)
            guard keys.count >= minimumWords else { continue }
            var set = Set<Int>()
            for start in 0...(keys.count - 4) { set.insert(keys[start..<(start + 4)].joined(separator: " ").hashValue) }
            shingles[id] = set
            for shingle in set { index[shingle, default: []].append(id) }
        }
        var result: [UUID: UUID] = [:]
        var best: [UUID: Double] = [:]
        for (id, set) in shingles {
            var shared: [UUID: Int] = [:]
            for shingle in set {
                for other in index[shingle] ?? [] where other != id { shared[other, default: 0] += 1 }
            }
            for (other, count) in shared {
                guard let otherSet = shingles[other] else { continue }
                let share = Double(count) / Double(min(set.count, otherSet.count))
                if share >= threshold, share > best[id] ?? 0 {
                    best[id] = share
                    result[id] = other
                }
            }
        }
        return result
    }
}
