import SwiftUI

/// The bar across the top of the window when an update is available.
public struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    public init(updater: Updater) {
        self.updater = updater
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(isFailure ? Color.orange : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if updater.state == .preparing && updater.restartWhenReady {
                ProgressView().controlSize(.small)
            }
            if isFailure {
                Button("Try Again") { updater.tryAgain() }
            } else {
                Button("Update & Restart") { updater.updateAndRestart() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(updater.restartWhenReady)
            }
            Button("Ignore") { updater.ignore() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Theme.notice)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var isFailure: Bool {
        if case .failed = updater.state { return true }
        return false
    }

    private var icon: String {
        switch updater.state {
        case .failed: return "exclamationmark.triangle"
        case .ready: return "checkmark.circle"
        default: return "arrow.down.circle"
        }
    }

    private var title: String {
        isFailure ? "The update couldn't be prepared." : "There has been an update."
    }

    private var detail: String {
        switch updater.state {
        case .failed(let reason):
            return "\(reason) Details are in ~/Library/Logs/In Her Own Write/update.log."
        case .ready:
            return "It's ready. Restarting takes a few seconds."
        default:
            return updater.restartWhenReady
                ? "Getting it ready. The app restarts as soon as it's done."
                : "Getting it ready in the background. You can keep working."
        }
    }
}
