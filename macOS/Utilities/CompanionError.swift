import Foundation

/// A technical failure translated into something the UI can show without
/// dumping raw tool output at the user.
struct CompanionError: Identifiable, Error, Equatable {
    let id = UUID()
    var title: String
    var details: String
    var recommendedAction: String
    var technicalDetails: String

    static func == (lhs: CompanionError, rhs: CompanionError) -> Bool { lhs.id == rhs.id }

    static func fromToolOutput(stage: String, result: ProcessResult) -> CompanionError {
        let output = result.combinedOutput
        let mapped = Diagnosis.match(output)
        return CompanionError(title: mapped?.title ?? "\(stage) failed",
                              details: mapped?.details ?? Self.firstMeaningfulLine(in: output) ?? "The tool exited with code \(result.exitCode).",
                              recommendedAction: mapped?.action ?? "Review the technical details below and retry once the underlying issue is resolved.",
                              technicalDetails: "$ \(result.command)\n\n\(output)")
    }

    static func generic(_ title: String, _ error: Error, action: String = "Check that Xcode and the command line developer tools are installed.") -> CompanionError {
        CompanionError(title: title,
                       details: error.localizedDescription,
                       recommendedAction: action,
                       technicalDetails: String(describing: error))
    }

    private static func firstMeaningfulLine(in output: String) -> String? {
        output
            .split(separator: "\n")
            .map(String.init)
            .first { $0.lowercased().contains("error") || $0.lowercased().contains("failed") }
    }

    private struct Diagnosis {
        var title: String
        var details: String
        var action: String

        static func match(_ output: String) -> Diagnosis? {
            let lower = output.lowercased()
            if lower.contains("no signing certificate") || lower.contains("doesn't have a valid signing identity") {
                return Diagnosis(title: "Code signing failed",
                                 details: "No Apple Development signing certificate is available for the selected team.",
                                 action: "Open Xcode ▸ Settings ▸ Accounts, sign in with your Apple ID and let Xcode create a development certificate.")
            }
            if lower.contains("requires a development team") || lower.contains("select a development team") {
                return Diagnosis(title: "Code signing failed",
                                 details: "The selected development team is not available for this project.",
                                 action: "Choose a development team in Settings, or open Xcode and select your team in Signing & Capabilities.")
            }
            if lower.contains("no profiles for") || lower.contains("failed to create provisioning profile") {
                return Diagnosis(title: "Provisioning failed",
                                 details: "Xcode could not create a development provisioning profile for this bundle identifier.",
                                 action: "Make sure the device is registered to your team and that the bundle identifier is available, then retry with automatic signing.")
            }
            if lower.contains("device is locked") || lower.contains("passcode") {
                return Diagnosis(title: "Installation failed",
                                 details: "The iPhone is locked.",
                                 action: "Unlock the iPhone, keep it unlocked, then run Install again.")
            }
            if lower.contains("developer mode") {
                return Diagnosis(title: "Developer Mode required",
                                 details: "The connected iPhone does not have Developer Mode enabled.",
                                 action: "On the iPhone open Settings ▸ Privacy & Security ▸ Developer Mode, turn it on and restart the device.")
            }
            if lower.contains("not paired") || lower.contains("trust this computer") || lower.contains("pairing") {
                return Diagnosis(title: "Device is not trusted",
                                 details: "The iPhone has not been paired with this Mac.",
                                 action: "Unlock the iPhone and tap Trust when asked to trust this computer, then reconnect.")
            }
            if lower.contains("xcode-select: error") || lower.contains("unable to find utility") {
                return Diagnosis(title: "Developer tools not available",
                                 details: "The active developer directory does not provide the required tool.",
                                 action: "Install Xcode, then run xcode-select to point at it (Xcode ▸ Settings ▸ Locations ▸ Command Line Tools).")
            }
            if lower.contains("unable to install") || lower.contains("applicationverificationfailed") {
                return Diagnosis(title: "Installation failed",
                                 details: "iOS rejected the development build's signature.",
                                 action: "Refresh the build so it is re-signed with a current development profile, then reinstall.")
            }
            return nil
        }
    }
}
