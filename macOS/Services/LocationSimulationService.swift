import Foundation

/// Spoofs the location of a connected iPhone using Apple's own developer
/// location service — the one behind Xcode's Simulate Location.
///
/// This is device-wide: every app on the phone, Maps and Find My included,
/// sees the spoofed coordinate while it is active, and `clear` returns the
/// device to real GPS. It requires Developer Mode, a trusted Mac and a mounted
/// developer disk image, so it is visible to the device's owner rather than
/// hidden from them.
///
/// The service is reached through pymobiledevice3, an open source client. The
/// companion can install it into a private environment it owns.
struct LocationSimulationService {
    struct Tool: Equatable, Sendable {
        var executablePath: String
        var version: String
    }

    enum Availability: Equatable {
        /// Apple's own devicectl, when this Xcode's build supports location.
        case deviceCtl(Tool)
        case ready(Tool)
        case notInstalled

        var tool: Tool? {
            switch self {
            case let .deviceCtl(tool), let .ready(tool): return tool
            case .notInstalled: return nil
            }
        }

        var usesAppleTooling: Bool {
            if case .deviceCtl = self { return true }
            return false
        }

        var displayName: String {
            switch self {
            case .deviceCtl: return "devicectl (Xcode)"
            case let .ready(tool): return tool.version
            case .notInstalled: return "pymobiledevice3 not installed"
            }
        }
    }

    private static var candidatePaths: [String] = [
        // The copy this app installs itself is preferred: its version is known
        // to work with the commands below.
        PyMobileDevice3Installer.executableURL.path,
        "/opt/homebrew/bin/pymobiledevice3",
        "/usr/local/bin/pymobiledevice3",
        "/opt/homebrew/opt/pymobiledevice3/bin/pymobiledevice3"
    ]

    static let installGuidance = """
    Use Install pymobiledevice3 to set it up automatically — it goes into a \
    private folder this app owns and needs no administrator rights. By hand: \
    brew install pymobiledevice3, or pipx install pymobiledevice3.
    """

    static let tunnelGuidance = """
    The companion tries Apple's own tunnel first, which needs no password and \
    leaves Xcode working, then an in-process tunnel. If both are refused, the \
    device may need unlocking, or Developer Mode turning on under Settings ▸ \
    Privacy & Security.
    """

    /// Port `pymobiledevice3 remote tunneld` binds by default.
    private static let tunneldPort = 49151

    /// A held session, or a latched one.
    ///
    /// Older builds assumed the tool always stays running. It does not:
    /// `simulate-location set` latches the coordinate on the device and exits,
    /// and the spoof then lasts until it is cleared. Treating that exit as a
    /// lost session is what made the UI announce "the simulation stopped"
    /// seconds after a location was set successfully.
    struct Session: Equatable, Sendable {
        /// Set only while a process is holding the session open.
        var handle: UUID?
        var isHeld: Bool { handle != nil }
    }

    /// How the tool reaches the device.
    ///
    /// The cable is not the only way in, and the privileged tunnel is the
    /// worst of the options rather than the only one:
    ///
    /// - `native` rides Apple's own `remoted` tunnel through `remotepairingd`.
    ///   No root, no Xcode, and `remoted` keeps running, so it coexists with
    ///   devicectl instead of fighting it for the device.
    /// - `userspace` builds the iOS 17+ tunnel in-process in pure Python. No
    ///   root either, just slower.
    /// - `plain` is lockdown over usbmux, which is all iOS 16 and earlier need.
    /// - `tunnel` is the privileged `tunneld` daemon: a last resort, because it
    ///   wants an administrator password and takes the device away from Xcode.
    ///
    /// Each can discover the device over Bonjour instead of USB, which is what
    /// lets the phone be unplugged and stay reachable.
    struct Link: Equatable, Sendable {
        enum Transport: Equatable, Sendable {
            case native
            case userspace
            case plain
            case tunnel
        }

        var transport: Transport
        var isWireless: Bool

        func arguments(udid: String) -> [String] {
            var arguments: [String] = []
            switch transport {
            case .native: arguments.append("--native")
            case .userspace: arguments.append("--userspace")
            case .plain: break
            case .tunnel: arguments += ["--tunnel", udid]
            }
            // --tunnel already names the device; passing both is rejected.
            if transport != .tunnel { arguments += ["--udid", udid] }
            if isWireless { arguments.append("--mobdev2") }
            return arguments
        }

