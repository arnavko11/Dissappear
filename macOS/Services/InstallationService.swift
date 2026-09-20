import Foundation

/// Installs, launches and removes the development build with `devicectl`.
struct InstallationService {
    private let runner = ProcessRunner.shared

    func install(product: BuildProduct,
                 on device: Device,
                 onOutputLine: @escaping @Sendable (String) -> Void) async throws {
        let result = try await runner.xcrun(["devicectl", "device", "install", "app",
                                             "--device", device.udid,
                                             product.appURL.path],
                                            onOutputLine: onOutputLine)
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Installation", result: result)
        }
    }

    func launch(bundleIdentifier: String, on device: Device) async throws {
        let result = try await runner.xcrun(["devicectl", "device", "process", "launch",
                                             "--device", device.udid,
                                             "--terminate-existing",
                                             bundleIdentifier])
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Launch", result: result)
        }
    }

    func uninstall(bundleIdentifier: String, from device: Device) async throws {
        let result = try await runner.xcrun(["devicectl", "device", "uninstall", "app",
                                             "--device", device.udid,
                                             bundleIdentifier])
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Remove", result: result)
        }
    }

    func installedApps(on device: Device) async throws -> [InstalledApp] {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dissappear-apps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await runner.xcrun(["devicectl", "device", "info", "apps",
                                             "--device", device.udid,
                                             "--json-output", output.path])
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Reading installed apps", result: result)
        }
        guard let data = try? Data(contentsOf: output) else { return [] }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> [InstalledApp] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]] else { return [] }

        return apps.compactMap { entry in
            guard let bundleID = entry["bundleIdentifier"] as? String else { return nil }
            return InstalledApp(bundleIdentifier: bundleID,
                                name: entry["name"] as? String ?? entry["bundleIdentifier"] as? String ?? bundleID,
                                version: entry["version"] as? String ?? entry["bundleVersion"] as? String ?? "—",
                                installationURL: entry["url"] as? String)
        }
    }
}
