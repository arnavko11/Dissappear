import Foundation

struct ProvisioningProfile: Identifiable, Hashable, Sendable {
    var id: String { uuid }
    var uuid: String
    var name: String
    var teamID: String
    var applicationIdentifier: String
    var expirationDate: Date
    var provisionedDeviceUDIDs: [String]
    var isDevelopment: Bool
    var fileURL: URL

    func matches(bundleIdentifier: String) -> Bool {
        let suffix = String(applicationIdentifier.drop { $0 != "." }.dropFirst())
        if suffix == "*" { return true }
        if suffix.hasSuffix(".*") {
            return bundleIdentifier.hasPrefix(String(suffix.dropLast(1)))
        }
        return suffix == bundleIdentifier
    }

    func includes(deviceUDID: String) -> Bool {
        provisionedDeviceUDIDs.contains { $0.caseInsensitiveCompare(deviceUDID) == .orderedSame }
    }
}

enum ProvisioningStatus: Equatable {
    case unknown
    case valid(ProvisioningProfile)
    case expiringSoon(ProvisioningProfile)
    case expired(ProvisioningProfile)
    case deviceNotRegistered
    case noProfile

    var profile: ProvisioningProfile? {
        switch self {
        case let .valid(profile), let .expiringSoon(profile), let .expired(profile): return profile
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .valid: return "Valid"
        case .expiringSoon: return "Expiring Soon"
        case .expired: return "Expired"
        case .deviceNotRegistered: return "Device Not Registered"
        case .noProfile: return "No Profile"
        }
    }
}
