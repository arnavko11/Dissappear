import Foundation

struct ToolchainStatus: Equatable {
    var developerDirectory: String?
    var xcodeVersion: String?
    var hasDeviceCtl: Bool
    var hasXcodebuild: Bool

    static let unknown = ToolchainStatus(developerDirectory: nil, xcodeVersion: nil, hasDeviceCtl: false, hasXcodebuild: false)

    var isReady: Bool { hasXcodebuild && hasDeviceCtl && xcodeVersion != nil }

    var summary: String {
        guard let xcodeVersion else { return "Xcode not found" }
        return xcodeVersion
    }
}

/// Detects Apple's developer tooling and degrades gracefully when it is absent.
struct ToolchainService {
    private let runner = ProcessRunner.shared

    func status() async -> ToolchainStatus {
        var status = ToolchainStatus.unknown

        if let select = try? await runner.run("/usr/bin/xcode-select", ["-p"]), select.succeeded {
            status.developerDirectory = select.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let version = try? await runner.run("/usr/bin/xcodebuild", ["-version"]), version.succeeded {
            status.hasXcodebuild = true
            status.xcodeVersion = version.standardOutput
                .split(separator: "\n")
                .prefix(2)
                .joined(separator: " · ")
        }

        if let find = try? await runner.run("/usr/bin/xcrun", ["--find", "devicectl"]), find.succeeded {
            status.hasDeviceCtl = true
        }

        return status
    }

    /// Xcode owns Apple ID authentication; the companion never handles credentials.
    func openXcodeAccounts() async {
        _ = try? await runner.run("/usr/bin/open", ["-b", "com.apple.dt.Xcode"])
    }
}
