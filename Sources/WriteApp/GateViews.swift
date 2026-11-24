import AppKit
import SwiftUI
import WriteCore

public struct RootView: View {
    @EnvironmentObject private var model: AppModel

    public init() {}

    public var body: some View {
        Group {
            switch model.screen {
            case .create: CreateVaultView()
            case .showRecoveryKey(let key): RecoveryKeyView(key: key)
            case .chooseNewPassword: NewPasswordView()
            case .locked: UnlockView()
            case .library: LibraryView()
            }
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Gate screens show their errors inline, so only the library uses the alert.
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.screen == .library && model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

struct GateCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("In Her Own Write")
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .italic()
                        .foregroundStyle(Theme.accent)
                    Text(title)
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(32)
            .frame(width: 440)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        }
    }
}

private struct InlineError: View {
    @EnvironmentObject private var model: AppModel
    var local: String?

    var body: some View {
        if let message = local ?? model.errorMessage {
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CreateVaultView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var password = ""
    @ViewState private var confirmation = ""

    private var problem: String? {
        if password.isEmpty { return nil }
        if password.count < Vault.minimumPasswordLength {
            return "Use at least \(Vault.minimumPasswordLength) characters."
        }
        if !confirmation.isEmpty && confirmation != password { return "The passwords don't match." }
        return nil
    }

    private var canSubmit: Bool {
        password.count >= Vault.minimumPasswordLength && password == confirmation && !model.isWorking
    }

    var body: some View {
        GateCard(
            title: "Choose a password",
            subtitle: "It encrypts every journal, photo, and transcription on this Mac. Nobody can reset it for you."
        ) {
            VStack(spacing: 10) {
                SecureField("Password", text: $password)
                SecureField("Type it again", text: $confirmation)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            InlineError(local: problem)
            Button(action: submit) {
                HStack {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Text("Create Encrypted Journal").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(!canSubmit)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await model.createVault(password: password) }
    }
}

struct RecoveryKeyView: View {
    @EnvironmentObject private var model: AppModel
    let key: String
    @ViewState private var saved = false
    @ViewState private var copied = false

    var body: some View {
        GateCard(
            title: "Save your recovery key",
            subtitle: "If you forget your password, this is the only way back in. Write it on paper and keep it somewhere safe. It won't be shown again."
        ) {
            Text(key.replacingOccurrences(of: "-", with: " "))
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(14)
                .background(Theme.paper, in: RoundedRectangle(cornerRadius: 8))
            Button(copied ? "Copied. Clears in 60 seconds." : "Copy Temporarily") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(key, forType: .string)
                let count = pasteboard.changeCount
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    if pasteboard.changeCount == count { pasteboard.clearContents() }
                }
            }
            Toggle("I wrote down my recovery key", isOn: $saved)
            Button {
                model.confirmRecoveryKeySaved()
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(!saved)
        }
    }
}

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var secret = ""
    @ViewState private var usingRecovery = false
    @FocusState private var focused: Bool

    var body: some View {
        GateCard(
            title: usingRecovery ? "Use recovery key" : "Welcome back",
            subtitle: usingRecovery ? "Enter the key you saved. You'll then choose a new password." : "Enter your password to open your journals."
        ) {
            Group {
                if usingRecovery {
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $secret)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                } else {
                    SecureField("Password", text: $secret)
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .focused($focused)
            .onSubmit(submit)
            InlineError()
            Button(action: submit) {
                HStack {
                    if model.isWorking { ProgressView().controlSize(.small) }
                    Text("Unlock").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(secret.isEmpty || model.isWorking)
            Button(usingRecovery ? "Use password instead" : "Forgot your password?") {
                usingRecovery.toggle()
                secret = ""
                model.errorMessage = nil
            }
            .buttonStyle(.link)
            .frame(maxWidth: .infinity)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !secret.isEmpty, !model.isWorking else { return }
        let entered = secret
        secret = ""
        Task {
            if usingRecovery {
                await model.unlock(recoveryKey: entered)
            } else {
                await model.unlock(password: entered)
            }
        }
    }
}

struct NewPasswordView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var password = ""
    @ViewState private var confirmation = ""

    private var canSubmit: Bool {
        password.count >= Vault.minimumPasswordLength && password == confirmation && !model.isWorking
    }

    var body: some View {
        GateCard(
            title: "Choose a new password",
            subtitle: "Your recovery key worked. Your recovery key stays the same."
        ) {
            VStack(spacing: 10) {
                SecureField("New password (\(Vault.minimumPasswordLength)+ characters)", text: $password)
                SecureField("Type it again", text: $confirmation)
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            InlineError()
            Button {
                Task { _ = await model.setNewPassword(password) }
            } label: {
                Text("Save Password").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(!canSubmit)
        }
    }
}
