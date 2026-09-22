import Foundation

struct BuildConfiguration: Equatable, Codable {
    /// Path to Dissappear.xcodeproj. Defaults to the repository this app was built from.
    var projectPath: String
    var scheme: String
    var configuration: String
    var derivedDataPath: String

    static let iOSScheme = "Dissappear"

    static var `default`: BuildConfiguration {
        let support = AppPaths.applicationSupport
            .appendingPathComponent("DissappearCompanion", isDirectory: true)
        return BuildConfiguration(projectPath: detectedProjectPath ?? "",
                                  scheme: iOSScheme,
                                  configuration: "Debug",
                                  derivedDataPath: support.appendingPathComponent("DerivedData").path)
    }

    /// Best-effort default: the repository this companion was compiled from.
    /// Falls back to an empty path when the sources are no longer present.
    static var detectedProjectPath: String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Build
            .deletingLastPathComponent()   // macOS
            .deletingLastPathComponent()   // repository root
        let project = root.appendingPathComponent("Dissappear.xcodeproj")
        return FileManager.default.fileExists(atPath: project.path) ? project.path : nil
    }

    var projectURL: URL? {
        projectPath.isEmpty ? nil : URL(fileURLWithPath: projectPath)
    }

    var isConfigured: Bool {
        guard let projectURL else { return false }
        return FileManager.default.fileExists(atPath: projectURL.path)
    }
}

struct BuildProduct: Equatable {
    var appURL: URL
    var bundleIdentifier: String
    var builtAt: Date
}

enum PipelineStage: String, CaseIterable, Identifiable {
    case connect = "Connect iPhone"
    case developerMode = "Developer Mode"
    case identity = "Signing Identity"
    case prepare = "Prepare Project"
    case build = "Build"
    case sign = "Code Sign"
    case provision = "Provision"
    case install = "Install"
    case launch = "Launch"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .connect: return "cable.connector"
        case .developerMode: return "hammer.circle"
        case .identity: return "person.badge.key"
        case .prepare: return "folder.badge.gearshape"
        case .build: return "hammer"
        case .sign: return "signature"
        case .provision: return "doc.badge.gearshape"
        case .install: return "square.and.arrow.down"
        case .launch: return "play.circle"
        }
    }
}

enum StageState: Equatable {
    case pending
    case running
    case succeeded(String)
    case skipped(String)
    case failed(String)

    var isTerminalFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
