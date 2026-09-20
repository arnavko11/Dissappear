import SwiftUI

/// Shows what Core Location actually reports, which is how you confirm a
/// device-wide simulated location set from the macOS companion is in effect.
struct RealLocationSection: View {
    @Environment(LocationAuthorizationService.self) private var authorization

    var body: some View {
        Section {
            if let location = authorization.realLocation {
                LabeledContent("Latitude", value: String(format: "%.6f", location.coordinate.latitude))
                LabeledContent("Longitude", value: String(format: "%.6f", location.coordinate.longitude))
                LabeledContent("Accuracy", value: String(format: "%.0f m", location.horizontalAccuracy))
                LabeledContent("Reported", value: location.timestamp.formatted(date: .omitted, time: .standard))
            } else if authorization.isAuthorized {
                Text("Waiting for a fix…").foregroundStyle(.secondary)
            } else {
                Button("Allow Location Access") { authorization.requestAuthorization() }
            }
        } header: {
            Text("Device Location")
        } footer: {
            Text("What iOS reports to every app. If the macOS companion has set a simulated location, this shows it — that is how you tell the spoof is working. The in-app simulation on the Simulation tab does not change this.")
        }
        .task {
            authorization.requestAuthorization()
            authorization.startUpdates()
        }
    }
}

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
