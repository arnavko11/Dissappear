import CryptoKit
import Foundation

/// Apple ID authentication against Apple's Grand Slam service, the same
/// exchange Xcode performs when you sign in under Settings ▸ Accounts.
///
/// Credential handling rules this type keeps to:
/// * the password is passed in, used to derive the SRP proof, and never stored,
///   written to disk, or included in any log line;
/// * SRP means the password itself never travels to Apple;
/// * only the resulting tokens are persisted, and only in the Keychain.
///
/// Apple does not document this service. The request shapes below follow the
/// protocol as publicly understood; if Apple changes them, authentication fails
/// with a clear error and the Xcode signing path still works.
struct AppleIDAuthService {
    struct Session: Equatable {
        var appleID: String
        var adsid: String
        var idmsToken: String
        var xcodeToken: String
    }

    struct TwoFactorContext: Equatable {
        var appleID: String
        var adsid: String
        var idmsToken: String
    }

    enum Outcome: Equatable {
        case signedIn(Session)
        case twoFactorRequired(TwoFactorContext)
    }

    private let anisette = AnisetteProvider()
    private let session = URLSession(configuration: .ephemeral)

    // MARK: - Sign in

    func authenticate(appleID: String, password: String) async throws -> Outcome {
        var client = SRPClient(username: appleID)

        // One anisette set for the whole exchange: the one-time password and
        // the machine identifier are only valid together.
        let anisetteHeaders = try await anisette.headers()
        let clientData = anisette.clientProvidedData(from: anisetteHeaders)

        let initResponse = try await send(headers: anisetteHeaders, request: [
            "A2k": client.publicKey,
            "cpd": clientData,
            "o": "init",
            "ps": ["s2k", "s2k_fo"],
            "u": appleID
        ])

        try Self.checkStatus(in: initResponse)
        guard let salt = initResponse["s"] as? Data,
              let serverPublicKey = initResponse["B"] as? Data,
              let iterations = initResponse["i"] as? Int ?? initResponse["iteration"] as? Int,
              let cookie = initResponse["c"] as? String,
              let protocolName = initResponse["sp"] as? String,
              let passwordProtocol = SRPClient.PasswordProtocol(rawValue: protocolName) else {
            throw AppleIDError.protocolFailure("Apple's sign-in service returned an unexpected challenge.")
        }

        let proof = try client.processChallenge(password: password,
                                                salt: salt,
                                                iterations: iterations,
                                                serverPublicKey: serverPublicKey,
                                                protocol: passwordProtocol)

        let completeResponse = try await send(headers: anisetteHeaders, request: [
            "c": cookie,
            "M1": proof,
            "cpd": clientData,
            "o": "complete",
            "u": appleID
        ])

        try Self.checkStatus(in: completeResponse)
        if let serverProof = completeResponse["M2"] as? Data,
           !client.verifyServerProof(serverProof, clientProof: proof) {
            throw AppleIDError.protocolFailure("Apple's response could not be verified. Sign-in was stopped.")
        }

        guard let encrypted = completeResponse["spd"] as? Data else {
            throw AppleIDError.protocolFailure("Apple's sign-in service returned no session payload.")
        }
        let decrypted = try client.decryptSessionPayload(encrypted)
        guard let payload = try PropertyListSerialization.propertyList(from: decrypted, format: nil) as? [String: Any],
              let adsid = payload["adsid"] as? String,
              let idmsToken = payload["GsIdmsToken"] as? String else {
            throw AppleIDError.protocolFailure("Apple's session payload was not readable.")
        }

        let status = completeResponse["Status"] as? [String: Any] ?? [:]
        if let authType = status["au"] as? String,
           ["trustedDeviceSecondaryAuth", "secondaryAuth"].contains(authType) {
            let context = TwoFactorContext(appleID: appleID, adsid: adsid, idmsToken: idmsToken)
            try await requestVerificationCode(for: context)
            return .twoFactorRequired(context)
        }

        let sessionKey = payload["sk"] as? Data ?? Data()
        let checksumCookie = payload["c"] as? Data ?? Data()
        let xcodeToken = try await fetchXcodeToken(adsid: adsid,
                                                   idmsToken: idmsToken,
                                                   sessionKey: sessionKey,
                                                   cookie: checksumCookie,
                                                   clientData: clientData,
                                                   anisetteHeaders: anisetteHeaders)
        return .signedIn(Session(appleID: appleID, adsid: adsid, idmsToken: idmsToken, xcodeToken: xcodeToken))
    }

    /// Asks Apple to push a six-digit code to the account's trusted devices.
    func requestVerificationCode(for context: TwoFactorContext) async throws {
        var request = URLRequest(url: AppleIDEndpoint.trustedDevice)
        request.httpMethod = "GET"
        try await applyIdentityHeaders(to: &request, adsid: context.adsid, idmsToken: context.idmsToken)
        _ = try? await session.data(for: request)
    }

