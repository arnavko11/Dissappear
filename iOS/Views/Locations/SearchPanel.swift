import MapKit
import SwiftData
import SwiftUI

struct SearchPanel: View {
    @Environment(MainViewModel.self) private var main
    @Environment(LocationSearchService.self) private var service
    @Environment(\.modelContext) private var context
    @State private var model: LocationSearchViewModel?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case query, latitude, longitude }

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if model == nil { model = LocationSearchViewModel(service: service) }
            model?.updateRegion(main.visibleRegion)
        }
        .onChange(of: main.visibleRegion?.center.latitude) { _, _ in
            model?.updateRegion(main.visibleRegion)
        }
    }

    @ViewBuilder
    private func content(_ model: LocationSearchViewModel) -> some View {
        @Bindable var model = model

        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Place, address, or 30.2672, -97.7431", text: $model.query)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .focused($focusedField, equals: .query)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await model.submit() } }
                        .onChange(of: model.query) { _, _ in model.queryDidChange() }
                    if model.isResolving || service.isSearching {
                        ProgressView().controlSize(.small)
                    } else if !model.query.isEmpty {
                        Button {
                            model.reset()
                            main.previewPlace = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .accessibilityElement(children: .contain)

                if let failure = model.failure {
                    InlineMessage(text: failure, tint: .orange)
                }
            }

            if let place = main.previewPlace {
                Section("Selected") {
                    PreviewCard(place: place)
                }
            }

            if let coordinate = model.parsedCoordinate {
                Section("Coordinate") {
                    Button {
                        select(PlaceResult(name: "Coordinate",
                                           address: CoordinateParser.format(coordinate),
                                           coordinate: coordinate))
                    } label: {
                        PlaceRow(title: CoordinateParser.format(coordinate), subtitle: "Use typed coordinate")
                    }
                }
            }

            if !model.results.isEmpty {
                Section("Results") {
                    ForEach(model.results) { result in
                        Button { select(result) } label: {
                            PlaceRow(title: result.name, subtitle: result.address)
                        }
                    }
                }
            }

            if !model.completions.isEmpty {
                Section("Suggestions") {
                    ForEach(model.completions, id: \.self) { completion in
                        Button {
                            Task {
                                guard let place = await model.resolve(completion) else {
                                    main.present(AppError(title: "Could Not Resolve Place",
                                                          message: "That suggestion has no coordinate. Try a different result."))
                                    return
                                }
                                select(place)
                            }
                        } label: {
                            PlaceRow(title: completion.title, subtitle: completion.subtitle)
                        }
                    }
                }
            }

            Section("Manual Entry") {
                LabeledContent("Latitude") {
                    TextField("30.2672", text: $model.manualLatitude)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .latitude)
                }
                LabeledContent("Longitude") {
                    TextField("-97.7431", text: $model.manualLongitude)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .longitude)
                }
                if model.manualEntryHasInput && model.manualCoordinate == nil {
                    InlineMessage(text: "Enter a latitude between -90 and 90 and a longitude between -180 and 180.",
                                  tint: .orange)
                }
                Button("Preview Coordinate") {
                    guard let coordinate = model.manualCoordinate else { return }
                    select(PlaceResult(name: "Manual Coordinate",
                                       address: CoordinateParser.format(coordinate),
                                       coordinate: coordinate))
                }
                .disabled(model.manualCoordinate == nil)
            }

            Section {
                Toggle("Drop Pin on Tap", isOn: dropPinBinding)
                    .accessibilityHint("Tap the map to place a test pin")
            } footer: {
                Text("Search uses Apple Maps. Simulated locations stay inside this app.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var dropPinBinding: Binding<Bool> {
        Binding(get: { main.tapMode == .dropPin },
                set: { main.tapMode = $0 ? .dropPin : .inspect })
    }

    private func select(_ place: PlaceResult) {
        withAnimation(.easeInOut(duration: 0.2)) {
            main.previewPlace = place
        }
        main.focus(on: place.coordinate)
        focusedField = nil
    }
}

/// Details and actions for the currently previewed place.
struct PreviewCard: View {
    @Environment(MainViewModel.self) private var main
    @Environment(RemoteControlClient.self) private var client
    @Environment(RouteEditorViewModel.self) private var routeEditor
    @Environment(\.modelContext) private var context
    @Query private var savedLocations: [SavedLocation]

    let place: PlaceResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name).font(.headline)
                if !place.address.isEmpty {
                    Text(place.address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(CoordinateParser.format(place.coordinate, precision: 6))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { actionButtons }
                VStack(alignment: .leading, spacing: 8) { actionButtons }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            main.focus(on: place.coordinate)
            Task {
                await client.setLocation(latitude: place.coordinate.latitude,
                                         longitude: place.coordinate.longitude,
                                         name: place.name)
            }
        } label: {
            Label("Spoof This Location", systemImage: "location.fill")
        }
        .glassButton(prominent: true)
        .disabled(!client.canSpoof)

        Button(action: toggleSave) {
            Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "star.fill" : "star")
        }
        .buttonStyle(.bordered)

        if let route = main.editingRoute {
            Button {
                routeEditor.addWaypoint(to: route, name: place.name, coordinate: place.coordinate, context: context)
            } label: {
                Label("Add Waypoint", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    private var existing: SavedLocation? {
        savedLocations.first {
            abs($0.latitude - place.coordinate.latitude) < 0.00001
                && abs($0.longitude - place.coordinate.longitude) < 0.00001
        }
    }

    private var isSaved: Bool { existing != nil }

    private func toggleSave() {
        if let existing {
            context.delete(existing)
        } else {
            context.insert(SavedLocation(name: place.name,
                                         address: place.address,
                                         latitude: place.coordinate.latitude,
                                         longitude: place.coordinate.longitude))
        }
        do {
            try PersistenceService(context: context).save()
        } catch {
            main.present(AppError(title: "Could Not Save Location", message: error.localizedDescription))
        }
    }
}
