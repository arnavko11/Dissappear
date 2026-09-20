import Foundation

/// Turns an Apple ID sign-in into everything needed to sign a development
/// build: a registered device, a development certificate in the keychain, an
/// App ID, and a provisioning profile.
///
/// Every artefact is created by Apple through the same developer service Xcode
/// uses. Nothing here forges or bypasses any of them.
struct FreeProvisioningService {
    struct Result {
        var profileURL: URL
        var profile: ProvisioningProfile
        var identity: SigningIdentity
        var bundleIdentifier: String
    }

    private let signingService = SigningService()
    private let csrBuilder = CertificateSigningRequest()

    func provision(session: AppleIDAuthService.Session,
                   team: DeveloperTeam,
                   device: Device,
                   baseBundleIdentifier: String,
                   onProgress: @escaping @Sendable (String) -> Void) async throws -> Result {
        let client = DeveloperServicesClient(session: session)

        // 1. The device must be registered with the team before a profile can include it.
        onProgress("Checking device registration")
        let registered = try await client.listDevices(teamID: team.id)
        if !registered.contains(where: { $0.udid.caseInsensitiveCompare(device.udid) == .orderedSame }) {
            onProgress("Registering \(device.name) with team \(team.name)")
            _ = try await client.addDevice(teamID: team.id, udid: device.udid, name: device.name)
        }

        // 2. Reuse an existing certificate when its private key is still here.
        let identity = try await developmentIdentity(client: client, team: team, session: session, onProgress: onProgress)

        // 3. Free accounts need a bundle identifier unique to the team.
        let bundleIdentifier = "\(baseBundleIdentifier).\(team.id.lowercased())"
        onProgress("Preparing App ID \(bundleIdentifier)")
        let appIDs = try await client.listAppIDs(teamID: team.id)
        let appID: DeveloperAppID
        if let existing = appIDs.first(where: { $0.identifier == bundleIdentifier }) {
            appID = existing
        } else {
            appID = try await client.addAppID(teamID: team.id,
                                              identifier: bundleIdentifier,
                                              name: "Dissappear Location Tester")
        }

        // 4. Download the profile Apple generates for that App ID and team.
        onProgress("Downloading provisioning profile")
        let data = try await client.downloadProvisioningProfile(teamID: team.id, appIDIdentifier: appID.id)

        let directory = try profilesDirectory()
        let url = directory.appendingPathComponent("\(bundleIdentifier).mobileprovision")
        try data.write(to: url, options: .atomic)

        guard let profile = await signingService.profile(at: url) else {
            throw AppleIDError.protocolFailure("The downloaded provisioning profile could not be read.")
        }
        guard profile.includes(deviceUDID: device.udid) else {
            throw AppleIDError.protocolFailure("Apple issued a profile that does not list this device. Try again in a moment.")
        }

        return Result(profileURL: url, profile: profile, identity: identity, bundleIdentifier: bundleIdentifier)
    }

    // MARK: - Certificate

    private func developmentIdentity(client: DeveloperServicesClient,
                                     team: DeveloperTeam,
                                     session: AppleIDAuthService.Session,
                                     onProgress: @escaping @Sendable (String) -> Void) async throws -> SigningIdentity {
        if let existing = try? await signingService.developmentIdentities().first(where: { $0.teamID == team.id }),
           csrBuilder.existingKeyPair() != nil {
            onProgress("Using existing certificate \(existing.commonName)")
            return existing
        }

        onProgress("Requesting a development certificate")
        let keyPair = try csrBuilder.existingKeyPair() ?? csrBuilder.generateKeyPair()
        let machineName = Host.current().localizedName ?? "Mac"
        let request = try csrBuilder.makeRequest(keyPair: keyPair,
                                                 commonName: "Dissappear Companion",
                                                 emailAddress: session.appleID)

        let certificate = try await client.submitCertificateRequest(teamID: team.id,
                                                                    csr: request,
                                                                    machineID: Self.machineIdentifier,
                                                                    machineName: machineName)
        guard !certificate.content.isEmpty else {
            throw AppleIDError.protocolFailure("Apple returned an empty certificate.")
        }
        try csrBuilder.importCertificate(certificate.content)
        onProgress("Certificate issued and added to your keychain")

        guard let identity = try await signingService.developmentIdentities().first(where: { $0.teamID == team.id }) else {
            throw AppleIDError.protocolFailure("The new certificate is not usable as a signing identity yet. Open Keychain Access to confirm it imported.")
        }
        return identity
    }

    /// Stable per-Mac identifier so repeated runs reuse the same certificate
    /// slot rather than exhausting the account's limit.
    private static var machineIdentifier: String {
        let key = "appleIDMachineIdentifier"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private func profilesDirectory() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DissappearCompanion/Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }
}