    /// Validates the code, then repeats the SRP exchange to collect tokens.
    func submitVerificationCode(_ code: String,
                                context: TwoFactorContext,
                                password: String) async throws -> Session {
        var request = URLRequest(url: AppleIDEndpoint.trustedDeviceCode)
        request.httpMethod = "POST"
        try await applyIdentityHeaders(to: &request, adsid: context.adsid, idmsToken: context.idmsToken)
        request.setValue(code, forHTTPHeaderField: "security-code")

        let (data, _) = try await session.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            try Self.checkStatus(in: ["Status": plist])
        }

        switch try await authenticate(appleID: context.appleID, password: password) {
        case let .signedIn(session):
            return session
        case .twoFactorRequired:
            throw AppleIDError.authenticationFailed(code: -1, message: "That verification code was not accepted.")
        }
    }

    // MARK: - Tokens

    private func fetchXcodeToken(adsid: String,
                                 idmsToken: String,
                                 sessionKey: Data,
                                 cookie: Data,
                                 clientData: [String: Any],
                                 anisetteHeaders: [String: String]) async throws -> String {
        let app = AnisetteProvider.xcodeSessionIdentifier
        let checksum = Data(HMAC<SHA256>.authenticationCode(
            for: Data("apptokens".utf8) + Data(adsid.utf8) + Data(app.utf8),
            using: SymmetricKey(data: sessionKey)))

        let response = try await send(headers: anisetteHeaders, request: [
            "app": [app],
            "c": cookie,
            "checksum": checksum,
            "cpd": clientData,
            "o": "apptokens",
            "t": idmsToken,
            "u": adsid
        ])
        try Self.checkStatus(in: response)

        guard let tokens = response["t"] as? [String: Any],
              let entry = tokens[app] as? [String: Any],
              let token = entry["token"] as? String else {
            throw AppleIDError.protocolFailure("Apple did not return a developer session token.")
        }
        return token
    }

    // MARK: - Transport

    private func send(headers anisetteHeaders: [String: String],
                      request body: [String: Any]) async throws -> [String: Any] {
        var urlRequest = URLRequest(url: AppleIDEndpoint.grandSlam)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.setValue("akd/1.0 CFNetwork/1494.0.7 Darwin/23.4.0", forHTTPHeaderField: "User-Agent")
        // Must be the client info from the same generation as the anisette
        // values in `cpd`, or Apple rejects the machine identifier.
        if let clientInfo = anisetteHeaders["X-Mme-Client-Info"] {
            urlRequest.setValue(clientInfo, forHTTPHeaderField: "X-MMe-Client-Info")
        }

        let envelope: [String: Any] = ["Header": ["Version": "1.0.1"], "Request": body]
        urlRequest.httpBody = try PropertyListSerialization.data(fromPropertyList: envelope, format: .xml, options: 0)

        let (data, response) = try await session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppleIDError.authenticationFailed(code: http.statusCode,
                                                    message: "Apple's sign-in service rejected the request.")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let inner = plist["Response"] as? [String: Any] else {
            throw AppleIDError.protocolFailure("Apple's sign-in service returned an unreadable response.")
        }
        return inner
    }

    private func applyIdentityHeaders(to request: inout URLRequest, adsid: String, idmsToken: String) async throws {
        for (key, value) in try await anisette.headers() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let identity = Data("\(adsid):\(idmsToken)".utf8).base64EncodedString()
        request.setValue(identity, forHTTPHeaderField: "X-Apple-Identity-Token")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue("Xcode", forHTTPHeaderField: "User-Agent")
    }

    private static func checkStatus(in response: [String: Any]) throws {
        guard let status = response["Status"] as? [String: Any] else { return }
        let code = status["ec"] as? Int ?? 0
        guard code != 0 else { return }
        let message = status["em"] as? String
            ?? status["ed"] as? String
            ?? "Apple rejected the sign-in request."
        throw AppleIDError.authenticationFailed(code: code, message: message)
    }
}

/// Token storage. The Apple ID password is never written here, or anywhere else.
enum AppleIDTokenStore {
    private static let service = "com.dissappear.companion.appleid"

    static func save(_ session: AppleIDAuthService.Session) {
        guard let data = try? JSONEncoder().encode(SessionRecord(session)) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: session.appleID]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(appleID: String) -> AppleIDAuthService.Session? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: appleID,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data) else { return nil }
        return record.session
    }

    static func clear(appleID: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: appleID]
        SecItemDelete(query as CFDictionary)
    }

    private struct SessionRecord: Codable {
        var appleID: String
        var adsid: String
        var idmsToken: String
        var xcodeToken: String

        init(_ session: AppleIDAuthService.Session) {
            appleID = session.appleID
            adsid = session.adsid
            idmsToken = session.idmsToken
            xcodeToken = session.xcodeToken
        }

        var session: AppleIDAuthService.Session {
            AppleIDAuthService.Session(appleID: appleID, adsid: adsid, idmsToken: idmsToken, xcodeToken: xcodeToken)
        }
    }
}
