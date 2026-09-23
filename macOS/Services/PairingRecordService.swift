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

        // A fresh pairing, not a copy of the Mac's own record. macOS hands out
        // its record without the escrow bag, and without that the phone hangs
        // up on every session opened while it is locked — the broken pipe the
        // on-device path kept hitting. Pairing under a new host ID also leaves
        // the Mac's own trust untouched; the phone asks to Trust once more.
        onOutputLine("Tap Trust on the iPhone when it asks.")
        let result = try await runner.run(
            Self.interpreter(for: tool.executablePath),
            ["-c", Self.pairScript, device.udid, destination.path],
            timeout: .seconds(180),
            onOutputLine: onOutputLine)

        guard result.succeeded else {
            let output = result.combinedOutput.lowercased()
            let action: String
            if output.contains("denied") {
                action = "You tapped Don't Trust. Export again and tap Trust."
            } else if output.contains("pending") || output.contains("timeout") || output.contains("timed out") {
                action = "The iPhone never answered the Trust prompt. Unlock it, export again, and tap Trust."
            } else if output.contains("passwordprotected") || output.contains("escrow") {
                action = "Unlock the iPhone, keep it unlocked, and export again."
            } else {
                throw CompanionError.fromToolOutput(stage: "Exporting the pairing record", result: result)
            }
            throw CompanionError(title: "The iPhone Did Not Pair",
                                 details: "A pairing record is made by pairing with the phone, which needs it unlocked and a tap on Trust.",
                                 recommendedAction: action,
                                 technicalDetails: result.combinedOutput)
        }

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw CompanionError(
                title: "Nothing Was Written",
                details: "The tool reported success but produced no file.",
                recommendedAction: "Check the technical details, then try again with the phone unlocked.",
                technicalDetails: result.combinedOutput)
        }
    }

    /// The Python that pymobiledevice3 runs under, read from its launcher so
    /// the script imports the same installation.
    static func interpreter(for executable: String) -> String {
        if let handle = FileHandle(forReadingAtPath: executable),
           let head = try? handle.read(upToCount: 512),
           let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first,
           line.hasPrefix("#!") {
            let path = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !path.contains(" "), FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let sibling = URL(fileURLWithPath: executable).deletingLastPathComponent()
            .appendingPathComponent("python3").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : "/usr/bin/python3"
    }

    /// Turns on the phone's network lockdown connections — the same switch as
    /// Finder's "Show this iPhone when on Wi-Fi". Without it the phone hangs
    /// up on its own app, because the loopback VPN counts as a network.
    func enableNetworkConnections(device: Device, tool: LocationSimulationService.Tool) async -> Bool {
        guard tool.version != "devicectl" else { return false }
        let result = try? await runner.run(tool.executablePath,
                                           ["lockdown", "wifi-connections", "on", "--udid", device.udid],
                                           timeout: ProcessRunner.deviceTimeout)
        return result?.succeeded ?? false
    }

    /// Pairs under a fresh host ID and writes the record, escrow bag and all.
    /// The cache folder is a temporary one so pymobiledevice3's own record is
    /// left alone.
    static let pairScript = """
    import asyncio, plistlib, sys, tempfile, uuid
    from pathlib import Path
    from pymobiledevice3.lockdown import create_using_usbmux

    async def main(udid, out):
        with tempfile.TemporaryDirectory() as cache:
            ld = await create_using_usbmux(serial=udid, autopair=False, pairing_records_cache_folder=Path(cache))
            ld.pair_record = None
            ld.host_id = str(uuid.uuid4()).upper()
            await ld.pair(timeout=120)
            # The phone reaches itself through the loopback VPN, which lockdownd
            # treats as a network connection, and it refuses network sessions
            # unless Wi-Fi connections are on - the broken pipe on the phone.
            if await ld.validate_pairing():
                await ld.set_enable_wifi_connections(True)
            record = dict(ld.pair_record)
            record["UDID"] = udid
            if "EscrowBag" not in record:
                sys.exit("The iPhone paired but returned no escrow bag. Unlock it and export again.")
            Path(out).write_bytes(plistlib.dumps(record))

    asyncio.run(main(sys.argv[1], sys.argv[2]))
    """
}