        var needsAdministrator: Bool { transport == .tunnel }

        var label: String {
            let how: String
            switch transport {
            case .native: how = "Apple's own tunnel"
            case .userspace: how = "in-process tunnel"
            case .plain: how = "lockdown"
            case .tunnel: how = "tunneld"
            }
            return "\(how) over \(isWireless ? "Wi-Fi" : "USB")"
        }

        /// Cheapest and least invasive first, and a known-good link ahead of
        /// everything so the search happens once rather than every time.
        static func candidates(preferring known: Link?) -> [Link] {
            var all: [Link] = []
            for transport: Transport in [.native, .userspace, .plain] {
                all.append(Link(transport: transport, isWireless: false))
                all.append(Link(transport: transport, isWireless: true))
            }
            all.append(Link(transport: .tunnel, isWireless: false))

            guard let known else { return all }
            all.removeAll { $0 == known }
            return [known] + all
        }
    }

    private let runner = ProcessRunner.shared

    func availability() async -> Availability {
        // Prefer Apple's own tooling when this Xcode's devicectl offers
        // location, so nothing extra needs installing. It is undocumented, so
        // its help output is what decides.
        if let deviceCtl = await deviceCtlLocationSupport() {
            return .deviceCtl(deviceCtl)
        }

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

    /// Reports devicectl's location support, if this Xcode has it.
    private func deviceCtlLocationSupport() async -> Tool? {
        guard let found = try? await runner.run("/usr/bin/xcrun", ["--find", "devicectl"]), found.succeeded else {
            return nil
        }
        let path = found.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        // The old check looked for the word "location" anywhere in `device
        // --help`, which matches Xcode versions that have no location verb at
        // all — every later command then failed. Ask for the subcommand
        // itself instead; an Xcode without it exits non-zero here.
        guard let help = try? await runner.run(path, ["device", "location", "--help"]),
              help.succeeded,
              help.combinedOutput.lowercased().contains("location") else { return nil }

        return Tool(executablePath: path, version: "devicectl")
    }

    /// Mounts the developer disk image if it is not mounted already.
    @discardableResult
    func prepare(device: Device,
                 tool: Tool,
                 link: Link?,
                 onOutputLine: @escaping @Sendable (String) -> Void) async throws -> Link? {
        guard tool.version != "devicectl" else { return link }   // devicectl mounts on demand

        let outcome = try await attempt(["mounter", "auto-mount"],
                                        device: device,
                                        tool: tool,
                                        link: link,
                                        stage: "Mounting the developer disk image",
                                        acceptable: { $0.localizedCaseInsensitiveContains("already") },
                                        onOutputLine: onOutputLine)
        return outcome
    }

    /// Spoofs the device's location.
    ///
    /// `set` latches the coordinate on the device and exits — the spoof lasts
    /// until it is cleared, not until this process ends — so there is no
    /// session to hold open and nothing to keep running.
    @discardableResult
    func beginSession(latitude: Double,
                      longitude: Double,
                      device: Device,
                      tool: Tool,
                      link: Link?,
                      onOutputLine: @escaping @Sendable (String) -> Void) async throws -> (Session, Link?) {
        let coordinates = [String(format: "%.6f", latitude), String(format: "%.6f", longitude)]

        if tool.version == "devicectl" {
            try await runDeviceCtlLocation(["set"] + coordinates,
                                           device: device,
                                           tool: tool,
                                           stage: "Spoofing the device location",
                                           onOutputLine: onOutputLine)
            return (Session(handle: nil), link)
        }

        let resolved = try await attempt(["developer", "dvt", "simulate-location", "set", "--"] + coordinates,
                                         device: device,
                                         tool: tool,
                                         link: link,
                                         stage: "Spoofing the device location",
                                         onOutputLine: onOutputLine)
        return (Session(handle: nil), resolved)
    }

    /// Runs a command, trying each way of reaching the device until one works.
    ///
    /// The winning link is returned so the next call starts with it: the
    /// search is for the first command against a device, not for every one.
    @discardableResult
    private func attempt(_ command: [String],
                         device: Device,
                         tool: Tool,
                         link: Link?,
                         stage: String,
                         acceptable: (String) -> Bool = { _ in false },
                         onOutputLine: @escaping @Sendable (String) -> Void) async throws -> Link? {
        var failures: [(Link, ProcessResult)] = []

        for candidate in Link.candidates(preferring: link) {
            // Never ask for a password on a guess. The privileged tunnel is
            // only used once it is already running.
            if candidate.needsAdministrator, !(await isTunnelRunning()) { continue }

            let result = try await runner.run(tool.executablePath,
                                              command + candidate.arguments(udid: device.udid),
                                              onOutputLine: onOutputLine)
            if result.succeeded || acceptable(result.combinedOutput) {
                return candidate
            }
            failures.append((candidate, result))
        }

        guard let (_, last) = failures.last else {
            throw CompanionError(
                title: "\(stage) failed",
                details: "No way of reaching the device was available.",
                recommendedAction: "Connect the iPhone by cable, unlock it, and make sure Developer Mode is on.",
                technicalDetails: command.joined(separator: " "))
        }

        var error = Self.error(stage: stage, result: last)
        error.technicalDetails = failures
            .map { "— \($0.0.label)\n\($0.1.combinedOutput)" }
            .joined(separator: "\n\n")
        throw error
    }

    func endSession(_ handle: UUID) async {
        await runner.stop(handle)
    }

    func isSessionActive(_ handle: UUID) async -> Bool {
        await runner.isRunning(handle)
    }

    @discardableResult
    func clearLocation(device: Device,
                       tool: Tool,
                       link: Link?,
                       onOutputLine: @escaping @Sendable (String) -> Void) async throws -> Link? {
        if tool.version == "devicectl" {
            try await runDeviceCtlLocation(["clear"], device: device, tool: tool,
                                           stage: "Restoring the real location",
                                           onOutputLine: onOutputLine)
            return link
        }
        return try await attempt(["developer", "dvt", "simulate-location", "clear"],
                                 device: device,
                                 tool: tool,
                                 link: link,
                                 stage: "Restoring the real location",
                                 onOutputLine: onOutputLine)
    }

    @discardableResult
    func playRoute(gpxURL: URL,
                   device: Device,
                   tool: Tool,
                   link: Link?,
                   onOutputLine: @escaping @Sendable (String) -> Void) async throws -> Link? {
        if tool.version == "devicectl" {
            try await runDeviceCtlLocation(["play", gpxURL.path], device: device, tool: tool,
                                           stage: "Playing the route on the device",
                                           onOutputLine: onOutputLine)
            return link
        }
        return try await attempt(["developer", "dvt", "simulate-location", "play", gpxURL.path],
                                 device: device,
                                 tool: tool,
                                 link: link,
                                 stage: "Playing the route on the device",
                                 onOutputLine: onOutputLine)
    }

    /// devicectl's location verbs, tried in the shapes Apple's CLI uses
    /// elsewhere. Unsupported shapes fail harmlessly and the next is tried.
    private func runDeviceCtlLocation(_ arguments: [String],
                                      device: Device,
                                      tool: Tool,
                                      stage: String,
                                      onOutputLine: @escaping @Sendable (String) -> Void) async throws {
        let verb = arguments.first ?? "set"
        let values = arguments.filter { $0 != verb && $0 != "--" }

        var attempts: [[String]] = []
        switch verb {
        case "set" where values.count == 2:
            attempts = [
                ["device", "location", "set", "--device", device.udid,
                 "--latitude", values[0], "--longitude", values[1]],
                ["device", "location", "set", "--device", device.udid, values[0], values[1]]
            ]
        case "clear":
            attempts = [["device", "location", "clear", "--device", device.udid]]
        default:
            attempts = [["device", "location", verb, "--device", device.udid] + values]
        }

        var last: ProcessResult?
        for attempt in attempts {
            let result = try await runner.run(tool.executablePath, attempt, onOutputLine: onOutputLine)
            if result.succeeded { return }
            last = result
        }
        throw Self.error(stage: stage, result: last ?? ProcessResult(command: "devicectl",
                                                                     exitCode: 1,
                                                                     standardOutput: "",
                                                                     standardError: "devicectl rejected the location command."))
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
