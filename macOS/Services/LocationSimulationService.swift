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
    iOS 17 and later reach the developer service over a tunnel that needs \
    administrator rights. Use Start Developer Tunnel — macOS will ask for your \
    password. By hand, run this once per restart and leave it running:

    sudo pymobiledevice3 remote tunneld
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
    func prepare(tool: Tool, onOutputLine: @escaping @Sendable (String) -> Void) async throws {
        guard tool.version != "devicectl" else { return }   // devicectl mounts on demand

        let result = try await runner.run(tool.executablePath, ["mounter", "auto-mount"], onOutputLine: onOutputLine)
        // Already-mounted is reported as a failure by some versions; that is fine.
        guard result.succeeded || result.combinedOutput.localizedCaseInsensitiveContains("already") else {
            throw Self.error(stage: "Mounting the developer disk image", result: result)
        }
    }

    /// Spoofs the device's location and returns the resulting session.
    ///
    /// Some tool versions hold the session open for as long as the spoof
    /// should last; others latch it on the device and exit. Both are success,
    /// and the returned session says which happened.
    @discardableResult
    func beginSession(latitude: Double,
                      longitude: Double,
                      device: Device,
                      tool: Tool,
                      onOutputLine: @escaping @Sendable (String) -> Void) async throws -> Session {
        let coordinates = [String(format: "%.6f", latitude), String(format: "%.6f", longitude)]

        if tool.version == "devicectl" {
            try await runSimulateLocation(["set", "--"] + coordinates,
                                          device: device,
                                          tool: tool,
                                          stage: "Spoofing the device location",
                                          onOutputLine: onOutputLine)
            return Session(handle: nil)
        }

        let arguments = ["developer", "dvt", "simulate-location", "set", "--udid", device.udid, "--"] + coordinates
        let handle = try await runner.start(tool.executablePath, arguments, onOutputLine: onOutputLine)

        // Give it a moment to fail loudly, rather than reporting success for a
        // session that died on launch.
        try? await Task.sleep(for: .seconds(2))
        if let status = await runner.exitStatus(handle) {
            await runner.stop(handle)
            guard status == 0 else {
                // Retry through the tunnel, which is what iOS 17 and later need.
                let tunnelled = try await runner.run(
                    tool.executablePath,
                    ["developer", "dvt", "simulate-location", "set", "--tunnel", device.udid, "--"] + coordinates,
                    onOutputLine: onOutputLine)
                if tunnelled.succeeded { return Session(handle: nil) }
                throw Self.error(stage: "Spoofing the device location", result: tunnelled)
            }
            // Exited cleanly: the coordinate is latched on the device.
            return Session(handle: nil)
        }
        return Session(handle: handle)
    }

    // MARK: - Developer tunnel

    /// Whether `pymobiledevice3 remote tunneld` is already answering.
    func isTunnelRunning() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(Self.tunneldPort)/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// Starts the tunnel daemon behind the standard macOS password panel.
    ///
    /// It is installed as a launchd daemon rather than backgrounded from the
    /// password prompt. `do shell script` reaps the process group it spawned
    /// as soon as it returns, so a `nohup … &` daemon died the instant the
    /// panel closed and the port was never bound. launchd owns the process
    /// instead, which also means it comes back after a restart — the tunnel is
    /// set up once rather than every time the Mac boots.
    func startTunnel(tool: Tool) async throws {
        guard tool.version != "devicectl" else { return }
        if await isTunnelRunning() { return }

        // Check the subcommand exists before asking anyone for a password.
        let help = try await runner.run(tool.executablePath, ["remote", "tunneld", "--help"])
        guard help.succeeded else {
            throw CompanionError(
                title: "This pymobiledevice3 Has No Tunnel",
                details: "The installed version does not provide `remote tunneld`.",
                recommendedAction: "Reinstall the tooling from Setup, which fetches a current version.",
                technicalDetails: help.combinedOutput)
        }

        // A root daemon must not execute a binary that this user can rewrite:
        // anything running as the user could then swap it and gain root. The
        // app's own environment lives in the user's Application Support, so a
        // root-owned copy is made and the daemon points at that.
        let ownsTool = tool.executablePath == PyMobileDevice3Installer.executableURL.path
        let source = PyMobileDevice3Installer.environmentURL.path
        let arguments = ownsTool
            ? [Self.systemToolDirectory + "/bin/python3", "-m", "pymobiledevice3", "remote", "tunneld"]
            : [tool.executablePath, "remote", "tunneld"]

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.daemonLabel).plist")
        try Self.daemonPlist(arguments: arguments)
            .write(to: staged, atomically: true, encoding: .utf8)

        var steps = ["mkdir -p " + Self.shellQuoted(Self.logDirectory)]
        if ownsTool {
            steps += [
                "rm -rf " + Self.shellQuoted(Self.systemToolDirectory),
                "mkdir -p " + Self.shellQuoted((Self.systemToolDirectory as NSString).deletingLastPathComponent),
                // Scripts inside a venv carry absolute shebangs, so the copy is
                // run as `python3 -m pymobiledevice3` rather than through them.
                "cp -R " + Self.shellQuoted(source) + " " + Self.shellQuoted(Self.systemToolDirectory),
                "chown -R root:wheel " + Self.shellQuoted(Self.systemToolDirectory),
                "chmod -R go-w " + Self.shellQuoted(Self.systemToolDirectory)
            ]
        }
        steps += [
            "cp " + Self.shellQuoted(staged.path) + " " + Self.shellQuoted(Self.daemonPlistPath),
            "chown root:wheel " + Self.shellQuoted(Self.daemonPlistPath),
            "chmod 644 " + Self.shellQuoted(Self.daemonPlistPath),
            // Replace any earlier copy rather than failing as already loaded.
            "launchctl bootout system/" + Self.daemonLabel + " 2>/dev/null || true",
            "launchctl bootstrap system " + Self.shellQuoted(Self.daemonPlistPath)
        ]
        let script = "do shell script " + Self.appleScriptQuoted(steps.joined(separator: "; "))
            + " with administrator privileges"

        let result = try await runner.run("/usr/bin/osascript", ["-e", script])
        guard result.succeeded else {
            if result.combinedOutput.localizedCaseInsensitiveContains("cancel")
                || result.combinedOutput.contains("-128") {
                throw CompanionError(
                    title: "Developer Tunnel Not Started",
                    details: "The administrator prompt was cancelled.",
                    recommendedAction: "The tunnel needs administrator rights because it opens a network interface on this Mac. Try again when you are ready.",
                    technicalDetails: result.combinedOutput)
            }
            throw Self.error(stage: "Installing the developer tunnel", result: result)
        }

        // launchd starts it asynchronously, and the first run imports a large
        // Python package tree, so this is slower than a bare process launch.
        for _ in 0..<40 {
            if await isTunnelRunning() { return }
            try? await Task.sleep(for: .milliseconds(750))
        }

        throw CompanionError(
            title: "Developer Tunnel Did Not Answer",
            details: "The daemon was installed but nothing is listening on port \(Self.tunneldPort).",
            recommendedAction: "The daemon's own output is below — it usually names the cause. Stop Tunnel and try again once it is addressed.",
            technicalDetails: await Self.tunnelDiagnostics())
    }

    /// Removes the daemon, so a tunnel the user did not want is not left
    /// running as root forever.
    func stopTunnel() async throws {
        let steps = [
            "launchctl bootout system/" + Self.daemonLabel + " 2>/dev/null || true",
            "rm -f " + Self.shellQuoted(Self.daemonPlistPath),
            "rm -rf " + Self.shellQuoted(Self.systemToolDirectory)
        ]
        let script = "do shell script " + Self.appleScriptQuoted(steps.joined(separator: "; "))
            + " with administrator privileges"

        let result = try await runner.run("/usr/bin/osascript", ["-e", script])
        guard result.succeeded else {
            throw Self.error(stage: "Stopping the developer tunnel", result: result)
        }
    }

    /// Whatever the daemon reported, so a failure is explained here instead of
    /// sending the user to find a log file by hand.
    private static func tunnelDiagnostics() async -> String {
        var parts: [String] = []

        for path in [logPath, errorLogPath] {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let tail = contents.split(separator: "\n").suffix(40).joined(separator: "\n")
            if !tail.isEmpty { parts.append("\(path):\n\(tail)") }
        }

        if let state = try? await ProcessRunner.shared.run("/bin/launchctl", ["print", "system/\(daemonLabel)"]),
           !state.combinedOutput.isEmpty {
            let tail = state.combinedOutput.split(separator: "\n").prefix(25).joined(separator: "\n")
            parts.append("launchctl print system/\(daemonLabel):\n\(tail)")
        }

        return parts.isEmpty
            ? "The daemon produced no output at \(logPath)."
            : parts.joined(separator: "\n\n")
    }

    // MARK: - launchd daemon

    private static let daemonLabel = "com.dissappear.tunneld"
    private static let daemonPlistPath = "/Library/LaunchDaemons/com.dissappear.tunneld.plist"
    private static let logDirectory = "/Library/Logs/Dissappear"
    /// Root-owned copy of the tool, so the daemon never runs user-writable code.
    private static let systemToolDirectory = "/Library/Application Support/Dissappear/tunnel"
    static let logPath = "/Library/Logs/Dissappear/tunneld.log"
    static let errorLogPath = "/Library/Logs/Dissappear/tunneld.error.log"

    private static func daemonPlist(arguments: [String]) -> String {
        let argumentXML = arguments
            .map { "        <string>\(xmlEscaped($0))</string>" }
            .joined(separator: "\n")
        return plist(argumentXML: argumentXML)
    }

    private static func plist(argumentXML: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
        \(argumentXML)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(errorLogPath)</string>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
    }

    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'" + escaped + "'"
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    func endSession(_ handle: UUID) async {
        await runner.stop(handle)
    }

    func isSessionActive(_ handle: UUID) async -> Bool {
        await runner.isRunning(handle)
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
        if tool.version == "devicectl" {
            try await runDeviceCtlLocation(arguments, device: device, tool: tool,
                                           stage: stage, onOutputLine: onOutputLine)
            return
        }

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
