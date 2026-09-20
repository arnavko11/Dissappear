import Foundation

/// Tools that can install a signed build on a device. All are either Apple's
/// own or well-known open source; none are bundled with this app.
enum InstallBackend: String, CaseIterable, Identifiable, Sendable {
    case devicectl
    case cfgutil
    case ideviceinstaller

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .devicectl: return "devicectl (Xcode)"
        case .cfgutil: return "Apple Configurator"
        case .ideviceinstaller: return "ideviceinstaller"
        }
    }

    var requirement: String {
        switch self {
        case .devicectl:
            return "Included with Xcode."
        case .cfgutil:
            return "Install Apple Configurator from the Mac App Store, then choose Apple Configurator ▸ Install Automation Tools."
        case .ideviceinstaller:
            return "Install the open source libimobiledevice tools, for example with Homebrew: brew install ideviceinstaller."
        }
    }

    /// Candidate locations. A GUI app does not inherit a shell PATH, so the
    /// usual install locations are checked directly.
    var candidatePaths: [String] {
        switch self {
        case .devicectl:
            return []
        case .cfgutil:
            return ["/usr/local/bin/cfgutil", "/opt/homebrew/bin/cfgutil",
                    "/Applications/Apple Configurator.app/Contents/MacOS/cfgutil"]
        case .ideviceinstaller:
            return ["/opt/homebrew/bin/ideviceinstaller", "/usr/local/bin/ideviceinstaller"]
        }
    }

    var supportsLaunch: Bool { self == .devicectl }
}

struct ResolvedTool: Equatable, Sendable {
    var backend: InstallBackend
    var executablePath: String
}

struct DeviceToolingService {
    private let runner = ProcessRunner.shared

    /// Ordered by preference: Apple's own tooling first.
    func availableTools() async -> [ResolvedTool] {
        var tools: [ResolvedTool] = []

        if let found = try? await runner.run("/usr/bin/xcrun", ["--find", "devicectl"]), found.succeeded {
            let path = found.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                tools.append(ResolvedTool(backend: .devicectl, executablePath: path))
            }
        }

        for backend in [InstallBackend.cfgutil, .ideviceinstaller] {
            if let path = backend.candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                tools.append(ResolvedTool(backend: backend, executablePath: path))
            }
        }
        return tools
    }

    /// Device listing that does not need Xcode, used when devicectl is absent.
    func devicesFromLibimobiledevice() async -> [Device] {
        let idevice_id = ["/opt/homebrew/bin/idevice_id", "/usr/local/bin/idevice_id"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let ideviceinfo = ["/opt/homebrew/bin/ideviceinfo", "/usr/local/bin/ideviceinfo"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let idevice_id else { return [] }

        guard let listed = try? await runner.run(idevice_id, ["-l"]), listed.succeeded else { return [] }
        let udids = listed.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var devices: [Device] = []
        for udid in udids {
            var name = "iPhone", version = "", product = "", build = ""
            if let ideviceinfo {
                for (key, target) in [("DeviceName", 0), ("ProductVersion", 1), ("ProductType", 2), ("BuildVersion", 3)] {
                    guard let value = try? await runner.run(ideviceinfo, ["-u", udid, "-k", key]), value.succeeded else { continue }
                    let text = value.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch target {
                    case 0: name = text.isEmpty ? name : text
                    case 1: version = text
                    case 2: product = text
                    default: build = text
                    }
                }
            }
            devices.append(Device(udid: udid,
                                  identifier: udid,
                                  name: name,
                                  marketingName: "",
                                  productType: product,
                                  platform: "iOS",
                                  osVersion: version,
                                  osBuild: build,
                                  developerMode: .unknown,
                                  connection: .connected,
                                  transport: "usb"))
        }
        return devices
    }
}
