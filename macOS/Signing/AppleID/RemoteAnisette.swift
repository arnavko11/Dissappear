import CryptoKit
import Foundation

/// A client for the anisette servers the sideloading community runs
/// (anisette-v3-server and compatible), which stand in for the anisette macOS
/// no longer hands to unentitled apps.
///
/// v3 is a protocol, not a single request. Asking `/v3/get_headers` with an
/// identifier the server has never provisioned only returns
/// `GetHeadersError` — which is all the old code ever did, so no v3 server
/// could work. The full flow, as the server's source implements it:
///
/// 1. `GET /v3/client_info` — the client info and user agent to present.
/// 2. Provision once: `GET` Apple's GsService2 `lookup` for the provisioning
///    URLs, then a WebSocket to `/v3/provisioning_session`. The server asks
///    for our identifier, then for `spim` (from Apple's midStartProvisioning),
///    returns `cpim`, asks for `ptm`/`tk` (from Apple's midFinishProvisioning
///    given that `cpim`), and answers with `adi_pb`.
/// 3. `POST /v3/get_headers` with the identifier and `adi_pb` for each set.
///
/// The provisioning is kept per server, so step 2 happens once. Servers that
/// only speak v1 answer a plain `GET /` with a header set, used as fallback.
struct RemoteAnisette {
    let server: URL

    private struct Provisioning: Codable {
        var identifier: String      // base64 of 16 random bytes
        var adiPB: String           // base64, from ProvisioningSuccess
        var deviceID: String
        var localUserID: String
        var clientInfo: String
        var userAgent: String
    }

    private static let session = URLSession(configuration: .ephemeral)
    private static let lookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!

    func headers() async throws -> [String: String] {
        do {
            return try await v3Headers()
        } catch let v3Failure {
            if let v1 = try? await v1Headers() { return v1 }
            throw v3Failure
        }
    }

    // MARK: - v3

    private func v3Headers() async throws -> [String: String] {
        var provisioning = try await storedOrNewProvisioning()
        do {
            return try await fetchHeaders(with: provisioning)
        } catch RemoteFailure.notProvisioned {
            // The server forgot this machine (they are wiped now and then).
            Self.forget(server)
            provisioning = try await provision()
            return try await fetchHeaders(with: provisioning)
        }
    }

    private enum RemoteFailure: Error { case notProvisioned }

