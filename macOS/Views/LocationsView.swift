import SwiftUI

struct LocationsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var model: CompanionModel
    @State private var selection = Set<UUID>()
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            table
            Divider()
            DeviceLocationBar(selectedLocation: selectedLocation)
        }
    }

    private var selectedLocation: SimulatedLocation? {
        guard let id = selection.first else { return nil }
        return store.library.locations.first { $0.id == id }
    }

    private var table: some View {
        Table(store.library.locations, selection: $selection) {
            TableColumn("Name") { Text($0.name) }
            TableColumn("Latitude") { Text(String(format: "%.5f", $0.coordinate.latitude)) }
            TableColumn("Longitude") { Text(String(format: "%.5f", $0.coordinate.longitude)) }
            TableColumn("Note") { Text($0.note).foregroundStyle(.secondary) }
        }
        .navigationTitle("Locations")
        .toolbar {
            ToolbarItemGroup {
                Button { isAdding = true } label: { Label("Add", systemImage: "plus") }
                Button(role: .destructive) {
                    store.removeLocations(selection)
                    selection = []
                } label: { Label("Remove", systemImage: "minus") }
                    .disabled(selection.isEmpty)
            }
        }
        .sheet(isPresented: $isAdding) { AddLocationSheet() }
        .overlay {
            if store.library.locations.isEmpty {
                ContentUnavailableView("No Locations", systemImage: "mappin.slash",
                                       description: Text("Add a coordinate to set on the device."))
            }
        }
    }
}

/// Applies a saved location to the connected device, or restores real GPS.
struct DeviceLocationBar: View {
    @EnvironmentObject private var model: CompanionModel
    let selectedLocation: SimulatedLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusDot(state: model.deviceLocation == nil ? .inactive : .good)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.deviceLocation == nil ? "Device using real location" : "Device location simulated")
                        .font(.callout)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                Button {
                    guard let selectedLocation else { return }
                    Task {
                        await model.setDeviceLocation(latitude: selectedLocation.coordinate.latitude,
                                                      longitude: selectedLocation.coordinate.longitude,
                                                      name: selectedLocation.name)
                    }
                } label: {
                    Label("Set on Device", systemImage: "location.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedLocation == nil || !model.canSimulateDeviceLocation || model.isBusy)

                Button {
                    Task { await model.clearDeviceLocation() }
                } label: {
                    Label("Use Real Location", systemImage: "location.slash")
                }
                .disabled(!model.canSimulateDeviceLocation || model.isBusy)
            }

            if model.locationTooling.tool == nil {
                GuidanceCard(title: "Device location needs pymobiledevice3",
                             message: LocationSimulationService.installGuidance,
                             systemImage: "terminal")
            }
        }
        .padding(12)
    }

    private var statusDetail: String {
        if let coordinate = model.deviceLocation {
            let name = model.deviceLocationName.map { "\($0) · " } ?? ""
            return name + String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
        }
        guard model.selectedDevice != nil else { return "No device selected" }
        return selectedLocation == nil ? "Select a location to apply" : "Every app on the device sees this location"
    }
}

private struct AddLocationSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "New Location", subtitle: "Coordinates used by the iOS test app's simulation engine.")
            Form {
                TextField("Name", text: $name)
                TextField("Latitude", text: $latitude)
                TextField("Longitude", text: $longitude)
                TextField("Note", text: $note)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    guard let lat = Double(latitude), let lon = Double(longitude) else { return }
                    store.addLocation(name: name.isEmpty ? "Untitled" : name, latitude: lat, longitude: lon, note: note)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(Double(latitude) == nil || Double(longitude) == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
