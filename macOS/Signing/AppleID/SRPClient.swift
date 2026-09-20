import CommonCrypto
import CryptoKit
import Foundation

/// SRP-6a client for Apple's Grand Slam authentication, using the RFC 5054
/// 2048-bit group with SHA-256.
///
/// The password is used only to derive `x` and is never stored or logged.
/// SRP is a zero-knowledge exchange, so it is never sent to Apple either.
struct SRPClient {
    enum PasswordProtocol: String {
        case s2k
        case s2kFo = "s2k_fo"
    }

    private static let nHex = """
    AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4\
    A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF60\
    95179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF\
    747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B907\
    8717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861\
    60279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DB\
    FBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73
    """

    private let n: BigUInt
    private let g = BigUInt(2)
    private let k: BigUInt
    private let width: Int

    private let username: String
    private let a: BigUInt
    private let publicA: BigUInt

    private(set) var sessionKey = Data()

    init(username: String) {
        n = BigUInt(hex: Self.nHex) ?? BigUInt()
        width = (n.bitWidth + 7) / 8
        k = BigUInt(data: Data(SHA256.hash(data: n.serialize(paddedTo: width) + g.serialize(paddedTo: width))))
        self.username = username

        var secret = Data(count: 32)
        _ = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        a = BigUInt(data: secret)
        publicA = g.power(a, modulus: n)
    }

    /// The client's public ephemeral value, sent to Apple as `A2k`.
    var publicKey: Data { publicA.serialize(paddedTo: width) }

    /// Apple hashes the password before PBKDF2; `s2k_fo` hex-encodes that hash first.
    static func derivePasswordKey(password: String,
                                  salt: Data,
                                  iterations: Int,
                                  protocol passwordProtocol: PasswordProtocol) -> Data {
        var digest = Data(SHA256.hash(data: Data(password.utf8)))
        if passwordProtocol == .s2kFo {
            digest = Data(digest.map { String(format: "%02x", $0) }.joined().utf8)
        }

        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                digest.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                                         digest.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                         salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         UInt32(iterations),
                                         derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                         32)
                }
            }
        }
        return status == kCCSuccess ? derived : Data()
    }

    /// Processes the server challenge and returns the client proof `M1`.
    mutating func processChallenge(password: String,
                                   salt: Data,
                                   iterations: Int,
                                   serverPublicKey: Data,
                                   protocol passwordProtocol: PasswordProtocol) throws -> Data {
        let b = BigUInt(data: serverPublicKey)
        guard !(b % n).isZero else {
            throw AppleIDError.protocolFailure("The server sent an invalid public key.")
        }

        let passwordKey = Self.derivePasswordKey(password: password,
                                                 salt: salt,
                                                 iterations: iterations,
                                                 protocol: passwordProtocol)
        let inner = Data(SHA256.hash(data: Data(username.utf8) + Data(":".utf8) + passwordKey))
        let x = BigUInt(data: Data(SHA256.hash(data: salt + inner)))

        let u = BigUInt(data: Data(SHA256.hash(data: publicKey + b.serialize(paddedTo: width))))
        let kgx = (k * g.power(x, modulus: n)) % n
        let base = (b + n - kgx) % n          // keeps the subtraction non-negative
        let exponent = a + (u * x)
        let s = base.power(exponent, modulus: n)

        sessionKey = Data(SHA256.hash(data: s.serialize(paddedTo: width)))

        let hashN = Data(SHA256.hash(data: n.serialize(paddedTo: width)))
        let hashG = Data(SHA256.hash(data: g.serialize(paddedTo: width)))
        let xored = Data(zip(hashN, hashG).map { $0 ^ $1 })
        return Data(SHA256.hash(data: xored
            + Data(SHA256.hash(data: Data(username.utf8)))
            + salt
            + publicKey
            + b.serialize(paddedTo: width)
            + sessionKey))
    }

    /// Confirms the server proved knowledge of the verifier.
    func verifyServerProof(_ m2: Data, clientProof m1: Data) -> Bool {
        Data(SHA256.hash(data: publicKey + m1 + sessionKey)) == m2
    }

    /// Apple wraps the session payload in AES-CBC keyed from the session key.
    func decryptSessionPayload(_ payload: Data) throws -> Data {
        let key = Data(HMAC<SHA256>.authenticationCode(for: Data("extra data key:".utf8),
                                                       using: SymmetricKey(data: sessionKey)))
        let iv = Data(HMAC<SHA256>.authenticationCode(for: Data("extra data iv:".utf8),
                                                      using: SymmetricKey(data: sessionKey))).prefix(16)

        var output = Data(count: payload.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { payloadBytes in
                iv.withUnsafeBytes { ivBytes in
                    key.withUnsafeBytes { keyBytes in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress,
                                payloadBytes.baseAddress, payload.count,
                                outputBytes.baseAddress, output.count,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw AppleIDError.protocolFailure("The session payload could not be decrypted.")
        }
        return output.prefix(moved)
    }
}
