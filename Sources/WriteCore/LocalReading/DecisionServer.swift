import CoreGraphics
import CoreText
import Darwin
import os
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum DecisionModelError: Error, LocalizedError, Equatable {
    case runtimeMissing
    case modelMissing
    case downloadFailed(String)
    case startFailed(String)
    case stopped
    case badReply(Int)

    public var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            return "Reading on this Mac needs llama.cpp. Install it with Homebrew: brew install llama.cpp"
        case .modelMissing:
            return "The reading model hasn't been downloaded yet."
        case .downloadFailed(let reason):
            return "The model couldn't be downloaded: \(reason)"
        case .startFailed(let reason):
            return "The reading model couldn't start: \(reason)"
        case .stopped:
            return "The reading model stopped."
        case .badReply(let status):
            return "The reading model gave an unexpected answer (error \(status))."
        }
    }
}

/// The decision model's files: MiniCPM-OCR-Jev, which looks at a crop of writing and a candidate reading
/// and answers how likely the reading is correct. It runs in llama.cpp, entirely on this Mac.
public struct DecisionModelFiles: Sendable {
    public static let source = URL(string: "https://huggingface.co/openbmb/MiniCPM-OCR-Jev-gguf/resolve/main/")!
    public static let modelName = "MiniCPM-OCR-Jev-Q8_0.gguf"
    public static let projectorName = "mmproj-model-f16.gguf"
    public static let expectedSizes = [modelName: Int64(2_012_021_120), projectorName: Int64(671_372_416)]

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var model: URL { directory.appendingPathComponent(Self.modelName) }
    public var projector: URL { directory.appendingPathComponent(Self.projectorName) }

    public var isDownloaded: Bool {
        Self.expectedSizes.allSatisfy { name, size in
            let url = directory.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? Int64) == size
        }
    }

    public static var downloadSize: Int64 { expectedSizes.values.reduce(0, +) }

    /// Homebrew's llama-server, or one named in LLAMA_SERVER.
    public static func findRuntime() -> URL? {
        var paths = ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        if let custom = ProcessInfo.processInfo.environment["LLAMA_SERVER"], !custom.isEmpty {
            paths.insert(custom, at: 0)
        }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Downloads both files, reporting the fraction done. Only model files are fetched; nothing is sent.
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = [Self.projectorName, Self.modelName]
        var finished: Int64 = 0
        for name in names {
            let destination = directory.appendingPathComponent(name)
            let size = Self.expectedSizes[name] ?? 0
            let current = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
            if current == size {
                finished += size
                continue
            }
            let done = finished
            let file = try await FileDownload.fetch(Self.source.appendingPathComponent(name)) { received in
                progress(Double(done + received) / Double(Self.downloadSize))
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? Int64) == size else {
                try? FileManager.default.removeItem(at: file)
                throw DecisionModelError.downloadFailed("\(name) arrived incomplete.")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file, to: destination)
            finished += size
        }
        progress(1)
    }
}

private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    static func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = FileDownload(onProgress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so keep the file first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw DecisionModelError.downloadFailed("the server answered \(http.statusCode).")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: (error as? URLError)?.code == .cancelled
                             ? CancellationError() : DecisionModelError.downloadFailed(error.localizedDescription))
        continuation = nil
    }
}

