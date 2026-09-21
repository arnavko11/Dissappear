import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: CompanionModel
    @State private var isChoosingProject = false
    @AppStorage("anisetteServer") private var anisetteServer = ""

    var body: some View {
        Form {
            Section("Developer Tools") {
                StatusRow(label: "Xcode",
                          value: model.toolchain.summary,
                          state: model.toolchain.hasXcodebuild ? .good : .bad)
                StatusRow(label: "Developer Directory",
                          value: model.toolchain.developerDirectory ?? "Not set",
                          state: model.toolchain.developerDirectory == nil ? .bad : .good)
                StatusRow(label: "devicectl",
                          value: model.toolchain.hasDeviceCtl ? "Available" : "Not available",
                          state: model.toolchain.hasDeviceCtl ? .good : .bad)
                if !model.toolchain.isReady {
                    Label("Install Xcode from the App Store, open it once to accept the license, and install the command line developer tools.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                Button("Open Xcode") { model.openXcode() }
            }

            Section {
                Picker("Development Team", selection: $model.selectedIdentityID) {
                    if model.identities.isEmpty {
                        Text("No Apple Development identity").tag(Optional<String>.none)
                    }
                    ForEach(model.identities) { identity in
                        Text(identity.displayName).tag(Optional(identity.id))
                    }
                }
                LabeledContent("Provisioning Profiles", value: "\(model.profiles.count) installed")
            } header: {
                Text("Signing")
            } footer: {
                Text("Apple issues certificates and profiles. This companion reads the ones already on this Mac, and can ask Apple for new ones from Build ▸ Apple ID Signing.")
            }

            Section {
                LabeledContent("Anisette Server") {
                    TextField("https://example.com", text: $anisetteServer)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                Button("Find One For Me") {
                    Task {
                        await model.findAnisetteServer()
                        anisetteServer = Preferences.anisetteServerString
                    }
                }
                .disabled(model.isBusy)

                if anisetteServer.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("This Mac's own anisette will be used. macOS 26 and later withhold it from apps without Apple's private entitlements, so Apple ID sign-in fails with \"MID is invalid\". Find One For Me downloads the published list of servers and picks the first that answers.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                Label("None of this is needed to spoof a location. It only affects Build ▸ Apple ID Signing, which is one of three ways to get the iPhone app installed.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Apple ID Sign-In")
            } footer: {
                Text("Only needed for Build ▸ Apple ID Signing. An anisette server computes the device attestation Apple requires, which macOS no longer provides to this app. It receives a random identifier for this Mac, so use one you run or trust. Installing with a provisioning profile needs none of this.")
            }

            Section {
                if model.configuration.isConfigured {
                    LabeledContent("Xcode Project") {
                        HStack {
                            Text(model.configuration.projectPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Change…") { isChoosingProject = true }
                        }
                    }
                    LabeledContent("Scheme", value: model.configuration.scheme)
                    LabeledContent("Configuration", value: model.configuration.configuration)
                    LabeledContent("Derived Data") {
                        Text(model.configuration.derivedDataPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    StatusRow(label: "Xcode Project", value: "Not needed", state: .inactive)
                    Button("Choose a Project…") { isChoosingProject = true }
                }
            } header: {
                Text("Build from Source (Optional)")
            } footer: {
                Text("Only for building the iOS app from its Xcode project. Installing the build bundled with this app does not use any of this — see Build ▸ Install Without Building.")
            }

            Section {
                Toggle("Allow control from iPhone", isOn: Binding(
                    get: { model.isControlServerRunning },
                    set: { $0 ? model.startControlServer() : model.stopControlServer() }))

                StatusRow(label: "Status",
                          value: model.controlServerStatus.message ?? model.controlServerStatus.label,
                          state: serverState)

                StatusRow(label: "Incoming Connections",
                          value: firewallValue,
                          state: model.firewallStatus.isBlocking ? .bad : .good)

                if model.firewallStatus.isBlocking {
                    Label("macOS is dropping the phone's connections before they reach this app, without a prompt, because this app is not signed with a Developer ID. The server will look like it is listening and the phone will never get an answer.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Allow Incoming Connections") {
                        Task { await model.allowIncomingConnections() }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let address = model.controlServerAddress, let code = model.controlServerCode {
                    LabeledContent("Address") {
                        Text(address).textSelection(.enabled)
                    }
                    LabeledContent("Pairing Code") {
                        HStack {
                            Text(code).monospaced().textSelection(.enabled)
                            Button("New Code") { model.regeneratePairingCode() }
                        }
                    }
                    StatusRow(label: "Sleep",
                              value: model.isKeepingAwake ? "Staying awake" : "Normal",
                              state: model.isKeepingAwake ? .good : .inactive)

                    if let remote = model.remoteAddress {
                        LabeledContent("Away From Home") {
                            Text("\(remote.hostName):\(model.controlServerAddress?.split(separator: ":").last.map(String.init) ?? "8787")")
                                .textSelection(.enabled)
                        }
                        Text("\(remote.provider) is set up, so this address reaches the Mac from anywhere. That covers the controls only: the Mac still has to reach the iPhone it is spoofing, over USB or the same local network. Controlling a Mac from afar is useful when the phone being spoofed stays here with it — not for the phone in your pocket.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("A mesh VPN such as Tailscale on both devices lets the controls reach this Mac from anywhere, and its address will appear here. It does not extend the spoofing itself: the Mac reaches the iPhone over USB or the local network, so the phone being spoofed has to be here. Do not forward a router port to this server instead: it speaks plain HTTP and is meant for a private network.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("Idle sleep is held off while a session is live. Closing the lid still sleeps the Mac unless it is plugged in with an external display, and this cannot stop sleep you ask for or a flat battery.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Enter these in the iOS app under Remote. Keep this Mac awake and the device connected — the simulation lasts only while this app holds the session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Remote Control")
            } footer: {
                Text("Serves the spoofing controls to your iPhone over the local network, so the Mac can stay put while you move. It is on by default. Requests must carry the pairing code, and nothing but the location controls is exposed. macOS asks permission the first time it uses the local network — allow it, or the phone will never find this Mac.")
            }

            Section("About") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Build", value: Self.build)
                StatusRow(label: "Bundled iOS Build",
                          value: model.hasBundledBuild ? (model.bundledBuildSize ?? "Included") : "Not included",
                          state: model.hasBundledBuild ? .good : .inactive)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 520)
        .fileImporter(isPresented: $isChoosingProject,
                      allowedContentTypes: [UTType(filenameExtension: "xcodeproj") ?? .package, .package, .directory]) { result in
            if case let .success(url) = result {
                model.configuration.projectPath = url.path
            }
        }
    }

    private var firewallValue: String {
        switch model.firewallStatus {
        case .off: return "Firewall off"
        case .allowed: return "Allowed"
        case .blocked: return "Blocked by the firewall"
        case .unknown: return "Unknown"
        }
    }

    private var serverState: StatusDot.State {
        switch model.controlServerStatus {
        case .running: return .good
        case .starting: return .warning
        case .failed: return .bad
        case .off: return .inactive
        }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
