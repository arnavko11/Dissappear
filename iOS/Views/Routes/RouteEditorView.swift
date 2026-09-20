import SwiftData
import SwiftUI

struct RouteEditorView: View {
    @Environment(MainViewModel.self) private var main
    @Environment(SimulationViewModel.self) private var simulation
    @Environment(RouteEditorViewModel.self) private var editor
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKey.distanceUnit) private var distanceUnitRaw = DistanceUnit.automatic.rawValue
    @Query(sort: \SavedLocation.name) private var savedLocations: [SavedLocation]

    @Bindable var route: TestRoute

    var body: some View {
        List {
            Section("Route") {
                TextField("Name", text: $route.name)
                    .onChange(of: route.name) { _, _ in save() }
                LabeledContent("Speed") {
                    Stepper(value: $route.baseSpeed, in: 0.5...120, step: 0.5) {
                        Text(speedLabel)
                            .monospacedDigit()
                    }
                    .onChange(of: route.baseSpeed) { _, _ in save() }
                }
                Toggle("Loop Route", isOn: $route.loops)
                    .onChange(of: route.loops) { _, _ in save() }
            }

            Section("Statistics") {
                LabeledContent("Waypoints", value: "\(route.waypoints.count)")
                LabeledContent("Total Distance", value: formatting.distance(route.totalDistance))
                LabeledContent("Estimated Duration", value: formatting.duration(route.estimatedDuration))
            }

            Section {
                if route.waypoints.isEmpty {
                    Text("No waypoints yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(route.orderedWaypoints.enumerated()), id: \.element.id) { index, waypoint in
                        WaypointRow(index: index + 1, waypoint: waypoint, isMoveTarget: isMoveTarget(waypoint))
                            .contentShape(Rectangle())
                            .onTapGesture { beginMove(waypoint) }
                    }
                    .onMove { offsets, destination in
                        editor.move(in: route, from: offsets, to: destination, context: context)
                    }
                    .onDelete { offsets in
                        editor.delete(from: route, at: offsets, context: context)
                    }
                }
            } header: {
                Text("Waypoints")
            } footer: {
                Text("Drag to reorder. Tap a waypoint, then tap the map to move it.")
            }

            Section("Add Waypoint") {
                Button {
                    main.editingRoute = route
                    main.tapMode = .addWaypoint
                    dismiss()
                } label: {
                    Label("Add from Map", systemImage: "hand.tap")
                }

                Menu {
                    if savedLocations.isEmpty {
                        Text("No saved locations")
                    }
                    ForEach(savedLocations) { location in
                        Button(location.name) {
                            editor.addWaypoint(to: route,
                                               name: location.name,
                                               coordinate: location.coordinate,
                                               context: context)
                        }
                    }
                } label: {
                    Label("Add Saved Location", systemImage: "mappin.and.ellipse")
                }
            }

            Section {
                Button {
                    editor.reverse(route, context: context)
                } label: {
                    Label("Reverse Route", systemImage: "arrow.left.arrow.right")
                }
                .disabled(route.waypoints.count < 2)

                Button(role: .destructive) {
                    editor.clearWaypoints(of: route, context: context)
                } label: {
                    Label("Clear Waypoints", systemImage: "trash")
                }
                .disabled(route.waypoints.isEmpty)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(route.name.isEmpty ? "Route" : route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    main.editingRoute = route
                    main.frame(coordinates: route.coordinates)
                    simulation.run(route: route)
                    dismiss()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(route.waypoints.count < 2)
            }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        .onAppear {
            main.editingRoute = route
            if !route.coordinates.isEmpty { main.frame(coordinates: route.coordinates) }
        }
        .alert(editor.lastError?.title ?? "Error", isPresented: isErrorPresented, presenting: editor.lastError) { _ in
            Button("OK", role: .cancel) { editor.dismissError() }
        } message: { error in
            Text(error.message)
        }
    }

    private var formatting: MeasurementFormatting {
        MeasurementFormatting(unit: DistanceUnit(rawValue: distanceUnitRaw) ?? .automatic)
    }

    private var speedLabel: String {
        "\(route.baseSpeed.formatted(.number.precision(.fractionLength(0...1)))) m/s"
    }

    private var isErrorPresented: Binding<Bool> {
        Binding(get: { editor.lastError != nil }, set: { if !$0 { editor.dismissError() } })
    }

    private func isMoveTarget(_ waypoint: RouteWaypoint) -> Bool {
        if case let .moveWaypoint(identifier) = main.tapMode {
            return identifier == waypoint.persistentModelID
        }
        return false
    }

    private func beginMove(_ waypoint: RouteWaypoint) {
        main.editingRoute = route
        main.tapMode = .moveWaypoint(waypoint.persistentModelID)
        main.focus(on: waypoint.coordinate)
        dismiss()
    }

    private func save() {
        try? PersistenceService(context: context).save()
    }
}

private struct WaypointRow: View {
    let index: Int
    let waypoint: RouteWaypoint
    let isMoveTarget: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(isMoveTarget ? Color.orange : Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(waypoint.name).lineLimit(1)
                Text(CoordinateParser.format(waypoint.coordinate))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isMoveTarget {
                Text("Tap map")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waypoint \(index), \(waypoint.name)")
        .accessibilityHint("Tap to move on the map")
    }
}
