import Foundation

/// Drives `xcodebuild` with automatic signing so Apple's tooling manages
/// certificates, device registration and provisioning profiles.
struct BuildService {
    private let runner = ProcessRunner.shared

    struct Settings: Equatable {
        var bundleIdentifier: String
        var builtProductsDirectory: String
        var productName: String
        var developmentTeam: String?
    }

    func buildSettings(configuration: BuildConfiguration, device: Device?) async throws -> Settings {
        guard let projectURL = configuration.projectURL else {
            throw CompanionError(title: "Project not configured",
                                 details: "No Xcode project has been selected.",
                                 recommendedAction: "Choose Dissappear.xcodeproj in Settings.",
                                 technicalDetails: "BuildConfiguration.projectPath is empty")
        }

        var arguments = ["-project", projectURL.path,
                         "-scheme", configuration.scheme,
                         "-configuration", configuration.configuration,
                         "-derivedDataPath", configuration.derivedDataPath,
                         "-showBuildSettings", "-json"]
        if let device {
            arguments.append(contentsOf: ["-destination", "id=\(device.udid)"])
        } else {
            arguments.append(contentsOf: ["-destination", "generic/platform=iOS"])
        }

        let result = try await runner.run("/usr/bin/xcodebuild", arguments)
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Reading build settings", result: result)
        }

        guard let jsonStart = result.standardOutput.firstIndex(of: "["),
              let parsed = try? JSONSerialization.jsonObject(with: Data(result.standardOutput[jsonStart...].utf8)) as? [[String: Any]],
              let settings = parsed.first?["buildSettings"] as? [String: Any],
              let bundleID = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String,
              let productsDir = settings["BUILT_PRODUCTS_DIR"] as? String,
              let productName = settings["FULL_PRODUCT_NAME"] as? String else {
            throw CompanionError.fromToolOutput(stage: "Reading build settings", result: result)
        }

        let team = settings["DEVELOPMENT_TEAM"] as? String
        return Settings(bundleIdentifier: bundleID,
                        builtProductsDirectory: productsDir,
                        productName: productName,
                        developmentTeam: (team?.isEmpty == false) ? team : nil)
    }

    /// Writes the companion's simulation library into the iOS target's resources
    /// so the next build carries the current locations, routes and scenarios.
    func prepare(configuration: BuildConfiguration, library: SimulationLibrary) throws -> URL {
        guard let projectURL = configuration.projectURL else {
            throw CompanionError(title: "Project not configured",
                                 details: "No Xcode project has been selected.",
                                 recommendedAction: "Choose Dissappear.xcodeproj in Settings.",
                                 technicalDetails: "BuildConfiguration.projectPath is empty")
        }
        let resources = projectURL.deletingLastPathComponent()
            .appendingPathComponent("iOS/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let destination = resources.appendingPathComponent("\(SimulationLibrary.resourceName).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: destination, options: .atomic)
        return destination
    }

    func build(configuration: BuildConfiguration,
               device: Device,
               teamID: String?,
               onOutputLine: @escaping @Sendable (String) -> Void) async throws -> BuildProduct {
        guard let projectURL = configuration.projectURL else {
            throw CompanionError(title: "Project not configured",
                                 details: "No Xcode project has been selected.",
                                 recommendedAction: "Choose Dissappear.xcodeproj in Settings.",
                                 technicalDetails: "BuildConfiguration.projectPath is empty")
        }

        var arguments = ["-project", projectURL.path,
                         "-scheme", configuration.scheme,
                         "-configuration", configuration.configuration,
                         "-destination", "id=\(device.udid)",
                         "-derivedDataPath", configuration.derivedDataPath,
                         "-allowProvisioningUpdates",
                         "CODE_SIGN_STYLE=Automatic"]
        if let teamID, !teamID.isEmpty {
            arguments.append("DEVELOPMENT_TEAM=\(teamID)")
        }
        arguments.append("build")

        let result = try await runner.run("/usr/bin/xcodebuild", arguments,
                                          timeout: ProcessRunner.buildTimeout,
                                          onOutputLine: onOutputLine)
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Build", result: result)
        }

        let settings = try await buildSettings(configuration: configuration, device: device)
        let appURL = URL(fileURLWithPath: settings.builtProductsDirectory)
            .appendingPathComponent(settings.productName)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw CompanionError(title: "Build produced no app",
                                 details: "xcodebuild reported success but the built product could not be found.",
                                 recommendedAction: "Check that the scheme builds the Dissappear iOS app target, then rebuild.",
                                 technicalDetails: "Expected product at \(appURL.path)")
        }
        return BuildProduct(appURL: appURL, bundleIdentifier: settings.bundleIdentifier, builtAt: Date())
    }

    func clean(configuration: BuildConfiguration) async throws {
        guard let projectURL = configuration.projectURL else { return }
        let result = try await runner.run("/usr/bin/xcodebuild",
                                          ["-project", projectURL.path,
                                           "-scheme", configuration.scheme,
                                           "-configuration", configuration.configuration,
                                           "-derivedDataPath", configuration.derivedDataPath,
                                           "clean"],
                                          timeout: ProcessRunner.buildTimeout)
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Clean", result: result)
        }
    }

    /// Verifies the signature Apple's tooling applied to the built product.
    func verifySignature(of product: BuildProduct) async throws -> String {
        let result = try await runner.run("/usr/bin/codesign", ["-dv", "--verbose=2", product.appURL.path])
        guard result.succeeded else {
            throw CompanionError.fromToolOutput(stage: "Code signing", result: result)
        }
        let output = result.combinedOutput
        let authority = output
            .split(separator: "\n")
            .first { $0.hasPrefix("Authority=") }?
            .replacingOccurrences(of: "Authority=", with: "")
        return authority ?? "Signed"
    }

    func embeddedProfile(in product: BuildProduct) -> ProvisioningProfile? {
        let url = product.appURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards) else { return nil }
        return SigningService.parseProfile(data[start.lowerBound..<end.upperBound], fileURL: url)
    }
}
