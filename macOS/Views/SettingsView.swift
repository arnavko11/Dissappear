import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: CompanionModel
    @State private var isChoosingProject = false

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

            Section("Project") {
                LabeledContent("Xcode Project") {
                    HStack {
                        Text(model.configuration.projectPath.isEmpty ? "Not selected" : model.configuration.projectPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(model.configuration.isConfigured ? .primary : .secondary)
                        Button("Choose…") { isChoosingProject = true }
                    }
                }
                LabeledContent("Scheme", value: model.configuration.scheme)
                LabeledContent("Configuration", value: model.configuration.configuration)
                LabeledContent("Derived Data") {
                    Text(model.configuration.derivedDataPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section("Signing") {
                Picker("Development Team", selection: $model.selectedIdentityID) {
                    if model.identities.isEmpty {
                        Text("No Apple Development identity").tag(Optional<String>.none)
                    }
                    ForEach(model.identities) { identity in
                        Text(identity.displayName).tag(Optional(identity.id))
                    }
                }
                LabeledContent("Provisioning Profiles", value: "\(model.profiles.count) installed")
                Text("Certificates, device registration and provisioning profiles are created and renewed by Xcode. This companion only reads them and passes your team to xcodebuild with automatic signing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
}
