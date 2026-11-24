import AppKit
import SwiftUI
import WriteCore

public struct InHerOwnWriteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel(directory: InHerOwnWriteApp.dataDirectory)
    @StateObject private var updater = Updater()

    public init() {
        umask(0o077)
        // macOS would otherwise save window contents to disk for session restore.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    public var body: some Scene {
        WindowGroup("In Her Own Write", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .background(WindowPrivacy())
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.prepareToQuit()
                }
                // An update is only offered; nothing restarts until she chooses Update & Restart.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if updater.showsBanner { UpdateBanner(updater: updater) }
                }
                .task { await updater.check(quietly: true) }
                .alert(updater.message ?? "", isPresented: Binding(
                    get: { updater.message != nil },
                    set: { if !$0 { updater.message = nil } }
                )) {
                    Button("OK") { updater.message = nil }
                }
        }
        .defaultSize(width: 1240, height: 800)

        Window("Reading on This Mac", id: "local-reader") {
            LocalReaderWindow()
                .environmentObject(model)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Reading on This Mac") { model.showLocalReader() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.screen != .library)
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Page…") { model.showUpload = true }
                    .keyboardShortcut("n")
                    .disabled(model.screen != .library)
            }
            CommandGroup(before: .toolbar) {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show Page Photo", isOn: $model.showPhoto)
                Toggle("Show Two Pages", isOn: $model.twoPageSpread)
                Toggle("Accurate Line Breaks", isOn: $model.accurateLineBreaks)
                Divider()
            }
            CommandGroup(after: .appInfo) {
                Button(updater.state == .checking ? "Checking for Updates…" : "Check for Updates…") {
                    Task { await updater.check(quietly: false) }
                }
                .disabled(updater.state == .checking || updater.state == .restarting)
            }
            CommandGroup(after: .appSettings) {
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",")
                    .disabled(model.screen != .library)
                Button("Lock Journal") { model.lock() }
                    .keyboardShortcut("l")
                    .disabled(model.screen != .library)
            }
        }
    }

    public static var dataDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["IN_HER_OWN_WRITE_DATA"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("In Her Own Write", isDirectory: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

/// Keeps decrypted pages out of the window snapshots macOS saves for session restore.
private struct WindowPrivacy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.isRestorable = false }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isRestorable = false
    }
}
