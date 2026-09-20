import Foundation

/// Access to the iOS build shipped inside this app's own bundle, so a user can
/// install the test app without checking out or building the Xcode project.
struct BundledBuildService {
    static let resourceName = "BundledApp"

    private let runner = ProcessRunner.shared

    var bundledArchiveURL: URL? {
        Bundle.main.url(forResource: Self.resourceName, withExtension: "ipa")
    }

    var isAvailable: Bool { bundledArchiveURL != nil }

    var version: String? {
        guard let url = bundledArchiveURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    /// Expands the embedded archive into a fresh working directory and returns
    /// the extracted .app.
    func extract() async throws -> URL {
        guard let archive = bundledArchiveURL else {
            throw CompanionError(title: "No Bundled Build",
                                 details: "This copy of the companion does not include a prebuilt iOS app.",
                                 recommendedAction: "Download a release build of the companion, or build the iOS app from the Xcode project instead.",
                                 technicalDetails: "Bundle.main has no \(Self.resourceName).ipa resource")
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("DissappearBundled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let result = try await runner.run("/usr/bin/ditto", ["-x", "-k", archive.path, workspace.path])
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Unpacking bundled build", result: result)
        }

        let payload = workspace.appendingPathComponent("Payload", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw CompanionError(title: "Bundled Build Is Unreadable",
                                 details: "The embedded archive does not contain an app.",
                                 recommendedAction: "Download the companion again, or build from the Xcode project.",
                                 technicalDetails: "No .app found in \(payload.path)")
        }
        return app
    }
}
