import Foundation

struct DeviceDiscovery {
    var devices: [Device]
    var command: String
    var exitCode: Int32
    var output: String
    /// Apple devices seen on the USB bus, even when devicectl reports nothing.
    var usbDeviceNames: [String] = []

    var succeeded: Bool { exitCode == 0 }
}

/// Device discovery through `xcrun devicectl`, Apple's supported CLI for
/// connected development devices.
struct DeviceService {
    private let runner = ProcessRunner.shared

    /// Never throws: discovery problems are reported so the UI can explain them.
    func discover() async -> DeviceDiscovery {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dissappear-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let arguments = ["devicectl", "list", "devices", "--timeout", "10", "--json-output", output.path]
        let command = "xcrun " + arguments.joined(separator: " ")

        let result: ProcessResult
        do {
            result = try await runner.xcrun(arguments)
        } catch {
            return DeviceDiscovery(devices: [],
                                   command: command,
                                   exitCode: -1,
                                   output: error.localizedDescription)
        }

        guard result.succeeded, let data = try? Data(contentsOf: output) else {
            return DeviceDiscovery(devices: [],
                                   command: command,
                                   exitCode: result.exitCode,
                                   output: result.combinedOutput)
        }

        let devices = Self.parse(data)
        return DeviceDiscovery(devices: devices,
                               command: command,
                               exitCode: result.exitCode,
                               output: result.combinedOutput.isEmpty
                                   ? "Reported \(devices.count) device(s)."
                                   : result.combinedOutput)
    }

    /// Reads the USB bus so the app can tell "no iPhone attached" apart from
    /// "iPhone attached but Xcode's tooling cannot see it".
    func attachedAppleDeviceNames() async -> [String] {
        guard let result = try? await runner.run("/usr/sbin/system_profiler", ["SPUSBDataType", "-json"]),
              result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var names: [String] = []
        func walk(_ value: Any) {
            if let array = value as? [Any] {
                array.forEach(walk)
            } else if let node = value as? [String: Any] {
                if let name = node["_name"] as? String,
                   ["iphone", "ipad", "ipod"].contains(where: { name.lowercased().contains($0) }) {
                    names.append(name)
                }
                node.values.forEach(walk)
            }
        }
        walk(root)
        return Array(Set(names)).sorted()
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

            // A paired device is usable. The tunnel is opened on demand by the
            // tools themselves, so its state is reported separately rather than
            // treated as a connection failure.
            let state: DeviceConnectionState
            if pairing == "unpaired" || pairing == "pairingrequested" {
                state = .pairingNeeded
            } else {
                state = .connected
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
                          transport: connection["transportType"] as? String ?? "",
                          tunnelState: tunnel)
        }
    }
}
