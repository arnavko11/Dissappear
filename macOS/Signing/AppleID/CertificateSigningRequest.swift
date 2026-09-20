import Foundation
import Security

/// Generates the key pair and PKCS#10 request Apple needs in order to issue a
/// development certificate, and files the result in the login keychain.
///
/// The private key is created by the Security framework, marked permanent, and
/// never leaves the keychain — only the public key and the signed request go to
/// Apple, exactly as Xcode does it.
struct CertificateSigningRequest {
    static let keyTag = "com.dissappear.companion.development-key"

    struct KeyPair {
        var privateKey: SecKey
        var publicKey: SecKey
    }

    // MARK: - Keys

    func existingKeyPair() -> KeyPair? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(Self.keyTag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        let privateKey = item as! SecKey
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        return KeyPair(privateKey: privateKey, publicKey: publicKey)
    }

    func generateKeyPair() throws -> KeyPair {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(Self.keyTag.utf8),
                kSecAttrLabel as String: "Dissappear Development Key"
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw AppleIDError.protocolFailure("A signing key could not be created: \(Self.describe(error)).")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw AppleIDError.protocolFailure("The generated key has no public half.")
        }
        return KeyPair(privateKey: privateKey, publicKey: publicKey)
    }

    // MARK: - Request

    /// PEM-encoded PKCS#10 certificate signing request.
    func makeRequest(keyPair: KeyPair, commonName: String, emailAddress: String, country: String = "US") throws -> String {
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(keyPair.publicKey, &error) as Data? else {
            throw AppleIDError.protocolFailure("The public key could not be exported: \(Self.describe(error)).")
        }

        let subject = ASN1.sequence([
            ASN1.set([ASN1.sequence([ASN1.objectIdentifier([2, 5, 4, 6]), ASN1.printableString(country)])]),
            ASN1.set([ASN1.sequence([ASN1.objectIdentifier([2, 5, 4, 3]), ASN1.utf8String(commonName)])]),
            ASN1.set([ASN1.sequence([ASN1.objectIdentifier([1, 2, 840, 113549, 1, 9, 1]),
                                     ASN1.ia5String(emailAddress)])])
        ])

        let algorithm = ASN1.sequence([
            ASN1.objectIdentifier([1, 2, 840, 113549, 1, 1, 1]),   // rsaEncryption
            ASN1.null()
        ])
        let subjectPublicKeyInfo = ASN1.sequence([algorithm, ASN1.bitString(publicKeyData)])

        let requestInfo = ASN1.sequence([
            ASN1.integer(0),
            subject,
            subjectPublicKeyInfo,
            ASN1.contextSpecificConstructed(0, content: Data())   // no attributes
        ])

        guard let signature = SecKeyCreateSignature(keyPair.privateKey,
                                                    .rsaSignatureMessagePKCS1v15SHA256,
                                                    requestInfo as CFData,
                                                    &error) as Data? else {
            throw AppleIDError.protocolFailure("The request could not be signed: \(Self.describe(error)).")
        }

        let signatureAlgorithm = ASN1.sequence([
            ASN1.objectIdentifier([1, 2, 840, 113549, 1, 1, 11]),  // sha256WithRSAEncryption
            ASN1.null()
        ])
        let csr = ASN1.sequence([requestInfo, signatureAlgorithm, ASN1.bitString(signature)])

        let base64 = csr.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE REQUEST-----\n\(base64)\n-----END CERTIFICATE REQUEST-----\n"
    }

    /// Files the issued certificate so it pairs with the private key and becomes
    /// a usable signing identity.
    func importCertificate(_ der: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw AppleIDError.protocolFailure("Apple returned a certificate that could not be read.")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw AppleIDError.protocolFailure("The certificate could not be added to your keychain (error \(status)).")
        }
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error = error?.takeRetainedValue() else { return "unknown error" }
        return CFErrorCopyDescription(error) as String? ?? "unknown error"
    }
}

/// The small slice of DER encoding a PKCS#10 request needs.
enum ASN1 {
    static func encode(tag: UInt8, content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 128 {
            out.append(UInt8(count))
        } else {
            var length = count
            var bytes: [UInt8] = []
            while length > 0 {
                bytes.insert(UInt8(length & 0xFF), at: 0)
                length >>= 8
            }
            out.append(UInt8(0x80 | bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(content)
        return out
    }

    static func sequence(_ items: [Data]) -> Data {
        encode(tag: 0x30, content: items.reduce(Data(), +))
    }

    static func set(_ items: [Data]) -> Data {
        encode(tag: 0x31, content: items.reduce(Data(), +))
    }

    static func integer(_ value: Int) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return encode(tag: 0x02, content: Data(bytes))
    }

    static func bitString(_ data: Data) -> Data {
        encode(tag: 0x03, content: Data([0]) + data)     // no unused bits
    }

    static func null() -> Data { Data([0x05, 0x00]) }

    static func utf8String(_ value: String) -> Data {
        encode(tag: 0x0C, content: Data(value.utf8))
    }

    static func printableString(_ value: String) -> Data {
        encode(tag: 0x13, content: Data(value.utf8))
    }

    static func ia5String(_ value: String) -> Data {
        encode(tag: 0x16, content: Data(value.utf8))
    }

    static func contextSpecificConstructed(_ number: UInt8, content: Data) -> Data {
        encode(tag: 0xA0 | number, content: content)
    }

    static func objectIdentifier(_ components: [UInt]) -> Data {
        var bytes: [UInt8] = [UInt8(components[0] * 40 + components[1])]
        for component in components.dropFirst(2) {
            var value = component
            var encoded: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                encoded.insert(UInt8((value & 0x7F) | 0x80), at: 0)
                value >>= 7
            }
            bytes.append(contentsOf: encoded)
        }
        return encode(tag: 0x06, content: Data(bytes))
    }
}
