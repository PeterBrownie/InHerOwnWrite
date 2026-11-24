import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Key derivation, authenticated encryption, and the printable recovery key.
enum Crypto {
    static let defaultIterations = 2_000_000
    static let iterationRange = 600_000...20_000_000
    private static let recoveryAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func randomBytes(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw VaultError.cryptoUnavailable }
        return bytes
    }

    static func passwordKey(_ password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard iterationRange.contains(iterations) else { throw VaultError.corrupted }
        // Normalized so the same password typed on another keyboard produces the same key.
        let passwordBytes = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                passwordBytes.withUnsafeBytes { input in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        input.bindMemory(to: CChar.self).baseAddress,
                        input.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        output.bindMemory(to: UInt8.self).baseAddress,
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.cryptoUnavailable }
        return SymmetricKey(data: derived)
    }

    static func subkey(_ master: SymmetricKey, purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            salt: Data("in-her-own-write/v1".utf8),
            info: Data(purpose.utf8),
            outputByteCount: 32
        )
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, context: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw VaultError.cryptoUnavailable }
        return combined
    }

    /// The context binds ciphertext to its row, so encrypted values cannot be swapped between pages.
    static func open(_ sealed: Data, key: SymmetricKey, context: String) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: sealed)
        return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
    }

    static func makeRecoveryKey() throws -> (display: String, bytes: Data) {
        let bytes = try randomBytes(20)
        var bits = 0
        var bitCount = 0
        var characters: [Character] = []
        for byte in bytes {
            bits = (bits << 8) | Int(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                characters.append(recoveryAlphabet[(bits >> bitCount) & 31])
            }
            bits &= (1 << bitCount) - 1
        }
        let groups = stride(from: 0, to: characters.count, by: 4).map {
            String(characters[$0..<min($0 + 4, characters.count)])
        }
        return (groups.joined(separator: "-"), bytes)
    }

    /// Accepts lowercase, missing dashes, and the letters people commonly misread as digits.
    static func parseRecoveryKey(_ text: String) -> Data? {
        let cleaned = text.uppercased()
            .filter { $0.isLetter || $0.isNumber }
            .map { character -> Character in
                switch character {
                case "O": return "0"
                case "I", "L": return "1"
                default: return character
                }
            }
        guard cleaned.count == 32 else { return nil }

        var output = Data()
        var bits = 0
        var bitCount = 0
        for character in cleaned {
            guard let value = recoveryAlphabet.firstIndex(of: character) else { return nil }
            bits = (bits << 5) | value
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((bits >> bitCount) & 0xFF))
                bits &= (1 << bitCount) - 1
            }
        }
        return output
    }

    static func recoveryWrappingKey(_ bytes: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: bytes),
            salt: salt,
            info: Data("in-her-own-write/v1/recovery".utf8),
            outputByteCount: 32
        )
    }
}
