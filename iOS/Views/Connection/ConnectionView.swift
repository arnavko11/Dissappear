import SwiftUI
import UIKit

/// How this phone gets spoofed, and everything needed to set that up, in one
/// place reached from the status chip on the map.
struct ConnectionView: View {
    @Environment(RemoteControlClient.self) private var client
    @Environment(PairingRecordStore.self) private var pairingRecords
    @Environment(SpoofingCoordinator.self) private var spoofing
    @Environment(\.dismiss) private var dismiss
    @State private var isImportingRecord = false
    @State private var importFailure: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Spoofing Through") {
                    Text(routeDescription).foregroundStyle(.secondary)
                }
                if let reason = spoofing.unavailableReason {
                    InlineMessage(text: reason, systemImage: "exclamationmark.triangle", tint: .orange)
                }
            }

            Section {
                if pairingRecords.hasRecord {
                    LabeledContent("Pairing Record", value: "Imported")
                    LabeledContent("Loopback VPN") {
                        Text(spoofing.isLoopbackReachable ? "Connected" : "Not running")
                            .foregroundStyle(spoofing.isLoopbackReachable ? .secondary : Color.orange)
                    }
                    Button("Replace Pairing Record…") { isImportingRecord = true }
                    Button("Remove Pairing Record", role: .destructive) { pairingRecords.removeRecord() }
                } else {
                    Button("Import Pairing Record…") { isImportingRecord = true }
                }
                if let failure = pairingRecords.lastPickUpFailure {
                    InlineMessage(text: "The record the Mac sent was not usable: \(failure)",
                                  systemImage: "exclamationmark.triangle", tint: .orange)
                }
                if let failure = spoofing.lastOnDeviceFailure {
                    InlineMessage(text: failure, systemImage: "exclamationmark.triangle", tint: .orange)
                }
            } header: {
                Text("No Computer — Works Anywhere")
            } footer: {
                Text("1. Plug this iPhone into the Mac, open Dissappear Companion ▸ Devices, click Set Up iPhone Spoofing, and tap Trust here. The record arrives in this app by itself.\n2. Install StosVPN or LocalDevVPN and switch it on.\nThen this phone spoofs itself — on cellular, away from home, no Mac.")
            }

            Section {
                LabeledContent("Mac") {
                    Text(macDescription).foregroundStyle(.secondary)
                }
                if let status = client.status {
                    LabeledContent("iPhone on the Mac", value: status.device.isEmpty ? "None" : status.device)
                }
                if case .declined = client.pairing {
                    Button("Ask the Mac Again") { client.retryPairing() }
                }
            } header: {
                Text("Through the Mac")
            } footer: {
                Text("Found automatically on the same Wi-Fi — click Allow on the Mac the first time. iOS gives apps no way to talk through the cable, so this uses the local network even while plugged in.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = diagnostics
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Diagnostics", systemImage: "doc.on.doc")
                }
            } footer: {
                Text("Copies what the app knows about the connection and the last failures, with the exact step that failed. Paste it when reporting a problem. It never includes the pairing record's keys.")
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(isPresented: $isImportingRecord,
                      allowedContentTypes: [.propertyList, .xml, .data]) { result in
            guard case let .success(url) = result else { return }
            do {
                try pairingRecords.importRecord(from: url)
                Task { await spoofing.refreshLoopback() }
            } catch {
                importFailure = error.localizedDescription
            }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importFailure != nil },
            set: { if !$0 { importFailure = nil } })) {
            Button("OK", role: .cancel) { importFailure = nil }
        } message: {
            Text(importFailure ?? "")
        }
    }

    private var routeDescription: String {
        switch spoofing.route {
        case .onDevice: return "This iPhone"
        case .companion: return "The Mac"
        case .unavailable: return "Not set up"
        }
    }

    private var macDescription: String {
        switch client.pairing {
        case .searching: return "Searching…"
        case let .waitingForApproval(name): return "Click Allow on \(name)"
        case .declined: return "Not allowed"
        case .paired:
            guard let name = client.discovered?.name else { return "Searching…" }
            return client.isConnected ? name : "\(name) — not answering"
        }
    }

    private var diagnostics: String {
        let info = Bundle.main.infoDictionary ?? [:]
        var lines = [
            "Dissappear \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
            "Route: \(spoofing.routeName)",
            "Unavailable reason: \(spoofing.unavailableReason ?? "none")",
            "Loopback: \(spoofing.loopbackAddress):\(OnDeviceSpoofing.pairingPort) reachable=\(spoofing.isLoopbackReachable)",
            "Pairing record: \(pairingRecords.hasRecord ? "present" : "none"), keys: \(pairingRecords.recordKeys.joined(separator: ", "))",
            "Record pick-up failure: \(pairingRecords.lastPickUpFailure ?? "none")",
            "Mac: \(macDescription), connected=\(client.isConnected), ready=\(client.status?.ready ?? false)",
            "Last on-device failure: \(spoofing.lastOnDeviceFailure ?? "none")",
            "Recent failures:"
        ]
        lines += spoofing.failureLog.isEmpty ? ["  none"] : spoofing.failureLog.map { "  " + $0 }
        return lines.joined(separator: "\n")
    }
}
