import Foundation

/// Development build metadata read from the signed bundle itself.
struct BuildInfo {
    var bundleIdentifier: String
    var version: String
    var build: String
    var profileName: String?
    var teamIdentifier: String?
    var expirationDate: Date?
    var isDevelopmentProfile: Bool

    var daysRemaining: Int? {
        guard let expirationDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
        return max(0, days)
    }

    static func current(bundle: Bundle = .main) -> BuildInfo {
        var info = BuildInfo(
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
            build: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "—",
            profileName: nil,
            teamIdentifier: nil,
            expirationDate: nil,
            isDevelopmentProfile: false)

        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let plist = Self.plist(inSignedProfile: data) else { return info }

        info.profileName = plist["Name"] as? String
        info.teamIdentifier = (plist["TeamIdentifier"] as? [String])?.first
        info.expirationDate = plist["ExpirationDate"] as? Date
        let entitlements = plist["Entitlements"] as? [String: Any]
        info.isDevelopmentProfile = (entitlements?["get-task-allow"] as? Bool) ?? false
        return info
    }

    /// The provisioning profile is CMS-wrapped; the embedded plist is extracted by range.
    private static func plist(inSignedProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards) else { return nil }
        let slice = data[start.lowerBound..<end.upperBound]
        return try? PropertyListSerialization.propertyList(from: slice, format: nil) as? [String: Any]
    }
}
