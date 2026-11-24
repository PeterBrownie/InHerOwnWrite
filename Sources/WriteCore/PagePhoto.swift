import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PagePhotoError: Error, LocalizedError {
    case unreadable
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "That file couldn't be read as a photo."
        case .tooLarge: return "That photo is too large to process."
        }
    }
}

public enum PagePhoto {
    private static let maxSourceBytes = 100 * 1024 * 1024
    private static let maxSourcePixels = 200_000_000
    /// Base64 adds a third, and the API accepts images up to 5 MB once encoded.
    private static let maxOutputBytes = 3_600_000
    private static let attempts: [(dimension: Int, quality: Double)] = [
        (2400, 0.84), (2400, 0.70), (2000, 0.72), (1600, 0.72), (1400, 0.60),
    ]

    /// Applies the camera orientation and returns a JPEG with no location or device metadata.
    public static func prepare(_ data: Data) throws -> Data {
        guard data.count <= maxSourceBytes else { throw PagePhotoError.tooLarge }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw PagePhotoError.unreadable }

        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxSourcePixels else { throw PagePhotoError.tooLarge }

        for attempt in attempts {
            let output = try encode(source, maxDimension: min(attempt.dimension, max(width, height)), quality: attempt.quality)
            if output.count <= maxOutputBytes { return output }
        }
        throw PagePhotoError.tooLarge
    }

    /// When a photo was taken, from its camera metadata, or failing that when the file was created.
    public static func dateTaken(_ url: URL) -> Date? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let stamps = [exif?[kCGImagePropertyExifDateTimeOriginal], exif?[kCGImagePropertyExifDateTimeDigitized],
                          tiff?[kCGImagePropertyTIFFDateTime]]
            for case let stamp as String in stamps {
                if let date = exifDate.date(from: stamp) { return date }
            }
        }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// Photos in the order they were taken; any without a date go last, by name.
    public static func sortedByDate(_ urls: [URL]) -> [URL] {
        let dated = urls.map { ($0, dateTaken($0)) }
        return dated.sorted { a, b in
            switch (a.1, b.1) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.0.lastPathComponent.localizedStandardCompare(b.0.lastPathComponent) == .orderedAscending
            }
        }.map(\.0)
    }

    /// Camera time stamps carry no time zone; they're read as this Mac's local time, which only has to put
    /// photos from one camera in order.
    private static let exifDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static func encode(_ source: CGImageSource, maxDimension: Int, quality: Double) throws -> Data {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw PagePhotoError.unreadable
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PagePhotoError.unreadable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PagePhotoError.unreadable }
        return output as Data
    }
}
