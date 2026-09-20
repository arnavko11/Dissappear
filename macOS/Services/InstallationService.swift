import Foundation

/// Installs, launches and removes the development build using whichever
/// supported tool is present: Apple's devicectl or Apple Configurator, or the
/// open source libimobiledevice tools.
struct InstallationService {
    private let runner = ProcessRunner.shared

    /// Wraps a signed .app as an .ipa for the tools that expect one.
    func package(appURL: URL) async throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("DissappearPackage-\(UUID().uuidString)", isDirectory: true)
        let payload = staging.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: appURL, to: payload.appendingPathComponent(appURL.lastPathComponent))

        let ipa = staging.appendingPathComponent("\(appURL.deletingPathExtension().lastPathComponent).ipa")
        let result = try await runner.run("/usr/bin/ditto", ["-c", "-k", payload.path, ipa.path])
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Packaging build", result: result)
        }
        return ipa
    }

    private func resolvedArchive(_ ipaURL: URL?, appURL: URL) async throws -> URL {
        if let ipaURL { return ipaURL }
        return try await package(appURL: appURL)
    }

    func install(appURL: URL,
                 ipaURL: URL?,
                 on device: Device,
                 using tool: ResolvedTool,
                 onOutputLine: @escaping @Sendable (String) -> Void) async throws {
        let result: ProcessResult
        switch tool.backend {
        case .devicectl:
            result = try await runner.run(tool.executablePath,
                                          ["device", "install", "app", "--device", device.udid, appURL.path],
                                          onOutputLine: onOutputLine)
        case .cfgutil:
            let ipa = try await resolvedArchive(ipaURL, appURL: appURL)
            result = try await runner.run(tool.executablePath,
                                          ["install-app", ipa.path],
                                          onOutputLine: onOutputLine)
        case .ideviceinstaller:
            let ipa = try await resolvedArchive(ipaURL, appURL: appURL)
            result = try await runner.run(tool.executablePath,
                                          ["-u", device.udid, "-i", ipa.path],
                                          onOutputLine: onOutputLine)
        }

        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Installation", result: result)
        }
    }

    func launch(bundleIdentifier: String, on device: Device, using tool: ResolvedTool) async throws {
        guard tool.backend == .devicectl else {
            throw CompanionError(title: "Launching Needs Xcode",
                                 details: "\(tool.backend.displayName) can install the app but cannot launch it.",
                                 recommendedAction: "Open the app from the Home Screen on \(device.name).",
                                 technicalDetails: "launch is only implemented by devicectl")
        }
        let result = try await runner.run(tool.executablePath,
                                          ["device", "process", "launch",
                                           "--device", device.udid,
                                           "--terminate-existing",
                                           bundleIdentifier])
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Launch", result: result)
        }
    }

    func uninstall(bundleIdentifier: String, from device: Device, using tool: ResolvedTool) async throws {
        let result: ProcessResult
        switch tool.backend {
        case .devicectl:
            result = try await runner.run(tool.executablePath,
                                          ["device", "uninstall", "app", "--device", device.udid, bundleIdentifier])
        case .cfgutil:
            result = try await runner.run(tool.executablePath, ["remove-app", bundleIdentifier])
        case .ideviceinstaller:
            result = try await runner.run(tool.executablePath, ["-u", device.udid, "-U", bundleIdentifier])
        }
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Remove", result: result)
        }
    }

    /// Installed-app listing is only available through devicectl.
    func installedApps(on device: Device, using tool: ResolvedTool) async throws -> [InstalledApp] {
        guard tool.backend == .devicectl else { return [] }

        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dissappear-apps-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await runner.run(tool.executablePath,
                                          ["device", "info", "apps", "--device", device.udid,
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
                                name: entry["name"] as? String ?? bundleID,
                                version: entry["version"] as? String ?? entry["bundleVersion"] as? String ?? "—",
                                installationURL: entry["url"] as? String)
        }
    }
}
