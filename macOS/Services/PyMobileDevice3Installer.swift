import Foundation

/// Installs pymobiledevice3 into a private virtual environment owned by this
/// app, so location spoofing works without the user opening Terminal.
///
/// pymobiledevice3 is the open source client for Apple's own developer
/// services — the same services behind Xcode's Simulate Location. It is
/// installed from PyPI into `Application Support`, never into the system
/// Python, and it needs no administrator rights.
struct PyMobileDevice3Installer {
    enum Progress: Equatable {
        case locatingPython
        case creatingEnvironment
        case downloading
        case finished(String)
    }

    private let runner = ProcessRunner.shared

    /// Where the private environment lives. Kept out of the app bundle so it
    /// survives updates and can be deleted by hand.
    static var environmentURL: URL {
        AppPaths.applicationSupport.appendingPathComponent("Dissappear/pymobiledevice3", isDirectory: true)
    }

    /// The executable this installer produces, whether or not it exists yet.
    static var executableURL: URL {
        environmentURL.appendingPathComponent("bin/pymobiledevice3")
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    // MARK: - Python

    /// Candidate interpreters, most self-contained first. `/usr/bin/python3`
    /// is a stub that prompts to install the Command Line Tools when they are
    /// missing, which is exactly the prompt the user needs to see.
    private static let pythonCandidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3"
    ]

    /// Returns an interpreter that can actually create a virtual environment.
    /// The Command Line Tools stub answers `--version` even when nothing is
    /// installed, so `venv` is what decides.
    private func locatePython() async -> String? {
        for path in Self.pythonCandidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let check = try? await runner.run(path, ["-c", "import venv"]), check.succeeded else { continue }
            return path
        }
        return nil
    }

    // MARK: - Install

    /// Creates the environment and installs pymobiledevice3 into it, or
    /// upgrades it if it is already there. Returns the executable path.
    @discardableResult
    func install(onProgress: @escaping @MainActor (Progress) -> Void,
                 onOutputLine: @escaping @Sendable (String) -> Void) async throws -> String {
        await onProgress(.locatingPython)
        guard let python = await locatePython() else {
            throw CompanionError(
                title: "Python 3 Is Needed Once",
                details: "Nothing on this Mac can create the private environment pymobiledevice3 installs into.",
                recommendedAction: "Install Apple's Command Line Tools — run xcode-select --install, or install Xcode from the App Store and open it once. Then try this again.",
                technicalDetails: "Checked: \(Self.pythonCandidates.joined(separator: ", "))")
        }

        let environment = Self.environmentURL
        if !FileManager.default.fileExists(atPath: environment.appendingPathComponent("bin/pip3").path) {
            await onProgress(.creatingEnvironment)
            try? FileManager.default.createDirectory(at: environment.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let create = try await runner.run(python, ["-m", "venv", environment.path],
                                              onOutputLine: onOutputLine)
            guard create.succeeded else {
                throw CompanionError.fromToolOutput(stage: "Creating the pymobiledevice3 environment",
                                                    result: create)
            }
        }

        await onProgress(.downloading)
        let pip = environment.appendingPathComponent("bin/pip3").path
        let result = try await runner.run(pip,
                                          ["install", "--upgrade", "--disable-pip-version-check", "pymobiledevice3"],
                                          onOutputLine: onOutputLine)
        guard result.succeeded else {
            let output = result.combinedOutput.lowercased()
            if output.contains("network") || output.contains("timed out") || output.contains("resolve") {
                throw CompanionError(
                    title: "Could Not Reach PyPI",
                    details: "The download of pymobiledevice3 failed.",
                    recommendedAction: "Check this Mac's internet connection and try again. Behind a proxy, install it by hand: brew install pymobiledevice3.",
                    technicalDetails: result.combinedOutput)
            }
            throw CompanionError.fromToolOutput(stage: "Installing pymobiledevice3", result: result)
        }

        guard Self.isInstalled else {
            throw CompanionError(
                title: "pymobiledevice3 Did Not Install",
                details: "pip reported success, but the executable is not where it should be.",
                recommendedAction: "Delete \(environment.path) and try again.",
                technicalDetails: result.combinedOutput)
        }

        let version = try? await runner.run(Self.executableURL.path, ["version"])
        let label = version?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) ?? "installed"
        await onProgress(.finished(label))
        return Self.executableURL.path
    }

    /// Removes the private environment, for a clean reinstall.
    func uninstall() throws {
        try? FileManager.default.removeItem(at: Self.environmentURL)
    }
}