    private func fetchHeaders(with provisioning: Provisioning) async throws -> [String: String] {
        var request = URLRequest(url: endpoint("v3/get_headers"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": provisioning.identifier,
            "adi_pb": provisioning.adiPB
        ])
        let (data, _) = try await Self.session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("returned something that is not anisette data to /v3/get_headers")
        }
        guard (json["result"] as? String) == "Headers",
              let md = json["X-Apple-I-MD"] as? String,
              let machine = json["X-Apple-I-MD-M"] as? String else {
            if (json["result"] as? String) == "GetHeadersError" { throw RemoteFailure.notProvisioned }
            throw failure("answered /v3/get_headers with \(json["message"] as? String ?? json["result"] as? String ?? "an error")")
        }
        var headers = baseHeaders(provisioning)
        headers["X-Apple-I-MD"] = md
        headers["X-Apple-I-MD-M"] = machine
        headers["X-Apple-I-MD-RINFO"] = (json["X-Apple-I-MD-RINFO"] as? String) ?? "17106176"
        return headers
    }

    private func storedOrNewProvisioning() async throws -> Provisioning {
        if let stored = Self.stored(for: server) { return stored }
        return try await provision()
    }

    private func provision() async throws -> Provisioning {
        // 1. What to present as.
        let (infoData, _) = try await Self.session.data(from: endpoint("v3/client_info"))
        guard let info = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
              let clientInfo = info["client_info"] as? String else {
            throw failure("does not speak anisette v3 (no /v3/client_info)")
        }
        let userAgent = info["user_agent"] as? String ?? "akd/1.0 CFNetwork/808.1.4"

        var raw = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        let identifier = Data(raw).base64EncodedString()
        let localUserID = SHA256.hash(data: Data(identifier.utf8))
            .map { String(format: "%02X", $0) }.joined()
        var provisioning = Provisioning(identifier: identifier, adiPB: "",
                                        deviceID: UUID().uuidString.uppercased(),
                                        localUserID: localUserID,
                                        clientInfo: clientInfo, userAgent: userAgent)

        // 2. Where Apple wants the provisioning requests.
        let lookup = try await apple(Self.lookupURL, method: "GET", body: nil, provisioning)
        guard let urls = lookup["urls"] as? [String: Any],
              let startString = urls["midStartProvisioning"] as? String, let start = URL(string: startString),
              let finishString = urls["midFinishProvisioning"] as? String, let finish = URL(string: finishString) else {
            throw AppleIDError.anisetteUnavailable("Apple's provisioning lookup did not return its URLs.")
        }

        // 3. The server drives the exchange; Apple supplies spim, ptm and tk.
        var components = URLComponents(url: endpoint("v3/provisioning_session"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let socket = Self.session.webSocketTask(with: components.url!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        while true {
            let message = try await receive(socket)
            switch message["result"] as? String {
            case "GiveIdentifier":
                try await send(["identifier": identifier], on: socket)
            case "GiveStartProvisioningData":
                let response = try await apple(start, method: "POST", body: [:], provisioning)
                guard let spim = (response["Response"] as? [String: Any])?["spim"] as? String else {
                    throw AppleIDError.anisetteUnavailable("Apple's start-provisioning reply had no spim.")
                }
                try await send(["spim": spim], on: socket)
            case "GiveEndProvisioningData":
                guard let cpim = message["cpim"] as? String else {
                    throw failure("sent no cpim during provisioning")
                }
                let response = try await apple(finish, method: "POST", body: ["cpim": cpim], provisioning)
                guard let inner = response["Response"] as? [String: Any],
                      let ptm = inner["ptm"] as? String, let tk = inner["tk"] as? String else {
                    throw AppleIDError.anisetteUnavailable("Apple's finish-provisioning reply had no ptm/tk.")
                }
                try await send(["ptm": ptm, "tk": tk], on: socket)
            case "ProvisioningSuccess":
                guard let adiPB = message["adi_pb"] as? String else {
                    throw failure("reported success without adi_pb")
                }
                provisioning.adiPB = adiPB
                Self.store(provisioning, for: server)
                return provisioning
            case let other:
                throw failure("stopped provisioning: \(message["message"] as? String ?? other ?? "no reason given")")
            }
        }
    }

    /// Calls Apple's provisioning endpoints as the machine the server emulates.
    private func apple(_ url: URL, method: String, body: [String: Any]?,
                       _ provisioning: Provisioning) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        for (key, value) in baseHeaders(provisioning) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(provisioning.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let body {
            let envelope: [String: Any] = ["Header": [String: Any](), "Request": body]
            request.httpBody = try PropertyListSerialization.data(fromPropertyList: envelope, format: .xml, options: 0)
        }
        let (data, _) = try await Self.session.data(for: request)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppleIDError.anisetteUnavailable("Apple's provisioning service returned an unreadable reply.")
        }
        return plist
    }

    private func baseHeaders(_ provisioning: Provisioning) -> [String: String] {
        [
            "X-Mme-Client-Info": provisioning.clientInfo,
            "X-Mme-Device-Id": provisioning.deviceID,
            "X-Apple-I-MD-LU": provisioning.localUserID,
            "X-Apple-I-SRL-NO": "0",
            "X-Apple-I-Client-Time": ISO8601DateFormatter().string(from: Date()),
            "X-Apple-I-TimeZone": TimeZone.current.abbreviation() ?? "UTC",
            "X-Apple-Locale": "en_US",
        ]
    }

    // MARK: - v1

    private func v1Headers() async throws -> [String: String] {
        var request = URLRequest(url: server)
        request.timeoutInterval = 15
        let (data, _) = try await Self.session.data(for: request)
        guard let headers = AnisetteProvider.parse(data) else {
            throw failure("returned no anisette data")
        }
        return headers
    }

    // MARK: - Plumbing

    private func endpoint(_ path: String) -> URL {
        let base = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/\(path)")!
    }

    private func send(_ payload: [String: String], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let text: String
        switch try await socket.receive() {
        case let .string(string): text = string
        case let .data(data): text = String(decoding: data, as: UTF8.self)
        @unknown default: text = ""
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw failure("sent an unreadable provisioning message")
        }
        return json
    }

    private func failure(_ what: String) -> AppleIDError {
        .anisetteUnavailable("The anisette server \(server.host ?? server.absoluteString) \(what).")
    }

    private static func key(for server: URL) -> String { "anisette.v3.\(server.absoluteString)" }

    private static func stored(for server: URL) -> Provisioning? {
        guard let data = UserDefaults.standard.data(forKey: key(for: server)) else { return nil }
        return try? JSONDecoder().decode(Provisioning.self, from: data)
    }

    private static func store(_ provisioning: Provisioning, for server: URL) {
        UserDefaults.standard.set(try? JSONEncoder().encode(provisioning), forKey: key(for: server))
    }

    static func forget(_ server: URL) {
        UserDefaults.standard.removeObject(forKey: key(for: server))
    }
}
