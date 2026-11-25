import CryptoKit
import LocalAuthentication
import Security
import WriteCore

/// Opening the journal with Touch ID or a nearby unlocked Apple Watch instead of the password.
///
/// A key made in this Mac's Secure Enclave wraps a copy of the vault's key. The enclave uses it only after
/// Touch ID or the watch says yes, and the key never leaves the enclave: the vault keeps only an encrypted
/// handle that's useless on any other Mac. This is used instead of a Keychain item because the Keychain's
/// Touch ID items need a code-signing entitlement that an app built without Xcode can't have.
enum DeviceUnlock {
    /// What this Mac can use right now, named for buttons and settings, or nil if neither is set up.
    static func methodName() -> String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion, error: nil) else { return nil }
        let touchID = context.biometryType == .touchID
        let watch = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithCompanion, error: nil)
        switch (touchID, watch) {
        case (true, true): return "Touch ID or Apple Watch"
        case (true, false): return "Touch ID"
        default: return "Apple Watch"
        }
    }

    /// Asks for Touch ID or the watch. The returned context lets the enclave key be used without asking again.
    static func authenticate(reason: String) async throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometricsOrCompanion, localizedReason: reason)
        return context
    }

    /// A new enclave key that can be used only after Touch ID or the watch, on this Mac, while it's unlocked.
    static func makeKey(context: LAContext) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryAny, .or, .companion], &error
        ) else { throw error!.takeRetainedValue() as Error }
        return try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
    }

    static func reopenKey(_ handle: Data, context: LAContext) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle, authenticationContext: context)
    }

    /// Whether the person dismissed the prompt or chose the password, which isn't worth an error message.
    static func wasCancelled(_ error: Error) -> Bool {
        guard let error = error as? LAError else { return false }
        return [.userCancel, .appCancel, .systemCancel, .userFallback].contains(error.code)
    }
}
