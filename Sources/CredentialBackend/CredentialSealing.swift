import CryptoKit
import Foundation
import Security

/// Lỗi seal/mở ciphertext. Không chứa dữ liệu bí mật.
public enum SealingError: Error, Equatable, Sendable {
    case badFormat
    case unsupportedVersion
    case authenticationFailed
    case keyFailure
}

/// Khoá ECDH P-256 dùng để seal/mở (ADR-004c): chỉ cần khoá công khai + thoả thuận khoá.
/// Cài đặt thật là Secure Enclave; bản phần mềm chỉ dùng cho test.
public protocol SealingKey: Sendable {
    var publicKey: P256.KeyAgreement.PublicKey { get }
    func sharedSecret(with peer: P256.KeyAgreement.PublicKey) throws -> SharedSecret
}

/// Khoá phần mềm (chỉ test).
public struct SoftwareSealingKey: SealingKey {
    private let privateKey: P256.KeyAgreement.PrivateKey
    public init(privateKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) {
        self.privateKey = privateKey
    }
    public var publicKey: P256.KeyAgreement.PublicKey { privateKey.publicKey }
    public func sharedSecret(with peer: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        try privateKey.sharedSecretFromKeyAgreement(with: peer)
    }
}

/// Khoá Secure Enclave: chỉ `.privateKeyUsage`, `ThisDeviceOnly`, KHÔNG userPresence (ADR-004c).
public struct SecureEnclaveSealingKey: SealingKey, @unchecked Sendable {
    private let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey

    public static func generate() throws -> SecureEnclaveSealingKey {
        var error: Unmanaged<CFError>?
        guard
            let acl = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage], &error)
        else { throw SealingError.keyFailure }
        do {
            return SecureEnclaveSealingKey(
                privateKey: try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: acl))
        } catch { throw SealingError.keyFailure }
    }

    public init(blob: Data) throws {
        do {
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
        } catch { throw SealingError.keyFailure }
    }

    private init(privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey) { self.privateKey = privateKey }

    /// Handle do SE bọc (không phải khoá thô) — lưu vào Keychain.
    public var blob: Data { privateKey.dataRepresentation }
    public var publicKey: P256.KeyAgreement.PublicKey { privateKey.publicKey }
    public func sharedSecret(with peer: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        try privateKey.sharedSecretFromKeyAgreement(with: peer)
    }
}

/// Seal/mở định dạng v1: `0x01 ‖ ephPub x963 (65) ‖ AES.GCM.combined`.
/// HKDF-SHA256(salt = ephPub, info = "sshdesk-credential-v1"), AAD = "sshdesk-v1|<ref>".
public enum CredentialSealing {
    public static let version: UInt8 = 1
    static let ephemeralLength = 65
    /// version + ephPub + nonce 12 + tag 16.
    static let minimumLength = 1 + ephemeralLength + 12 + 16
    static let info = Data("sshdesk-credential-v1".utf8)

    static func aad(_ ref: String) -> Data { Data(("sshdesk-v1|" + ref).utf8) }

    private static func symmetricKey(_ shared: SharedSecret, ephPub: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: ephPub, sharedInfo: info, outputByteCount: 32)
    }

    public static func seal(_ secret: String, ref: String, key: any SealingKey) throws -> Data {
        let eph = P256.KeyAgreement.PrivateKey()
        let ephPub = eph.publicKey.x963Representation
        do {
            let shared = try eph.sharedSecretFromKeyAgreement(with: key.publicKey)
            let box = try AES.GCM.seal(
                Data(secret.utf8), using: symmetricKey(shared, ephPub: ephPub),
                authenticating: aad(ref))
            guard let combined = box.combined else { throw SealingError.keyFailure }
            return Data([version]) + ephPub + combined
        } catch { throw SealingError.keyFailure }
    }

    public static func open(_ data: Data, ref: String, key: any SealingKey) throws -> String {
        let bytes = Data(data)  // chuẩn hoá chỉ số
        guard bytes.count >= minimumLength else { throw SealingError.badFormat }
        guard bytes[0] == version else { throw SealingError.unsupportedVersion }
        let ephPub = Data(bytes[1..<(1 + ephemeralLength)])
        let combined = Data(bytes[(1 + ephemeralLength)...])
        do {
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: ephPub)
            let shared = try key.sharedSecret(with: peer)
            let box = try AES.GCM.SealedBox(combined: combined)
            let plain = try AES.GCM.open(
                box, using: symmetricKey(shared, ephPub: ephPub), authenticating: aad(ref))
            guard let text = String(data: plain, encoding: .utf8) else { throw SealingError.badFormat }
            return text
        } catch let e as SealingError {
            throw e
        } catch { throw SealingError.authenticationFailed }
    }
}
