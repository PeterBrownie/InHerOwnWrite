import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WriteApp
import WriteCore

func pixelSize(_ data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return CGSize(width: width, height: height)
}

func isJPEG(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let type = CGImageSourceGetType(source) as String?
    else { return false }
    return UTType(type)?.conforms(to: .jpeg) ?? false
}

/// Pages are kept as HEIC, sent to Claude as JPEG, and pages saved as JPEG before that are converted in the
/// background once the library is open.
@MainActor
func runPhotoStorageChecks() async throws {
    print("Keeping photos as HEIC")
    let jpeg = try PagePhoto.prepare(handwrittenPage())
    let heic = try PagePhoto.forStorage(jpeg)
    check("a page is kept as HEIC", PagePhoto.isHEIC(heic) && !PagePhoto.isHEIC(jpeg))
    check("HEIC keeps the page's size in pixels", pixelSize(heic) == pixelSize(jpeg))
    check("HEIC takes less space than the JPEG", heic.count < jpeg.count)
    check("a HEIC page is kept as it is", try PagePhoto.forStorage(heic) == heic)
    let sent = try PagePhoto.forSending(heic)
    check("a HEIC page is sent to Claude as a JPEG of the same size",
          isJPEG(sent) && pixelSize(sent) == pixelSize(heic) && sent.base64EncodedString().utf8.count < 5_000_000)
    check("a JPEG page is sent as it is", try PagePhoto.forSending(jpeg) == jpeg)

    // A vault from before: three JPEG pages, one of them with a reading on this Mac saved partway.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let password = "synthetic password"
    let created = try Vault.create(in: directory, password: password)
    let old = created.vault
    let journal = try old.createJournal(name: "Older Pages")
    let pages = try (1...3).map { try old.addPage(journalID: journal.id, number: $0, photo: jpeg, converting: false) }
    try old.saveProgress(pageID: pages[2].id, progress: LocalReadProgress(layoutKey: "partway"))
    check("older pages start as JPEG", try pages.allSatisfy { isJPEG(try old.image(pageID: $0.id)) })
    check("converting a page makes it HEIC", try old.convertPhoto(pageID: pages[0].id)
          && PagePhoto.isHEIC(try old.image(pageID: pages[0].id)))
    check("converting it again changes nothing", try !old.convertPhoto(pageID: pages[0].id))
    old.lock()

    let model = AppModel(directory: directory)
    model.photoConversionPause = .zero
    await model.unlock(password: password)
    func waitForConversion() async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.isConvertingPhotos, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }
    try await waitForConversion()
    model.lock()
    var vault = try Vault.unlock(in: directory, password: password)
    check("opening the library converts older pages in the background",
          try PagePhoto.isHEIC(vault.image(pageID: pages[1].id)))
    check("a page with a reading saved partway is left as it was", try isJPEG(vault.image(pageID: pages[2].id)))
    check("the vault doesn't count conversion as finished while a page is left", try !vault.photosAreConverted())

    try vault.clearProgress(pageID: pages[2].id)
    vault.lock()
    await model.unlock(password: password)
    try await waitForConversion()
    model.lock()
    vault = try Vault.unlock(in: directory, password: password)
    check("once its reading is done, that page is converted too", try PagePhoto.isHEIC(vault.image(pageID: pages[2].id)))
    check("the vault remembers that every page is converted", try vault.photosAreConverted())
    vault.lock()
}
