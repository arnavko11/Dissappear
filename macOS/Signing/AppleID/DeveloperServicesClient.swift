import Foundation

struct DeveloperTeam: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var type: String
    var status: String

    var isFreeAccount: Bool { type.localizedCaseInsensitiveContains("individual") && status.isEmpty }
}

struct RegisteredDevice: Identifiable, Hashable, Sendable {
    var id: String
    var udid: String
    var name: String
}

struct DevelopmentCertificate: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var machineName: String
    var serialNumber: String
    var content: Data
}

struct DeveloperAppID: Identifiable, Hashable, Sendable {
    var id: String
    var identifier: String
    var name: String
}

/// Client for the developer service Xcode itself talks to when it manages
/// signing automatically. Every call is authorised by the token obtained during
/// Apple ID sign-in; no credentials are sent here.
struct DeveloperServicesClient {
    private static let clientID = "XABBG36SBA"
    private static let protocolVersion = "QH65B2"
    private static let xcodeVersion = "15.4 (15F31d)"

    let session: AppleIDAuthService.Session
    private let anisette = AnisetteProvider()
    private let transport = URLSession(configuration: .ephemeral)

    // MARK: - Teams

    func listTeams() async throws -> [DeveloperTeam] {
        let response = try await send(action: "listTeams.action", platform: false, body: [:])
        let teams = response["teams"] as? [[String: Any]] ?? []
        return teams.compactMap { entry in
            guard let id = entry["teamId"] as? String else { return nil }
            return DeveloperTeam(id: id,
                                 name: entry["name"] as? String ?? id,
                                 type: entry["type"] as? String ?? "",
                                 status: entry["status"] as? String ?? "")
        }
    }

    // MARK: - Devices

    func listDevices(teamID: String) async throws -> [RegisteredDevice] {
        let response = try await send(action: "ios/listDevices.action", body: ["teamId": teamID])
        let devices = response["devices"] as? [[String: Any]] ?? []
        return devices.compactMap { entry in
            guard let id = entry["deviceId"] as? String,
                  let udid = entry["deviceNumber"] as? String else { return nil }
            return RegisteredDevice(id: id, udid: udid, name: entry["name"] as? String ?? "Device")
        }
    }

    func addDevice(teamID: String, udid: String, name: String) async throws -> RegisteredDevice {
        let response = try await send(action: "ios/addDevice.action",
                                      body: ["teamId": teamID, "deviceNumber": udid, "name": name])
        guard let device = response["device"] as? [String: Any],
              let id = device["deviceId"] as? String else {
            throw AppleIDError.protocolFailure("Apple did not confirm the device registration.")
        }
        return RegisteredDevice(id: id, udid: udid, name: name)
    }

    // MARK: - Certificates

    func listCertificates(teamID: String) async throws -> [DevelopmentCertificate] {
        let response = try await send(action: "ios/listAllDevelopmentCerts.action", body: ["teamId": teamID])
        let certificates = response["certificates"] as? [[String: Any]] ?? []
        return certificates.compactMap(Self.certificate(from:))
    }

    func revokeCertificate(teamID: String, serialNumber: String) async throws {
        _ = try await send(action: "ios/revokeDevelopmentCert.action",
                           body: ["teamId": teamID, "serialNumber": serialNumber])
    }

    func submitCertificateRequest(teamID: String,
                                  csr: String,
                                  machineID: String,
                                  machineName: String) async throws -> DevelopmentCertificate {
        let response = try await send(action: "ios/submitDevelopmentCSR.action",
                                      body: ["teamId": teamID,
                                             "csrContent": csr,
                                             "machineId": machineID,
                                             "machineName": machineName])
        guard let request = response["certRequest"] as? [String: Any],
              let certificate = Self.certificate(from: request) else {
            throw AppleIDError.protocolFailure("Apple did not return a development certificate.")
        }
        return certificate
    }

    // MARK: - App IDs and profiles

    func listAppIDs(teamID: String) async throws -> [DeveloperAppID] {
        let response = try await send(action: "ios/listAppIds.action", body: ["teamId": teamID])
        let appIDs = response["appIds"] as? [[String: Any]] ?? []
        return appIDs.compactMap { entry in
            guard let id = entry["appIdId"] as? String,
                  let identifier = entry["identifier"] as? String else { return nil }
            return DeveloperAppID(id: id, identifier: identifier, name: entry["name"] as? String ?? identifier)
        }
    }

    func addAppID(teamID: String, identifier: String, name: String) async throws -> DeveloperAppID {
        let response = try await send(action: "ios/addAppId.action",
                                      body: ["teamId": teamID, "identifier": identifier, "name": name])
        guard let appID = response["appId"] as? [String: Any],
              let id = appID["appIdId"] as? String else {
            throw AppleIDError.protocolFailure("Apple did not create an App ID for this bundle identifier.")
        }
        return DeveloperAppID(id: id, identifier: identifier, name: name)
    }

    func downloadProvisioningProfile(teamID: String, appIDIdentifier: String) async throws -> Data {
        let response = try await send(action: "ios/downloadTeamProvisioningProfile.action",
                                      body: ["teamId": teamID, "appIdId": appIDIdentifier])
        guard let profile = response["provisioningProfile"] as? [String: Any],
              let data = profile["encodedProfile"] as? Data else {
            throw AppleIDError.protocolFailure("Apple did not return a provisioning profile.")
        }
        return data
    }

    // MARK: - Transport

    private static func certificate(from entry: [String: Any]) -> DevelopmentCertificate? {
        guard let id = entry["certificateId"] as? String else { return nil }
        let content = entry["certContent"] as? Data ?? entry["certificate"] as? Data ?? Data()
        return DevelopmentCertificate(id: id,
                                      name: entry["name"] as? String ?? "Apple Development",
                                      machineName: entry["machineName"] as? String ?? "",
                                      serialNumber: entry["serialNumber"] as? String ?? "",
                                      content: content)
    }

    private func send(action: String, platform: Bool = true, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: AppleIDEndpoint.developerServices.appendingPathComponent(action))
        request.httpMethod = "POST"
        for (key, value) in try anisette.headers() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.xcodeVersion, forHTTPHeaderField: "X-Xcode-Version")
        request.setValue(session.adsid, forHTTPHeaderField: "X-Apple-I-Identity-Id")
        request.setValue(session.xcodeToken, forHTTPHeaderField: "X-Apple-GS-Token")

        var payload: [String: Any] = body
        payload["clientId"] = Self.clientID
        payload["protocolVersion"] = Self.protocolVersion
        payload["requestId"] = UUID().uuidString.uppercased()
        payload["userLocale"] = [Locale.current.identifier]
        if platform { payload["DTDK_Platform"] = "ios" }
        request.httpBody = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)

        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AppleIDError.authenticationFailed(code: http.statusCode,
                                                    message: "Apple's developer service rejected the request.")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AppleIDError.protocolFailure("Apple's developer service returned an unreadable response.")
        }

        let code = plist["resultCode"] as? Int ?? 0
        guard code == 0 else {
            let message = plist["userString"] as? String
                ?? plist["resultString"] as? String
                ?? "The developer service returned error \(code)."
            throw AppleIDError.authenticationFailed(code: code, message: message)
        }
        return plist
    }
}
