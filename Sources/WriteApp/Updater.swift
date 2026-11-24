import AppKit
import Foundation

/// Keeps the app current with its GitHub repository. The install script records the commit the app was
/// built from and where its source lives. When GitHub has newer commits, a bar offers the update and, while
/// the app stays open, the new version is pulled and built in the background. Choosing Update & Restart
/// quits only once that build is ready; a small helper swaps in the new copy and reopens it, which takes a
/// few seconds. If the swap fails, the version already installed reopens.
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

    private let commit: String?
    private let source: URL?

    public init(bundle: Bundle = .main) {
        commit = bundle.object(forInfoDictionaryKey: "InHerOwnWriteCommit") as? String
        source = (bundle.object(forInfoDictionaryKey: "InHerOwnWriteSource") as? String)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
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

    /// Built by the install script from a git checkout that still exists, with Apple's developer tools present.
    public var isAvailable: Bool {
        guard commit != nil, let source,
              FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
        else { return false }
        return Self.run("/usr/bin/xcode-select", ["-p"], timeout: 5)?.status == 0
    }

    private var staged: URL? { source?.appendingPathComponent(".build/In Her Own Write.app", isDirectory: true) }

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
        guard isAvailable, let commit, let source else {
            if !quietly { message = "Updates work when the app is installed with “Start In Her Own Write.command” from a copy of its GitHub repository." }
            return
        }
        state = .checking
        let found = await Task.detached(priority: .utility) { Self.newerCommit(than: commit, in: source) }.value
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

    /// Pulls the new commits and builds them next to the installed app, which keeps running meanwhile.
    private func prepare() {
        guard let source, let staged else { return }
        state = .preparing
        Task {
            let outcome = await Self.build(source: source, staged: staged)
            switch outcome {
            case .success:
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

    /// Hands off to a helper that outlives the app, then quits.
    private func restart() {
        guard let staged else { return }
        state = .restarting
        let helper = FileManager.default.temporaryDirectory.appendingPathComponent("in-her-own-write-update.zsh")
        do {
            try Self.helperScript.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [helper.path, String(getpid()), staged.path, Bundle.main.bundleURL.path]
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
    public static let helperScript = #"""
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
