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
                if anisetteServer.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("This Mac's own anisette will be used. macOS 26 and later withhold it from apps without Apple's private entitlements, so Apple ID sign-in fails with \"MID is invalid\".",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
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

                if let address = model.controlServerAddress, let code = model.controlServerCode {
                    LabeledContent("Address", value: address)
                    LabeledContent("Pairing Code", value: code)
                    Text("Enter these in the iOS app under Remote. Keep this Mac awake and the device connected — the simulation lasts only while this app holds the session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Remote Control")
            } footer: {
                Text("Serves the location controls to your iPhone over the local network, so the Mac can stay put while you move. Requests must carry the pairing code, and nothing else is exposed.")
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

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
