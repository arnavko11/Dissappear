import SwiftUI

struct LocationsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var selection = Set<UUID>()
    @State private var isAdding = false

    var body: some View {
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
                                       description: Text("Add a coordinate to use in fixed-position scenarios."))
            }
        }
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
