import Foundation

/// Device discovery through `xcrun devicectl`, Apple's supported CLI for
/// connected development devices.
struct DeviceService {
    private let runner = ProcessRunner.shared

    func connectedDevices() async throws -> [Device] {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dissappear-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await runner.xcrun(["devicectl", "list", "devices", "--timeout", "10", "--json-output", output.path])
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Device discovery", result: result)
        }
        guard let data = try? Data(contentsOf: output) else { return [] }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }

        return devices.compactMap { entry in
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = entry["deviceProperties"] as? [String: Any] ?? [:]
            let connection = entry["connectionProperties"] as? [String: Any] ?? [:]
            guard let udid = hardware["udid"] as? String else { return nil }

            let pairing = (connection["pairingState"] as? String ?? "").lowercased()
            let tunnel = (connection["tunnelState"] as? String ?? "").lowercased()
            let state: DeviceConnectionState
            if pairing == "paired" && (tunnel == "connected" || tunnel == "available") {
                state = .connected
            } else if pairing.isEmpty || pairing == "unpaired" || pairing == "pairingrequested" {
                state = .pairingNeeded
            } else {
                state = .unavailable
            }

            return Device(udid: udid,
                          identifier: entry["identifier"] as? String ?? udid,
                          name: properties["name"] as? String ?? hardware["marketingName"] as? String ?? "iPhone",
                          marketingName: hardware["marketingName"] as? String ?? "",
                          productType: hardware["productType"] as? String ?? "",
                          platform: hardware["platform"] as? String ?? "iOS",
                          osVersion: properties["osVersionNumber"] as? String ?? "",
                          osBuild: properties["osBuildUpdate"] as? String ?? "",
                          developerMode: DeveloperModeStatus(rawValueOrUnknown: properties["developerModeStatus"] as? String),
                          connection: state,
                          transport: connection["transportType"] as? String ?? "")
        }
    }
}
