import SwiftUI

struct RoutesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var selection = Set<UUID>()
    @State private var isAdding = false

    var body: some View {
        Table(store.library.routes, selection: $selection) {
            TableColumn("Name") { Text($0.name) }
            TableColumn("Waypoints") { Text("\($0.waypoints.count)") }
            TableColumn("Speed") { Text(String(format: "%.1f m/s", $0.speed)) }
            TableColumn("Loops") { Text($0.loops ? "Yes" : "No").foregroundStyle(.secondary) }
        }
        .navigationTitle("Routes")
        .toolbar {
            ToolbarItemGroup {
                Button { isAdding = true } label: { Label("Add", systemImage: "plus") }
                    .disabled(store.library.locations.count < 2)
                Button(role: .destructive) {
                    store.removeRoutes(selection)
                    selection = []
                } label: { Label("Remove", systemImage: "minus") }
                    .disabled(selection.isEmpty)
            }
        }
        .sheet(isPresented: $isAdding) { AddRouteSheet() }
        .overlay {
            if store.library.routes.isEmpty {
                ContentUnavailableView("No Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                       description: Text("Create a route from two or more saved locations."))
            }
        }
    }
}

private struct AddRouteSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var speed = 3.5
    @State private var loops = false
    @State private var selected: [UUID] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "New Route", subtitle: "Waypoints are replayed in order at the chosen speed.")
            Form {
                TextField("Name", text: $name)
                Slider(value: $speed, in: 0.5...40) {
                    Text("Speed")
                } minimumValueLabel: {
                    Text("0.5")
                } maximumValueLabel: {
                    Text("40")
                }
                LabeledContent("Speed", value: String(format: "%.1f m/s", speed))
                Toggle("Loop route", isOn: $loops)

                Section("Waypoints") {
                    ForEach(store.library.locations) { location in
                        Toggle(isOn: binding(for: location.id)) {
                            Text(location.name)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("\(selected.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let ordered = selected.compactMap { id in store.library.locations.first { $0.id == id } }
                    store.addRoute(name: name.isEmpty ? "Untitled Route" : name, speed: speed, loops: loops, from: ordered)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.count < 2)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { isOn in
                    if isOn { selected.append(id) } else { selected.removeAll { $0 == id } }
                })
    }
}
