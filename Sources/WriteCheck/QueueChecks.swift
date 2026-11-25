import Foundation
import WriteApp
import WriteCore

/// Answers every request after a short wait, counting how many were open at once.
final class SlowStubAPI: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var open = 0
    nonisolated(unsafe) static var mostOpen = 0
    nonisolated(unsafe) static var served = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static func reset() {
        lock.withLock { open = 0; mostOpen = 0; served = 0 }
    }

    override func startLoading() {
        Self.lock.withLock {
            Self.open += 1
            Self.mostOpen = max(Self.mostOpen, Self.open)
        }
        let isRead = request.url?.path.hasSuffix("messages") == true
        DispatchQueue.global().asyncAfter(deadline: .now() + (isRead ? 0.3 : 0)) { [self] in
            Self.lock.withLock {
                Self.open -= 1
                if isRead { Self.served += 1 }
            }
            let body = isRead ? reply(text: "An invented line.") : "{}"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@MainActor
func runQueueChecks() async throws {
    print("Reading several pages with Claude at once (stubbed network)")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    SlowStubAPI.reset()

    let model = AppModel(directory: directory)
    model.makeTranscriber = { key in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowStubAPI.self]
        return Transcriber(apiKey: key, session: URLSession(configuration: configuration), retryDelay: 0.01)
    }
    await model.createVault(password: "synthetic password")
    model.confirmRecoveryKeySaved()
    model.showSettings = false
    let keySaved = await model.saveAPIKey("sk-test-canary")
    check("stubbed key saves", keySaved)
    SlowStubAPI.reset()

    guard let journal = model.createJournal(name: "Queue Test") else {
        check("queue test journal is made", false)
        return
    }
    let jpeg = try PagePhoto.prepare(handwrittenPage())
    let count = AppModel.concurrentReads + 3
    for number in 1...count {
        _ = model.addPage(journalID: journal.id, number: number, jpeg: jpeg, replacing: false)
    }
    // Deleting a page while it's being read cancels it and lets the next one start.
    if let first = model.pages.first(where: { $0.number == 1 }) { model.deletePage(id: first.id) }

    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline, model.pages.contains(where: { $0.status == .reading || $0.status == .waiting }) {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    check("every queued page is read", model.pages.count == count - 1 && model.pages.allSatisfy { $0.status == .done })
    check("pages are read \(AppModel.concurrentReads) at a time, no more",
          SlowStubAPI.mostOpen == AppModel.concurrentReads)
    check("read pages keep their text", model.pages.allSatisfy { model.texts[$0.id] == "An invented line." })

    // Locking mid-read stops the queue and leaves the unread pages waiting.
    model.readAgain(model.pages[0].id)
    model.readAgain(model.pages[1].id)
    model.lock()
    try await Task.sleep(nanoseconds: 600_000_000)
    await model.unlock(password: "synthetic password")
    check("locking mid-read leaves the pages to read again",
          model.pages.filter { $0.status == .waiting }.count == 2)
}
