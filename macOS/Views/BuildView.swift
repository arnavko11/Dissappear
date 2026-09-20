import SwiftUI

struct BuildView: View {
    @EnvironmentObject private var model: CompanionModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Signing") {
                    Picker("Development Team", selection: $model.selectedIdentityID) {
                        if model.identities.isEmpty {
                            Text("No Apple Development identity").tag(Optional<String>.none)
                        }
                        ForEach(model.identities) { identity in
                            Text(identity.displayName).tag(Optional(identity.id))
                        }
                    }
                    .onChange(of: model.selectedIdentityID) { _, newValue in
                        Preferences.identityID = newValue
                    }
                    if model.identities.isEmpty {
                        Label("Sign in with your Apple ID in Xcode ▸ Settings ▸ Accounts so Xcode can create a development certificate.",
                              systemImage: "person.badge.key")
                            .foregroundStyle(.secondary)
                        Button("Open Xcode") { model.openXcode() }
                    }
                    StatusRow(label: "Provisioning",
                              value: model.provisioning.displayName,
                              state: model.provisioning.profile == nil ? .warning : .good)
                    StatusRow(label: "Signing State", value: model.signingState.headline)
                }

                Section("Pipeline") {
                    ForEach(PipelineStage.allCases) { stage in
                        PipelineRow(stage: stage, state: model.stages[stage] ?? .pending)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            LogConsole(text: model.logText, activity: model.activity)
                .frame(minHeight: 170)
        }
        .navigationTitle("Build")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshBuild() }
                } label: { Label("Refresh Build", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.isBusy)

                Button {
                    Task { await model.runWorkflow() }
                } label: { Label("Build & Install", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.selectedDevice == nil)

                Menu {
                    Button("Clean Build Folder") { Task { await model.cleanBuildFolder() } }
                    Button("Open Xcode") { model.openXcode() }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.error {
                ErrorCard(error: error)
                    .padding(12)
            }
        }
    }
}

private struct PipelineRow: View {
    let stage: PipelineStage
    let state: StageState

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.rawValue)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.15), value: detail)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .pending:
            Image(systemName: stage.symbol).foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var detail: String? {
        switch state {
        case .pending: return nil
        case .running: return "In progress…"
        case let .succeeded(text), let .skipped(text), let .failed(text): return text
        }
    }
}

private struct LogConsole: View {
    let text: String
    let activity: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(activity ?? "Output")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy output")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "No output yet." : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .id("log-end")
                }
                .onChange(of: text) { _, _ in
                    proxy.scrollTo("log-end", anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
