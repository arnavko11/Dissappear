import MapKit
import SwiftUI

struct RootView: View {
    @Environment(MainViewModel.self) private var main
    @Environment(SimulationEngine.self) private var engine
    @Environment(SimulationViewModel.self) private var simulation
    @Environment(RouteEditorViewModel.self) private var routeEditor
    @Environment(LocationSearchService.self) private var searchService
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var context
    @State private var isLibraryPresented = false
    @State private var isSettingsPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    LibraryPanel()
                        .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)
                } detail: {
                    workspace
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack { workspace }
            }
        }
        .sheet(isPresented: $isLibraryPresented) {
            LibraryPanel()
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack { SettingsView() }
        }
        .alert(main.error?.title ?? "Error", isPresented: isErrorPresented, presenting: main.error) { _ in
            Button("OK", role: .cancel) { main.error = nil }
        } message: { error in
            Text(error.message)
        }
        .task { await main.beginSession() }
    }

    private var workspace: some View {
        TestMapView(onMapTap: handleMapTap, onWaypointTap: handleWaypointTap)
            .ignoresSafeArea(edges: sizeClass == .regular ? [] : .top)
            .overlay(alignment: .topTrailing) {
                MapOverlayControls()
                    .padding(.trailing, 12)
                    .padding(.top, 12)
            }
            .overlay(alignment: .top) { tapModeBanner }
            .safeAreaInset(edge: .bottom) { SimulationBar() }
            .navigationTitle("Location Tester")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            StatusIndicator(status: main.status(engine: engine))
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if sizeClass != .regular {
                Button { isLibraryPresented = true } label: {
                    Label("Library", systemImage: "sidebar.leading")
                }
            }
            Menu {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button(role: .destructive, action: resetEnvironment) {
                    Label("Reset Test Environment", systemImage: "arrow.counterclockwise.circle")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var tapModeBanner: some View {
        switch main.tapMode {
        case .inspect:
            EmptyView()
        case .dropPin:
            TapModeBanner(text: "Tap the map to drop a pin") { main.tapMode = .inspect }
        case .addWaypoint:
            TapModeBanner(text: "Tap the map to add a waypoint") { main.tapMode = .inspect }
        case .moveWaypoint:
            TapModeBanner(text: "Tap the map to move the selected waypoint") { main.tapMode = .inspect }
        }
    }

    private var isErrorPresented: Binding<Bool> {
        Binding(get: { main.error != nil }, set: { if !$0 { main.error = nil } })
    }

    private func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        switch main.tapMode {
        case .inspect:
            break
        case .dropPin:
            Task {
                let place = await searchService.describe(coordinate)
                withAnimation(.easeInOut(duration: 0.2)) { main.previewPlace = place }
                main.section = .search
            }
        case .addWaypoint:
            guard let route = main.editingRoute else {
                main.tapMode = .inspect
                return
            }
            routeEditor.addWaypoint(to: route,
                                    name: "Waypoint \(route.waypoints.count + 1)",
                                    coordinate: coordinate,
                                    context: context)
        case let .moveWaypoint(identifier):
            guard let waypoint = main.editingRoute?.waypoints.first(where: { $0.persistentModelID == identifier }) else {
                main.tapMode = .inspect
                return
            }
            routeEditor.relocate(waypoint, to: coordinate, context: context)
            main.tapMode = .inspect
        }
    }

    private func handleWaypointTap(_ waypoint: RouteWaypoint) {
        if case let .moveWaypoint(identifier) = main.tapMode, identifier == waypoint.persistentModelID {
            main.tapMode = .inspect
        } else {
            main.tapMode = .moveWaypoint(waypoint.persistentModelID)
        }
    }

    /// Returns the app to its default test environment.
    private func resetEnvironment() {
        simulation.resetSession()
        withAnimation(.easeInOut(duration: 0.2)) {
            main.previewPlace = nil
            main.editingRoute = nil
            main.tapMode = .inspect
            main.camera = .region(.defaultTestRegion)
        }
    }
}

private struct TapModeBanner: View {
    let text: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap").imageScale(.small)
            Text(text).font(.footnote)
            Button("Cancel", action: onCancel)
                .font(.footnote.weight(.medium))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassCapsule()
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}