/// Runs the decision model in a private llama-server on 127.0.0.1 and asks it one question at a time:
/// does this candidate text match this crop of handwriting?
public actor DecisionServer {
    /// Settings found by testing on an M3 Pro: capping image tokens at 32 cut each decision from 340 ms to about
    /// 167 ms with no loss of accuracy on word crops scaled to 32 pixels high.
    public static let cropHeight = 32
    static let imageTokenRange = (min: 8, max: 32)

    /// Runs llama-server under a small shell watchdog that stops it if this app exits for any reason,
    /// including a crash, so the model never lingers in memory on its own.
    static let watchdog = """
        "$0" "$@" & child=$!
        trap 'kill $child 2>/dev/null; wait $child; exit 0' TERM INT HUP
        while kill -0 "$WATCH_PID" 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 1; done
        kill $child 2>/dev/null
        wait $child
        """

    private let files: DecisionModelFiles
    private let processID = OSAllocatedUnfairLock<pid_t>(initialState: 0)
    private var process: Process?
    private var port = 0
    private var key = ""
    private let session: URLSession

    public init(files: DecisionModelFiles) {
        self.files = files
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    public var isRunning: Bool { process?.isRunning == true }

    public func start() async throws {
        if process?.isRunning == true { return }
        guard let runtime = DecisionModelFiles.findRuntime() else { throw DecisionModelError.runtimeMissing }
        guard files.isDownloaded else { throw DecisionModelError.modelMissing }

        port = try Self.freePort()
        key = UUID().uuidString
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        var environment = ProcessInfo.processInfo.environment
        environment["WATCH_PID"] = String(getpid())
        process.environment = environment
        process.arguments = [
            "-c", Self.watchdog, runtime.path,
            "-m", files.model.path, "--mmproj", files.projector.path,
            "--host", "127.0.0.1", "--port", String(port), "--api-key", key,
            "-ngl", "99", "-c", "4096", "-np", "1", "-fa", "on",
            "--image-min-tokens", String(Self.imageTokenRange.min),
            "--image-max-tokens", String(Self.imageTokenRange.max),
            "--offline", "--log-disable",
        ]
        // Nothing the model sees is written anywhere.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DecisionModelError.startFailed(error.localizedDescription)
        }
        self.process = process
        processID.withLock { $0 = process.processIdentifier }

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                self.process = nil
                throw DecisionModelError.startFailed("llama-server exited. Updating llama.cpp may help: brew upgrade llama.cpp")
            }
            if await isHealthy() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        stop()
        throw DecisionModelError.startFailed("it took too long to load.")
    }

    public func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        processID.withLock { $0 = 0 }
    }

    /// Stops the model immediately, from any thread. Used when the app quits.
    public nonisolated func terminateNow() {
        let pid = processID.withLock { current -> pid_t in
            defer { current = 0 }
            return current
        }
        if pid > 0 { kill(pid, SIGTERM) }
    }

    /// The probability, from 0 to 1, that `candidate` is what is written in `crop` (a PNG).
    public func score(crop: Data, candidate: String) async throws -> Double {
        guard process?.isRunning == true else { throw DecisionModelError.stopped }
        let height = CGFloat(Self.cropHeight)
        guard let rendered = CandidateRenderer.png(candidate, height: height) else { throw DecisionModelError.badReply(0) }
        let body: [String: Any] = [
            "state": candidate,
            "files": ["data:image/png;base64," + crop.base64EncodedString(),
                      "data:image/png;base64," + rendered.base64EncodedString()],
            "questions": ["match": ["type": "noul"]],
        ]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/systemone")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw process?.isRunning == true ? DecisionModelError.badReply(0) : DecisionModelError.stopped
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: Any],
              let match = answers["match"] as? [String: Any],
              let probability = match["noul"] as? Double
        else { throw DecisionModelError.badReply(status) }
        return probability
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Asks the system for an unused local port.
    static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw DecisionModelError.startFailed("no free port.") }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0 }
        }
        guard bound else { throw DecisionModelError.startFailed("no free port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Draws a candidate reading as plain black type, the "rendered" image the model compares with the crop.
public enum CandidateRenderer {
    public static func image(_ text: String, height: CGFloat) -> CGImage? {
        let font = CTFontCreateWithName("Helvetica" as CFString, height * 0.6, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let width = max(Int(textWidth + Double(height) / 2), 8)
        guard let context = CGContext(data: nil, width: width, height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: Int(height)))
        context.textPosition = CGPoint(x: height / 4, y: height * 0.2)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    public static func png(_ text: String, height: CGFloat) -> Data? {
        image(text, height: height).flatMap(PNG.encode)
    }
}

enum PNG {
    static func encode(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
