import Foundation

/// Reads signing identities and provisioning profiles that Apple's tooling has
/// already created. The companion never creates certificates itself and never
/// asks for an Apple ID password — Xcode owns that flow.
struct SigningService {
    private let runner = ProcessRunner.shared

    private static let profileDirectories = [
        "Library/Developer/Xcode/UserData/Provisioning Profiles",
        "Library/MobileDevice/Provisioning Profiles"
    ]

    func developmentIdentities() async throws -> [SigningIdentity] {
        let result = try await runner.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Reading signing identities", result: result)
        }
        return Self.parseIdentities(result.standardOutput).filter(\.isDevelopment)
    }

    static func parseIdentities(_ output: String) -> [SigningIdentity] {
        output.split(separator: "\n").compactMap { line in
            guard let quoteStart = line.firstIndex(of: "\""),
                  let quoteEnd = line.lastIndex(of: "\""),
                  quoteStart < quoteEnd else { return nil }
            let name = String(line[line.index(after: quoteStart)..<quoteEnd])
            let prefix = line[line.startIndex..<quoteStart]
            let sha1 = prefix.split(separator: " ").first { $0.count == 40 }.map(String.init) ?? ""
            guard !sha1.isEmpty else { return nil }

            var team = ""
            if let open = name.lastIndex(of: "("), let close = name.lastIndex(of: ")"), open < close {
                team = String(name[name.index(after: open)..<close])
            }
            return SigningIdentity(sha1: sha1, commonName: name, teamID: team)
        }
    }

    func provisioningProfiles() async -> [ProvisioningProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []
        for directory in Self.profileDirectories {
            let url = home.appendingPathComponent(directory, isDirectory: true)
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            urls.append(contentsOf: contents.filter { $0.pathExtension == "mobileprovision" })
        }

        var profiles: [ProvisioningProfile] = []
        for url in urls {
            guard let decoded = try? await runner.run("/usr/bin/security", ["cms", "-D", "-i", url.path]),
                  decoded.succeeded,
                  let profile = Self.parseProfile(Data(decoded.standardOutput.utf8), fileURL: url) else { continue }
            profiles.append(profile)
        }
        return profiles.sorted { $0.expirationDate > $1.expirationDate }
    }

    static func parseProfile(_ data: Data, fileURL: URL) -> ProvisioningProfile? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let uuid = plist["UUID"] as? String,
              let expiration = plist["ExpirationDate"] as? Date else { return nil }

        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        return ProvisioningProfile(uuid: uuid,
                                   name: plist["Name"] as? String ?? uuid,
                                   teamID: (plist["TeamIdentifier"] as? [String])?.first ?? "",
                                   applicationIdentifier: entitlements["application-identifier"] as? String ?? "",
                                   expirationDate: expiration,
                                   provisionedDeviceUDIDs: plist["ProvisionedDevices"] as? [String] ?? [],
                                   isDevelopment: (entitlements["get-task-allow"] as? Bool) ?? false,
                                   fileURL: fileURL)
    }

    /// Reads a single profile the user picked from disk.
    func profile(at url: URL) async -> ProvisioningProfile? {
        guard let decoded = try? await runner.run("/usr/bin/security", ["cms", "-D", "-i", url.path]),
              decoded.succeeded else { return nil }
        return Self.parseProfile(Data(decoded.standardOutput.utf8), fileURL: url)
    }

    func provisioningStatus(bundleIdentifier: String,
                            teamID: String?,
                            deviceUDID: String?,
                            profiles: [ProvisioningProfile]) -> ProvisioningStatus {
        let candidates = profiles.filter { profile in
            guard profile.isDevelopment, profile.matches(bundleIdentifier: bundleIdentifier) else { return false }
            if let teamID, !teamID.isEmpty, profile.teamID != teamID { return false }
            return true
        }
        guard !candidates.isEmpty else { return .noProfile }

        if let deviceUDID {
            let registered = candidates.filter { $0.includes(deviceUDID: deviceUDID) }
            guard let best = registered.first else { return .deviceNotRegistered }
            return Self.classify(best)
        }
        return Self.classify(candidates[0])
    }

    private static func classify(_ profile: ProvisioningProfile) -> ProvisioningStatus {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: profile.expirationDate).day ?? -1
        if days < 0 { return .expired(profile) }
        if days <= 2 { return .expiringSoon(profile) }
        return .valid(profile)
    }
}
