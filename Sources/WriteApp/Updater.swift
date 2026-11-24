import AppKit
import CryptoKit
import Foundation

/// Keeps the app current with its GitHub repository. The install script records the commit the app was
/// built from, the repository, and, on a Mac that built it, where its source lives. When there is something
/// newer, a bar offers the update and, while the app stays open, the new version is made ready in the
/// background: built from the source on a Mac that has it, or otherwise downloaded from the repository's
/// latest release, which GitHub builds on every push to `main`. Choosing Update & Restart quits only once
/// the new version is ready; a small helper swaps in the new copy and reopens it, which takes a few seconds.
/// If the swap fails, the version already installed reopens.
@MainActor
public final class Updater: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        /// An update was found and is being pulled and built.
        case preparing
        /// The new version is built and waiting to be swapped in.
        case ready
        case failed(String)
        case restarting
    }

    @Published public private(set) var state: State = .idle
    /// Whether Update & Restart was chosen before the update finished building.
    @Published public private(set) var restartWhenReady = false
    @Published public private(set) var isDismissed = false
    /// A message for a check the person asked for.
    @Published public var message: String?

    /// Where new versions come from.
    public enum Channel: Equatable, Sendable {
        /// A git checkout on this Mac, built here.
        case source(URL)
        /// The latest release of a GitHub repository ("owner/name"), built by GitHub.
        case releases(String)
    }

    /// A newer version published as a GitHub release.
    public struct Release: Equatable, Sendable {
        public var tag: String
        public var download: URL
        /// GitHub's checksum of the download, such as "sha256:…", when it gives one.
        public var digest: String?
    }

    /// The release file the app downloads; the release workflow uploads it under this name.
    public nonisolated static let releaseAsset = "In-Her-Own-Write.zip"

    private let commit: String?
    private let source: URL?
    private let repository: String?
    private let bundleURL: URL
    private let identifier: String?
    /// The new version, once one is found and made ready.
    private var release: Release?
    private var staged: URL?

    public init(bundle: Bundle = .main) {
        commit = bundle.object(forInfoDictionaryKey: "InHerOwnWriteCommit") as? String
        source = (bundle.object(forInfoDictionaryKey: "InHerOwnWriteSource") as? String)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        repository = bundle.object(forInfoDictionaryKey: "InHerOwnWriteRepository") as? String
        bundleURL = bundle.bundleURL
        identifier = bundle.bundleIdentifier
    }

    /// An updater frozen in one state, for screenshots.
    public static func preview(_ state: State, restartWhenReady: Bool = false) -> Updater {
        let updater = Updater(bundle: Bundle(for: BundleMarker.self))
        updater.state = state
        updater.restartWhenReady = restartWhenReady
        return updater
    }

    private final class BundleMarker {}

    public var showsBanner: Bool {
        guard !isDismissed else { return false }
        switch state {
        case .preparing, .ready, .failed: return true
        default: return false
        }
    }

    /// Building from source needs the git checkout the app was built from, and Apple's developer tools.
    /// Without them, as on a Mac that was sent the app, updates come from GitHub's releases instead.
    var channel: Channel? { Self.channel(commit: commit, source: source, repository: repository) }

    public nonisolated static func channel(commit: String?, source: URL?, repository: String?) -> Channel? {
        guard commit != nil else { return nil }
        if let source,
           FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path),
           FileManager.default.isExecutableFile(atPath: "/usr/bin/git"),
           run("/usr/bin/xcode-select", ["-p"], timeout: 5)?.status == 0 {
            return .source(source)
        }
        if let repository, isRepositoryName(repository) { return .releases(repository) }
        return nil
    }

    public var isAvailable: Bool { channel != nil }

    /// Why an app at this place can't replace itself, if it can't.
    public nonisolated static func installProblem(for app: URL) -> String? {
        // macOS runs a newly downloaded app from a hidden, read-only copy until it's moved.
        if app.path.contains("/AppTranslocation/") {
            return "Move In Her Own Write into your Applications folder and open it from there, so it can update itself."
        }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            return "In Her Own Write can't update itself where it is. Move it into your Applications folder."
        }
        return nil
    }

    public nonisolated static func isRepositoryName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    /// Checks GitHub and, if there is something newer, offers it and starts getting it ready. `quietly`
    /// skips messages when nothing is found, for the check made at launch.
    public func check(quietly: Bool) async {
        switch state {
        case .preparing, .ready, .failed:
            // Already found; a check the person asked for brings the bar back.
            if !quietly { isDismissed = false }
            return
        case .checking, .restarting:
            return
        case .idle:
            break
        }
        let (source, repository) = (source, repository)
        guard let commit, let channel = await Task.detached(priority: .utility, operation: {
            Self.channel(commit: commit, source: source, repository: repository)
        }).value else {
            if !quietly { message = "This copy of In Her Own Write doesn't know where its updates come from. Install the latest version from the repository's Releases page on GitHub." }
            return
        }
        if let problem = Self.installProblem(for: bundleURL) {
            if !quietly { message = problem }
            return
        }
        state = .checking
        let found: Result<Bool, CheckError>?
        switch channel {
        case .source(let source):
            found = await Task.detached(priority: .utility) { Self.newerCommit(than: commit, in: source) }.value
        case .releases(let repository):
            switch await Self.newerRelease(than: commit, in: repository) {
            case .success(let newer):
                release = newer
                found = .success(newer != nil)
            case .failure(let error):
                found = .failure(error)
            }
        }
        switch found {
        case .some(.success(let newer)) where newer:
            isDismissed = false
            prepare()
        case .some(.success):
            state = .idle
            if !quietly { message = "In Her Own Write is up to date." }
        case .some(.failure(.failed(let reason))):
            state = .idle
            if !quietly { message = reason }
        case .none:
            state = .idle
        }
    }

    public func updateAndRestart() {
        switch state {
        case .ready:
            restart()
        case .preparing:
            restartWhenReady = true
        case .failed:
            restartWhenReady = true
            prepare()
        default:
            break
        }
    }

    public func tryAgain() {
        if case .failed = state { prepare() }
    }

    public func ignore() {
        isDismissed = true
        restartWhenReady = false
    }

    /// Makes the new version ready next to the installed app, which keeps running meanwhile: pulls and builds
    /// the new commits, or downloads and checks the new release.
    private func prepare() {
        guard let channel else { return }
        state = .preparing
        Task {
            let outcome: Result<URL, CheckError>
            switch channel {
            case .source(let source):
                let staged = source.appendingPathComponent(".build/In Her Own Write.app", isDirectory: true)
                outcome = await Self.build(source: source, staged: staged).map { staged }
            case .releases:
                guard let release else { state = .idle; return }
                outcome = await Self.download(release, identifier: identifier)
            }
            switch outcome {
            case .success(let app):
                staged = app
                state = .ready
                if restartWhenReady { restart() }
            case .failure(.failed(let reason)):
                state = .failed(reason)
                restartWhenReady = false
            }
        }
    }

    nonisolated static func build(source: URL, staged: URL) async -> Result<Void, CheckError> {
        let git = "/usr/bin/git", path = source.path
        guard run(git, ["-C", path, "merge", "--ff-only", "--quiet", "@{upstream}"], timeout: 60)?.status == 0 else {
            return .failure(.failed("The new version couldn't be pulled, likely because this copy of the code has changes of its own."))
        }
        let status = await runLogged("/bin/zsh", [source.appendingPathComponent("Start In Her Own Write.command").path, "--stage-only"],
                                     in: source)
        guard status == 0 else { return .failure(.failed("The new version didn't build.")) }
        let head = run(git, ["-C", path, "rev-parse", "HEAD"], timeout: 10)?.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let built = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))?["InHerOwnWriteCommit"] as? String
        guard let head, built == head else { return .failure(.failed("The new version built, but it doesn't match the update.")) }
        return .success(())
    }

    /// Downloads a release into the caches folder, checks it, and unpacks it. Returns the app ready to swap in.
    nonisolated static func download(_ release: Release, identifier: String?) async -> Result<URL, CheckError> {
        let fileManager = FileManager.default
        let folder = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("In Her Own Write/Update", isDirectory: true)
        try? fileManager.removeItem(at: folder)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        log("downloading \(release.tag)")
        var request = URLRequest(url: release.download, timeoutInterval: 300)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (file, response) = try? await session.download(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return .failure(.failed("The new version couldn't be downloaded. Check the internet connection.")) }
        let zip = folder.appendingPathComponent(releaseAsset)
        do { try fileManager.moveItem(at: file, to: zip) } catch {
            return .failure(.failed("The new version couldn't be saved: \(error.localizedDescription)"))
        }
        if let digest = release.digest, digest.hasPrefix("sha256:") {
            let actual = (try? Data(contentsOf: zip)).map { data in
                "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            guard actual == digest.lowercased() else { return .failure(.failed("The download was damaged on the way.")) }
        }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path], timeout: 120)?.status == 0 else {
            return .failure(.failed("The download couldn't be unpacked."))
        }
        let app = folder.appendingPathComponent("In Her Own Write.app", isDirectory: true)
        if let problem = checkDownloadedApp(app, identifier: identifier) { return .failure(.failed(problem)) }
        // The app downloaded this itself, so macOS shouldn't mark it as coming from the internet; if anything
        // did, the new copy would be stopped at its first launch.
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path], timeout: 30)
        try? fileManager.removeItem(at: zip)
        log("ready \(release.tag)")
        return .success(app)
    }

    /// Why a downloaded app shouldn't be installed, if it shouldn't: it must be this app, say which commit it
    /// was built from, and be unchanged since it was signed.
    public nonisolated static func checkDownloadedApp(_ app: URL, identifier: String?) -> String? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info, info["CFBundleIdentifier"] as? String == identifier, info["InHerOwnWriteCommit"] is String else {
            return "The download isn't a copy of In Her Own Write."
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 60)?.status == 0 else {
            return "The download was changed after it was built."
        }
        return nil
    }

    /// The latest release, if it's newer than the commit this app was built from. Only moves forward: a build
    /// GitHub doesn't know about, such as one with unpushed work, or one ahead of the release, stays put.
    public nonisolated static func newerRelease(than commit: String, in repository: String) async -> Result<Release?, CheckError> {
        guard isRepositoryName(repository), commit.range(of: "^[0-9a-f]{7,40}$", options: .regularExpression) != nil,
              let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else { return .failure(.failed("This copy of the app doesn't know where its updates come from.")) }
        guard let latest = await askGitHub(latestURL) else {
            return .failure(.failed("Couldn't reach GitHub. Check the internet connection."))
        }
        if latest.status == 404 { return .success(nil) }  // Nothing released yet.
        if latest.status == 403 || latest.status == 429 {
            return .failure(.failed("GitHub asked the app to wait before checking again. Try again in an hour."))
        }
        guard latest.status == 200, let release = parseRelease(latest.data) else {
            return .failure(.failed("GitHub's answer about the latest version couldn't be read."))
        }
        guard let compareURL = URL(string: "https://api.github.com/repos/\(repository)/compare/\(commit)...\(release.tag)?per_page=1"),
              let compare = await askGitHub(compareURL)
        else { return .failure(.failed("Couldn't reach GitHub. Check the internet connection.")) }
        if compare.status == 404 { return .success(nil) }
        guard compare.status == 200, let status = parseCompareStatus(compare.data) else {
            return .failure(.failed("GitHub's answer about the latest version couldn't be read."))
        }
        return .success(status == "ahead" ? release : nil)
    }

    /// Reads GitHub's description of a release, keeping the app download.
    public nonisolated static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              tag.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == releaseAsset }),
              let address = asset["browser_download_url"] as? String,
              let download = URL(string: address), download.scheme == "https"
        else { return nil }
        return Release(tag: tag, download: download, digest: asset["digest"] as? String)
    }

    /// Reads GitHub's comparison of two commits: "ahead" means the second has everything the first has, and more.
    public nonisolated static func parseCompareStatus(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String
    }

    /// A private session: no cookies, no cache, nothing that could identify the person beyond the request.
    private nonisolated static let session = URLSession(configuration: .ephemeral)
    private nonisolated static let userAgent = "InHerOwnWrite-updater"

    private nonisolated static func askGitHub(_ url: URL) async -> (status: Int, data: Data)? {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return nil }
        return (http.statusCode, data)
    }

    /// Adds a line to the update log, which holds no journal content.
    nonisolated static func log(_ line: String) {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/In Her Own Write/update.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        handle.write(Data("== \(Date()) \(line)\n".utf8))
        try? handle.close()
    }

    /// Hands off to a helper that outlives the app, then quits.
    private func restart() {
        guard let staged else { return }
        state = .restarting
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("in-her-own-write-update.zsh")
        do {
            try Self.helperScript.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [helper.path, String(getpid()), staged.path, bundleURL.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            state = .failed("The update couldn't start: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Waits for the app to quit, swaps in the new copy, and reopens. If the swap fails, the old copy is put
    /// back. Its log holds no journal content.
    public nonisolated static let helperScript = #"""
        #!/bin/zsh
        pid=$1 staged=$2 app=$3
        log="$HOME/Library/Logs/In Her Own Write/update.log"
        mkdir -p "${log:h}"
        exec >>"$log" 2>&1
        echo "== $(date) installing $staged"
        for i in {1..240}; do kill -0 $pid 2>/dev/null || break; sleep 0.25; done
        rm -rf "$app.new" "$app.old"
        if ditto "$staged" "$app.new" && mv "$app" "$app.old" && mv "$app.new" "$app"; then
          rm -rf "$app.old"
          touch "$app"
          echo "== installed"
        else
          echo "== install failed; reopening the current version"
          [[ -d "$app" ]] || mv "$app.old" "$app"
          rm -rf "$app.new"
        fi
        open "$app"
        """#

    /// Runs a long job, such as the build, without blocking, writing its output to the update log.
    nonisolated static func runLogged(_ tool: String, _ arguments: [String], in directory: URL) async -> Int32 {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/In Her Own Write", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("update.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()
        log?.write(Data("== \(Date()) building the update\n".utf8))
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = quietGit(ProcessInfo.processInfo.environment)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log ?? FileHandle.nullDevice
            process.standardError = log ?? FileHandle.nullDevice
            process.terminationHandler = { finished in
                try? log?.close()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                try? log?.close()
                continuation.resume(returning: -1)
            }
        }
    }

    public enum CheckError: Error {
        case failed(String)
    }

    /// Whether the branch on GitHub has commits this build doesn't. Never asks for a password.
    public nonisolated static func newerCommit(than commit: String, in source: URL) -> Result<Bool, CheckError>? {
        let git = "/usr/bin/git"
        let path = source.path
        guard let fetch = run(git, ["-C", path, "fetch", "--quiet"], timeout: 30) else {
            return .failure(.failed("GitHub didn't answer in time. Try again later."))
        }
        guard fetch.status == 0 else {
            return .failure(.failed("Couldn't reach the app's GitHub repository. Check the internet connection. A private repository needs a read-only deploy key on this Mac; see the README."))
        }
        guard let upstream = run(git, ["-C", path, "rev-parse", "@{upstream}"], timeout: 10),
              upstream.status == 0
        else { return .failure(.failed("The app's source folder isn't following a GitHub branch.")) }
        let latest = upstream.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard latest != commit else { return .success(false) }
        // Only move forward: a build that is ahead of GitHub, such as one with unpushed work, stays put.
        let ahead = run(git, ["-C", path, "merge-base", "--is-ancestor", commit, latest], timeout: 10)
        return .success(ahead?.status == 0)
    }

    /// Git that never asks for anything: no password prompt, no keychain (macOS would ask her to allow
    /// that), and SSH only with a key that needs no passphrase, such as a read-only deploy key.
    nonisolated static func quietGit(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment["GIT_TERMINAL_PROMPT"] = "0"
        for helper in ["GIT_ASKPASS", "SSH_ASKPASS", "VSCODE_GIT_ASKPASS_MAIN", "VSCODE_GIT_IPC_HANDLE"] {
            environment[helper] = nil
        }
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        environment["GIT_CONFIG_COUNT"] = "1"
        environment["GIT_CONFIG_KEY_0"] = "credential.helper"
        environment["GIT_CONFIG_VALUE_0"] = ""
        return environment
    }

    @discardableResult
    public nonisolated static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = quietGit(ProcessInfo.processInfo.environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
