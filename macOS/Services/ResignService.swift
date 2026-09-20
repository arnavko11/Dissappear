import Foundation

/// Re-signs a prebuilt iOS app with an Apple Development identity from the
/// user's keychain and a development provisioning profile they supply.
///
/// This is ordinary `codesign` use: Apple issues the certificate and the
/// profile, and the profile decides which devices may run the result. Nothing
/// here creates certificates, bypasses signing, or touches an Apple ID.
struct ResignService {
    struct Outcome: Equatable {
        var appURL: URL
        var bundleIdentifier: String
        var authority: String
    }

    private let runner = ProcessRunner.shared

    func resign(appURL: URL,
                identity: SigningIdentity,
                profileURL: URL,
                profile: ProvisioningProfile,
                onOutputLine: @escaping @Sendable (String) -> Void) async throws -> Outcome {
        let entitlements = try await writeEntitlements(for: profileURL)
        let bundleIdentifier = try await alignBundleIdentifier(of: appURL, to: profile, onOutputLine: onOutputLine)

        try embedProfile(profileURL, into: appURL)
        try removeExistingSignature(in: appURL)

        for nested in nestedCodeToSign(in: appURL) {
            onOutputLine("Signing \(nested.lastPathComponent)")
            try await sign(nested, identity: identity, entitlements: nil)
        }

        onOutputLine("Signing \(appURL.lastPathComponent)")
        try await sign(appURL, identity: identity, entitlements: entitlements)

        let verify = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", appURL.path])
        guard verify.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Verifying signature", result: verify)
        }

        let display = try await runner.run("/usr/bin/codesign", ["-dv", "--verbose=2", appURL.path])
        let authority = display.combinedOutput
            .split(separator: "\n")
            .first { $0.hasPrefix("Authority=") }
            .map { $0.replacingOccurrences(of: "Authority=", with: "") } ?? identity.commonName

        return Outcome(appURL: appURL, bundleIdentifier: bundleIdentifier, authority: authority)
    }

    // MARK: - Steps

    private func writeEntitlements(for profileURL: URL) async throws -> URL {
        let decoded = try await runner.run("/usr/bin/security", ["cms", "-D", "-i", profileURL.path])
        guard decoded.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: Data(decoded.standardOutput.utf8),
                                                                     format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            throw CompanionError(title: "Provisioning Profile Is Unreadable",
                                 details: "The selected profile does not contain entitlements.",
                                 recommendedAction: "Choose a development provisioning profile (.mobileprovision) that matches your team.",
                                 technicalDetails: decoded.combinedOutput)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A signed app's bundle identifier must match the profile's App ID.
    private func alignBundleIdentifier(of appURL: URL,
                                       to profile: ProvisioningProfile,
                                       onOutputLine: @escaping @Sendable (String) -> Void) async throws -> String {
        let infoPlist = appURL.appendingPathComponent("Info.plist")
        let current = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: infoPlist), format: nil) as? [String: Any])?["CFBundleIdentifier"] as? String ?? ""

        let suffix = String(profile.applicationIdentifier.drop { $0 != "." }.dropFirst())
        guard suffix != "*" else { return current }

        if suffix.hasSuffix(".*") {
            let prefix = String(suffix.dropLast(1))
            guard !current.hasPrefix(prefix) else { return current }
            let replacement = prefix + (current.split(separator: ".").last.map(String.init) ?? "app")
            try await setBundleIdentifier(replacement, in: infoPlist)
            onOutputLine("Bundle identifier set to \(replacement) to match the profile")
            return replacement
        }

        guard suffix != current else { return current }
        try await setBundleIdentifier(suffix, in: infoPlist)
        onOutputLine("Bundle identifier set to \(suffix) to match the profile")
        return suffix
    }

    private func setBundleIdentifier(_ identifier: String, in infoPlist: URL) async throws {
        let result = try await runner.run("/usr/bin/plutil",
                                          ["-replace", "CFBundleIdentifier", "-string", identifier, infoPlist.path])
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Updating bundle identifier", result: result)
        }
    }

    private func embedProfile(_ profileURL: URL, into appURL: URL) throws {
        let destination = appURL.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: profileURL, to: destination)
    }

    private func removeExistingSignature(in appURL: URL) throws {
        let signature = appURL.appendingPathComponent("_CodeSignature")
        if FileManager.default.fileExists(atPath: signature.path) {
            try FileManager.default.removeItem(at: signature)
        }
    }

    /// Frameworks and dylibs must be signed before the app that contains them.
    private func nestedCodeToSign(in appURL: URL) -> [URL] {
        let frameworks = appURL.appendingPathComponent("Frameworks", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { ["framework", "dylib"].contains($0.pathExtension) }
    }

    private func sign(_ url: URL, identity: SigningIdentity, entitlements: URL?) async throws {
        var arguments = ["--force", "--sign", identity.sha1, "--timestamp=none", "--generate-entitlement-der"]
        if let entitlements {
            arguments.append(contentsOf: ["--entitlements", entitlements.path])
        }
        arguments.append(url.path)

        let result = try await runner.run("/usr/bin/codesign", arguments)
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Code signing", result: result)
        }
    }
}
