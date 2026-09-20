import SwiftUI

struct BuildInfoView: View {
    @EnvironmentObject private var model: SimulationModel

    var body: some View {
        NavigationStack {
            List {
                Section("Application") {
                    LabeledContent("Bundle ID", value: model.buildInfo.bundleIdentifier)
                    LabeledContent("Version", value: model.buildInfo.version)
                    LabeledContent("Build", value: model.buildInfo.build)
                }

                Section("Provisioning") {
                    LabeledContent("Profile", value: model.buildInfo.profileName ?? "Not available")
                    LabeledContent("Team", value: model.buildInfo.teamIdentifier ?? "Not available")
                    LabeledContent("Type", value: model.buildInfo.isDevelopmentProfile ? "Development" : "Distribution")
                    if let expiration = model.buildInfo.expirationDate {
                        LabeledContent("Expires", value: expiration.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let days = model.buildInfo.daysRemaining {
                        LabeledContent("Days Remaining", value: "\(days)")
                    }
                } footer: {
                    Text("When the development signing period ends, rebuild and reinstall from the macOS companion.")
                }
            }
            .navigationTitle("Build")
        }
    }
}
