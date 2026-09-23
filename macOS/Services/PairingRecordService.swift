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

        onOutputLine("Tap Trust on the iPhone when it asks.")
        let result = try await runner.run(
            Self.interpreter(for: tool.executablePath),
            ["-c", Self.pairScript, device.udid, destination.path],
            timeout: .seconds(240),
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

    /// The Python that pymobiledevice3 runs under, so the script imports the
    /// same installation.
    ///
    /// The launcher's first line is not reliable: when the environment's path
    /// has a space in it — ours lives under "Application Support" — pip writes
    /// a `#!/bin/sh` launcher that re-execs Python, and taking that line at
    /// its word ran the script through the shell. So: the Python beside the
    /// resolved launcher first (every venv, Homebrew's libexec), then the path
    /// inside a shell launcher, then the shebang, then the system Python.
    static func interpreter(for executable: String) -> String {
        let manager = FileManager.default
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        for name in ["python3", "python"] {
            let sibling = resolved.deletingLastPathComponent().appendingPathComponent(name).path
            if manager.isExecutableFile(atPath: sibling) { return sibling }
        }

        if let handle = FileHandle(forReadingAtPath: resolved.path),
           let head = try? handle.read(upToCount: 1024),
           let text = String(data: head, encoding: .utf8) {
            let lines = text.split(separator: "\n").prefix(3).map(String.init)
            // pip's shell launcher quotes the Python path after `exec`.
            for line in lines where line.contains("exec") {
                let parts = line.split(separator: "\"")
                if parts.count > 1 {
                    let candidate = String(parts[1])
                    if candidate.contains("python"), manager.isExecutableFile(atPath: candidate) {
                        return candidate
                    }
                }
            }
            if let first = lines.first, first.hasPrefix("#!") {
                let path = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if path.contains("python"), !path.contains(" "), manager.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return "/usr/bin/python3"
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

    /// Writes the file the phone spoofs itself with: the lockdown record plus
    /// a remote pairing (`public_key`, `private_key`, `identifier`) — the same
    /// layout iloader produces for StikDebug.
    ///
    /// The phone does not use lockdown to reach itself: over the loopback VPN,
    /// lockdownd hangs up on CoreDeviceProxy (the broken pipe). What works is
    /// RemotePairing on port 49152, which needs this second half. It can only
    /// be made over USB, through the trusted CoreDeviceProxy tunnel, and the
    /// phone asks to Trust once.
    static let pairScript = """
    import asyncio, plistlib, sys
    from pathlib import Path
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
    from pymobiledevice3.remote.tunnel_service import create_core_device_tunnel_service_using_rsd

    async def main(udid, out):
        ld = await create_using_usbmux(serial=udid)
        combined = dict(ld.pair_record or {})
        combined["UDID"] = udid
        for key in ("EnableWifiConnections", "EnableWifiDebugging"):
            try:
                await ld.set_value(True, "com.apple.mobile.wireless_lockdown", key)
            except Exception as error:
                print(f"Could not set {key}: {error}", file=sys.stderr)

        print("Tap Trust on the iPhone if it asks.", flush=True)
        async with UserspaceRsdTunnel(serial=udid) as rsd:
            service = await create_core_device_tunnel_service_using_rsd(rsd, autopair=True)
            record = service.pair_record
            identifier = service.identifier
            try:
                await service.close()
            except Exception:
                pass

        if not record or "private_key" not in record:
            sys.exit("The iPhone did not finish remote pairing. Unlock it, tap Trust, and export again.")
        combined["public_key"] = record["public_key"]
        combined["private_key"] = record["private_key"]
        combined["identifier"] = identifier
        if record.get("peer_alt_irk"):
            combined["alt_irk"] = record["peer_alt_irk"]
        Path(out).write_bytes(plistlib.dumps(combined))

    asyncio.run(main(sys.argv[1], sys.argv[2]))
    """
}
