import CommonCrypto
import CryptoKit
import Foundation

/// A "usage pass" is a shareable bundle of the SHORT-LIVED access tokens for one or more
/// accounts — never the rotating refresh token, so importing one can't invalidate the
/// sender's login (it works until the token expires, then the recipient re-imports).
///
/// It can be copied two ways: encrypted with a passphrase (for Overseer-to-Overseer sharing
/// over any channel) or plain (unsafe, for a recipient who doesn't run Overseer and just
/// wants the token). The package is versioned and every entry is engine-tagged, so adding
/// Codex/Grok later is additive and an older Overseer can skip an entry it doesn't understand.
///
/// This type is deliberately free of AppKit and Keychain dependencies so the format and its
/// crypto can be exercised in isolation.
enum AccessPass {
    static let version = 1

    struct Entry: Codable {
        // Enumerated explicitly so a stored property added later can never be serialized into
        // a shared blob by accident — the refresh token must never appear here.
        enum CodingKeys: String, CodingKey {
            case engine, email, organization, accountUuid, plan
            case accessToken, expiresAt, scopes, subscriptionType, rateLimitTier
        }
        let engine: String            // "claude" | "codex" | "grok"
        let email: String?
        let organization: String?
        let accountUuid: String?
        let plan: String?
        let accessToken: String
        let expiresAt: Double?        // seconds since 1970
        let scopes: [String]?
        let subscriptionType: String?
        let rateLimitTier: String?
    }

    struct Package: Codable {
        let version: Int
        let createdAt: Double
        let passes: [Entry]
    }

    enum PassError: Error, CustomStringConvertible {
        case empty
        case badFormat
        case needsPassphrase
        case wrongPassphrase
        case unsupportedVersion

        var description: String {
            switch self {
            case .empty: return "The clipboard has no usage keys to import."
            case .badFormat: return "That doesn't look like an Overseer usage-keys blob."
            case .needsPassphrase: return "These usage keys are encrypted — a passphrase is required."
            case .wrongPassphrase: return "Wrong passphrase, or the keys were altered in transit."
            case .unsupportedVersion: return "These usage keys were made by a newer version of Overseer."
            }
        }
    }

    private static let encPrefix = "overseer-pass;v1;enc;"
    private static let plainPrefix = "overseer-pass;v1;plain;"
    private static let saltCount = 16
    private static let sealedMinCount = 28          // 12-byte nonce + 16-byte GCM tag
    private static let iterations: UInt32 = 600_000 // OWASP PBKDF2-SHA256 floor

    static func makePackage(_ entries: [Entry], createdAt: Double) -> Package {
        Package(version: version, createdAt: createdAt, passes: entries)
    }

    // MARK: - Encode

    static func encodePlain(_ package: Package) throws -> String {
        guard let data = try? JSONEncoder().encode(package) else { throw PassError.badFormat }
        return plainPrefix + data.base64EncodedString()
    }

    static func encodeEncrypted(_ package: Package, passphrase: String) throws -> String {
        guard let plaintext = try? JSONEncoder().encode(package) else { throw PassError.badFormat }
        let salt = (0 ..< saltCount).map { _ in UInt8.random(in: .min ... .max) }
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        // Bind the version framing as additional authenticated data so a ciphertext can't be
        // re-wrapped under a different version label by a future reader.
        guard let sealed = try? AES.GCM.seal(plaintext, using: key, authenticating: Data(encPrefix.utf8)),
              let combined = sealed.combined else { throw PassError.badFormat }
        var blob = Data(salt)
        blob.append(combined)                       // nonce ‖ ciphertext ‖ tag
        return encPrefix + blob.base64EncodedString()
    }

    // MARK: - Decode

    /// True when the blob needs a passphrase, so callers can prompt only when necessary.
    static func isEncrypted(_ blob: String) -> Bool {
        trimmed(blob).hasPrefix(encPrefix)
    }

    static func decode(_ blob: String, passphrase: String?) throws -> Package {
        let text = trimmed(blob)
        guard !text.isEmpty else { throw PassError.empty }

        // Tolerate channels that wrap or pad the base64 (mail, chat) — the payload is either
        // GCM-authenticated (enc) or has no integrity property to weaken (plain).
        if text.hasPrefix(plainPrefix) {
            guard let data = Data(base64Encoded: String(text.dropFirst(plainPrefix.count)),
                                  options: .ignoreUnknownCharacters) else {
                throw PassError.badFormat
            }
            return try decodePackage(data)
        }

        if text.hasPrefix(encPrefix) {
            guard let passphrase, !passphrase.isEmpty else { throw PassError.needsPassphrase }
            guard let blobData = Data(base64Encoded: String(text.dropFirst(encPrefix.count)),
                                      options: .ignoreUnknownCharacters),
                  blobData.count >= saltCount + sealedMinCount else { throw PassError.badFormat }
            let salt = Array(blobData.prefix(saltCount))
            // Construct the box (a shape check) before the expensive KDF, and keep version
            // errors distinct from passphrase errors by decoding outside the open.
            guard let box = try? AES.GCM.SealedBox(combined: blobData.dropFirst(saltCount)) else {
                throw PassError.badFormat
            }
            let key = try deriveKey(passphrase: passphrase, salt: salt)
            guard let plaintext = try? AES.GCM.open(box, using: key, authenticating: Data(encPrefix.utf8)) else {
                throw PassError.wrongPassphrase
            }
            return try decodePackage(plaintext)
        }

        throw PassError.badFormat
    }

    private static func decodePackage(_ data: Data) throws -> Package {
        guard let package = try? JSONDecoder().decode(Package.self, from: data) else {
            throw PassError.badFormat
        }
        guard package.version >= 1 else { throw PassError.badFormat }
        guard package.version <= version else { throw PassError.unsupportedVersion }
        return package
    }

    private static func deriveKey(passphrase: String, salt: [UInt8]) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let password = Array(passphrase.utf8)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password, password.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            iterations,
            &derived, derived.count
        )
        guard status == kCCSuccess else { throw PassError.badFormat }
        return SymmetricKey(data: Data(derived))
    }

    private static func trimmed(_ blob: String) -> String {
        blob.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
