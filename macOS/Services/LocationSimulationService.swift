import Foundation

/// Sets the simulated location on a connected device using Apple's own
/// developer location service — the one behind Xcode's Simulate Location.
///
/// This is device-wide: every app on the phone sees the simulated coordinate
/// while it is active, and `clear` returns the device to real GPS. It requires
/// Developer Mode, a trusted Mac and a mounted developer disk image, so it is
/// visible to the device's owner rather than hidden from them.
///
/// The service is reached through pymobiledevice3, an open source client the
/// user installs. Nothing is bundled or downloaded by this app.
struct LocationSimulationService {
    struct Tool: Equatable, Sendable {
        var executablePath: String
        var version: String
    }

    enum Availability: Equatable {
        case ready(Tool)
        case notInstalled

        var tool: Tool? {
            if case let .ready(tool) = self { return tool }
            return nil
        }
    }

    private static let candidatePaths = [
        "/opt/homebrew/bin/pymobiledevice3",
        "/usr/local/bin/pymobiledevice3",
        "/opt/homebrew/opt/pymobiledevice3/bin/pymobiledevice3"
    ]

    static let installGuidance = """
    Install pymobiledevice3, the open source client for Apple's developer \
    services: brew install pymobiledevice3, or pipx install pymobiledevice3.
    """

    static let tunnelGuidance = """
    iOS 17 and later reach the developer service over a tunnel that needs \
    administrator rights, which this app does not ask for. Run this once per \
    restart in Terminal and leave it running:

    sudo pymobiledevice3 remote tunneld
    """

    private let runner = ProcessRunner.shared

    func availability() async -> Availability {
        var searchPaths = Self.candidatePaths
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        searchPaths.append("\(home)/.local/bin/pymobiledevice3")

        guard let path = searchPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .notInstalled
        }
        let version = try? await runner.run(path, ["version"])
        return .ready(Tool(executablePath: path,
                           version: version?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) ?? "installed"))
    }

    /// Mounts the developer disk image if it is not mounted already.
    func prepare(tool: Tool, onOutputLine: @escaping @Sendable (String) -> Void) async throws {
        let result = try await runner.run(tool.executablePath, ["mounter", "auto-mount"], onOutputLine: onOutputLine)
        // Already-mounted is reported as a failure by some versions; that is fine.
        guard result.succeeded || result.combinedOutput.localizedCaseInsensitiveContains("already") else {
            throw Self.error(stage: "Mounting the developer disk image", result: result)
        }
    }

    func setLocation(latitude: Double,
                     longitude: Double,
                     device: Device,
                     tool: Tool,
                     onOutputLine: @escaping @Sendable (String) -> Void) async throws {
        let coordinates = [String(format: "%.6f", latitude), String(format: "%.6f", longitude)]
        try await runSimulateLocation(["set", "--"] + coordinates,
                                      device: device,
                                      tool: tool,
                                      stage: "Setting the device location",
                                      onOutputLine: onOutputLine)
    }

    func clearLocation(device: Device,
                       tool: Tool,
                       onOutputLine: @escaping @Sendable (String) -> Void) async throws {
        try await runSimulateLocation(["clear"],
                                      device: device,
                                      tool: tool,
                                      stage: "Clearing the device location",
                                      onOutputLine: onOutputLine)
    }

    func playRoute(gpxURL: URL,
                   device: Device,
                   tool: Tool,
                   onOutputLine: @escaping @Sendable (String) -> Void) async throws {
        try await runSimulateLocation(["play", gpxURL.path],
                                      device: device,
                                      tool: tool,
                                      stage: "Playing the route on the device",
                                      onOutputLine: onOutputLine)
    }

    /// Tries the direct call first, then the tunnel-aware form iOS 17+ needs.
    private func runSimulateLocation(_ arguments: [String],
                                     device: Device,
                                     tool: Tool,
                                     stage: String,
                                     onOutputLine: @escaping @Sendable (String) -> Void) async throws {
        let base = ["developer", "dvt", "simulate-location"]

        let direct = try await runner.run(tool.executablePath,
                                          base + arguments + ["--udid", device.udid],
                                          onOutputLine: onOutputLine)
        if direct.succeeded { return }

        let tunnelled = try await runner.run(tool.executablePath,
                                             base + arguments + ["--tunnel", device.udid],
                                             onOutputLine: onOutputLine)
        if tunnelled.succeeded { return }

        throw Self.error(stage: stage, result: tunnelled, fallback: direct)
    }

    // MARK: - Errors

    private static func error(stage: String, result: ProcessResult, fallback: ProcessResult? = nil) -> CompanionError {
        let output = [result.combinedOutput, fallback?.combinedOutput]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let lower = output.lowercased()

        if lower.contains("tunnel") || lower.contains("rsd") || lower.contains("remotepairing") {
            return CompanionError(title: "Developer Tunnel Required",
                                  details: "iOS 17 and later reach the developer location service over a tunnel that needs administrator rights.",
                                  recommendedAction: tunnelGuidance,
                                  technicalDetails: output)
        }
        if lower.contains("developermode") || lower.contains("developer mode") {
            return CompanionError(title: "Developer Mode Required",
                                  details: "The device refused the developer service.",
                                  recommendedAction: "On the iPhone, turn on Settings ▸ Privacy & Security ▸ Developer Mode and restart it.",
                                  technicalDetails: output)
        }
        if lower.contains("ddi") || lower.contains("developer disk") || lower.contains("imagemounter") {
            return CompanionError(title: "Developer Disk Image Not Mounted",
                                  details: "The developer services are unavailable until the disk image is mounted.",
                                  recommendedAction: "Use Prepare Device, or run pymobiledevice3 mounter auto-mount in Terminal.",
                                  technicalDetails: output)
        }
        return CompanionError(title: "\(stage) failed",
                              details: output.split(separator: "\n").last.map(String.init)
                                  ?? "The tool exited with code \(result.exitCode).",
                              recommendedAction: "Check the technical details below. \(tunnelGuidance)",
                              technicalDetails: output)
    }
}

/// Writes a route as GPX so the developer service can replay it.
enum GPXWriter {
    static func write(coordinates: [(latitude: Double, longitude: Double)], name: String) throws -> URL {
        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Dissappear Companion" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(name)</name>
            <trkseg>

        """
        for coordinate in coordinates {
            gpx += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"></trkpt>\n",
                          coordinate.latitude, coordinate.longitude)
        }
        gpx += """
            </trkseg>
          </trk>
        </gpx>
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DissappearRoute-\(UUID().uuidString).gpx")
        try gpx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
