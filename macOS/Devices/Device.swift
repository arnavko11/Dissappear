import Foundation

enum DeveloperModeStatus: String, Sendable {
    case enabled
    case disabled
    case restricted
    case unknown

    init(rawValueOrUnknown raw: String?) {
        self = DeveloperModeStatus(rawValue: (raw ?? "").lowercased()) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        case .restricted: return "Restricted"
        case .unknown: return "Unknown"
        }
    }
}

enum DeviceConnectionState: String, Sendable {
    case connected
    case unavailable
    case pairingNeeded

    var displayName: String {
        switch self {
        case .connected: return "Connected"
        case .unavailable: return "Unavailable"
        case .pairingNeeded: return "Trust Required"
        }
    }
}

struct Device: Identifiable, Hashable, Sendable {
    var id: String { udid }
    var udid: String
    var identifier: String
    var name: String
    var marketingName: String
    var productType: String
    var platform: String
    var osVersion: String
    var osBuild: String
    var developerMode: DeveloperModeStatus
    var connection: DeviceConnectionState
    var transport: String

    var isPhysicalIOSDevice: Bool {
        platform.lowercased().contains("ios") || platform.lowercased().contains("iphone")
    }

    var displayModel: String {
        marketingName.isEmpty ? productType : marketingName
    }
}
