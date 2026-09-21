import CoreLocation
import SwiftData
import SwiftUI

struct SavedLocationsPanel: View {
    @Environment(SpoofingCoordinator.self) private var spoofing
    @Environment(MainViewModel.self) private var main
    @Environment(RouteEditorViewModel.self) private var routeEditor
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedLocation.createdAt, order: .reverse) private var locations: [SavedLocation]

    /// Favourites first, then most recently added.
    private var sortedLocations: [SavedLocation] {
        locations.sorted { lhs, rhs in
            lhs.isFavorite == rhs.isFavorite ? lhs.createdAt > rhs.createdAt : lhs.isFavorite
        }
    }

    var body: some View {
        List {
            if let place = main.previewPlace {
                Section("Selected") { PreviewCard(place: place) }
            }

            Section {
                ForEach(sortedLocations) { location in
                    Button { preview(location) } label: {
                        SavedLocationRow(location: location, isSelected: isPreviewed(location))
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            location.isFavorite.toggle()
                            save()
                        } label: {
                            Label(location.isFavorite ? "Unfavorite" : "Favorite",
                                  systemImage: location.isFavorite ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            context.delete(location)
                            save()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button("Spoof This Location") {
                            spoof(location.coordinate, name: location.name)
                        }
                        .disabled(!spoofing.canSpoof)
                        if let route = main.editingRoute {
                            Button("Add to \(route.name)") {
                                routeEditor.addWaypoint(to: route,
                                                        name: location.name,
                                                        coordinate: location.coordinate,
                                                        context: context)
                            }
                        }
                    }
                }
            } footer: {
                if !locations.isEmpty {
                    Text("Swipe a location to favourite or delete it.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if locations.isEmpty {
                EmptyStateView(title: "No Saved Locations",
                               message: "Search for a place or drop a pin, then save it for reuse.",
                               systemImage: "mappin.slash",
                               actionTitle: "Search") { main.section = .search }
            }
        }
    }

    private func isPreviewed(_ location: SavedLocation) -> Bool {
        guard let place = main.previewPlace else { return false }
        return abs(place.coordinate.latitude - location.latitude) < 0.00001
            && abs(place.coordinate.longitude - location.longitude) < 0.00001
    }

    private func preview(_ location: SavedLocation) {
        withAnimation(.easeInOut(duration: 0.2)) {
            main.previewPlace = PlaceResult(name: location.name,
                                            address: location.address,
                                            coordinate: location.coordinate)
        }
        main.focus(on: location.coordinate)
    }

    /// Every location change goes to the companion. Setting one only inside
    /// this app would claim a position the phone is not actually reporting.
    private func spoof(_ coordinate: CLLocationCoordinate2D, name: String?) {
        main.focus(on: coordinate)
        Task {
            await spoofing.spoof(latitude: coordinate.latitude,
                                 longitude: coordinate.longitude,
                                 name: name)
        }
    }

    private func save() {
        do {
            try PersistenceService(context: context).save()
        } catch {
            main.present(AppError(title: "Could Not Save Changes", message: error.localizedDescription))
        }
    }
}
