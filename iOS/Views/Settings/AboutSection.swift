import SwiftUI

struct AboutSection: View {
    private let info = BuildInfo.current()

    var body: some View {
        Section {
            LabeledContent("Version", value: info.version)
            LabeledContent("Build", value: info.build)
            LabeledContent("Bundle Identifier", value: info.bundleIdentifier)
            if let profile = info.profileName {
                LabeledContent("Provisioning Profile", value: profile)
            }
            if let expiration = info.expirationDate {
                LabeledContent("Signing Expires",
                               value: expiration.formatted(date: .abbreviated, time: .shortened))
            }
            if let days = info.daysRemaining {
                LabeledContent("Days Remaining", value: "\(days)")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Built with SwiftUI, MapKit, Core Location and SwiftData. Development builds are prepared, signed and installed with the macOS companion using Apple's developer tooling.")
        }
    }
}
