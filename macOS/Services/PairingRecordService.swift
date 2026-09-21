import Foundation

/// Exports the device's pairing record, which is what lets the phone drive its
/// own developer services with no computer present.
///
/// Apps that spoof from the phone alone still need one thing from a computer,
/// once: this file. It is the trust relationship iOS established when the
/// device was paired, and without it nothing on the phone may open the
/// developer services on itself.
///
/// The record authenticates a client to this device for the whole of the
/// developer surface, so it is a credential, not a settings file.
struct PairingRecordService {
    private let runner = ProcessRunner.shared

    /// Where the record is written, named after the device so several phones
    /// can be exported without overwriting each other.
    static func suggestedFilename(for device: Device) -> String {
        let safe = device.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(safe) (\(device.udid.prefix(8))).mobiledevicepairing"
    }

    /// Writes the pairing record for a connected device.
    ///
    /// The device has to be plugged in, unlocked and already trusting this
    /// Mac: the record is what that trust produced, and it cannot be
    /// manufactured without it.
    func export(device: Device,
                tool: LocationSimulationService.Tool,
                to destination: URL,
                onOutputLine: @escaping @Sendable (String) -> Void) async throws {
        guard tool.version != "devicectl" else {
            throw CompanionError(
                title: "pymobiledevice3 Is Needed",
                details: "Apple's devicectl does not expose the pairing record.",
                recommendedAction: "Install the tooling from Setup, then try again.",
                technicalDetails: "tool = devicectl")
        }

        try? FileManager.default.removeItem(at: destination)

        let result = try await runner.run(
            tool.executablePath,
            ["lockdown", "save-pair-record", destination.path, "--udid", device.udid],
            onOutputLine: onOutputLine)

        guard result.succeeded else {
            let output = result.combinedOutput.lowercased()
            if output.contains("pair") || output.contains("trust") || output.contains("lockdown") {
                throw CompanionError(
                    title: "The Device Is Not Paired With This Mac",
                    details: "There is no pairing record to export.",
                    recommendedAction: "Plug the iPhone in over USB, unlock it, and tap Trust when it asks about this Mac. Then export again.",
                    technicalDetails: result.combinedOutput)
            }
            throw CompanionError.fromToolOutput(stage: "Exporting the pairing record", result: result)
        }

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw CompanionError(
                title: "Nothing Was Written",
                details: "The tool reported success but produced no file.",
                recommendedAction: "Check the technical details, then try again with the phone unlocked.",
                technicalDetails: result.combinedOutput)
        }
    }
}
