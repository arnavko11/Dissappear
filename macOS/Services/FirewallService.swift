import Foundation

/// Reports whether the macOS application firewall is blocking this app from
/// accepting incoming connections, and can ask for it to be allowed.
///
/// This matters because the companion is ad-hoc signed rather than signed with
/// a Developer ID. When the firewall is on, macOS blocks incoming connections
/// to such an app, and it does so without a prompt — the listener binds, says
/// it is listening, and the phone's connection attempts simply never arrive.
struct FirewallService {
    enum Status: Equatable {
        case off
        case allowed
        case blocked
        case unknown

        var isBlocking: Bool { self == .blocked }
    }

    private static let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    private let runner = ProcessRunner.shared

    private var appPath: String { Bundle.main.bundleURL.path }

    func status() async -> Status {
        guard FileManager.default.isExecutableFile(atPath: Self.tool) else { return .unknown }

        guard let global = try? await runner.run(Self.tool, ["--getglobalstate"]),
              global.succeeded else { return .unknown }
        // "Firewall is disabled. (State = 0)"
        if global.combinedOutput.contains("State = 0") { return .off }

        guard let app = try? await runner.run(Self.tool, ["--getappblocked", appPath]),
              app.succeeded else { return .unknown }

        let output = app.combinedOutput.lowercased()
        if output.contains("blocked from accepting") { return .blocked }
        if output.contains("allowed to accept") { return .allowed }
        // An app the firewall has never seen is not listed at all. With the
        // firewall on and no Developer ID signature, that means blocked.
        return .blocked
    }

    /// Adds this app to the firewall's list and unblocks it, behind the
    /// standard administrator prompt.
    func allowIncomingConnections() async throws {
        let quoted = "'" + appPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let steps = [
            "\(Self.tool) --add \(quoted)",
            "\(Self.tool) --unblockapp \(quoted)"
        ].joined(separator: "; ")

        let escaped = steps
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let result = try await runner.run("/usr/bin/osascript", ["-e", script])
        guard result.succeeded else {
            if result.combinedOutput.localizedCaseInsensitiveContains("cancel")
                || result.combinedOutput.contains("-128") {
                throw CompanionError(
                    title: "Firewall Not Changed",
                    details: "The administrator prompt was cancelled.",
                    recommendedAction: "Allow it yourself in System Settings ▸ Network ▸ Firewall ▸ Options, by adding Dissappear Companion and setting it to allow incoming connections.",
                    technicalDetails: result.combinedOutput)
            }
            throw CompanionError.fromToolOutput(stage: "Allowing incoming connections", result: result)
        }
    }
}
