import MapKit
import SwiftUI

struct RootView: View {
    @Environment(MainViewModel.self) private var main
    @Environment(RouteEditorViewModel.self) private var routeEditor
    @Environment(LocationSearchService.self) private var searchService
    @Environment(SpoofingCoordinator.self) private var spoofing
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var context
    @AppStorage(PreferenceKey.didCompleteOnboarding) private var didCompleteOnboarding = false
    @State private var isLibraryPresented = false
    @State private var isSettingsPresented = false
    @State private var isOnboardingPresented = false
    @State private var isConnectionPresented = false
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
        .sheet(isPresented: $isConnectionPresented) {
            NavigationStack { ConnectionView() }
        }
        .fullScreenCover(isPresented: $isOnboardingPresented) {
            OnboardingView()
        }
        .alert(main.error?.title ?? "Error", isPresented: isErrorPresented, presenting: main.error) { _ in
            Button("OK", role: .cancel) { main.error = nil }
        } message: { error in
            Text(error.message)
        }
        // A failed spoof is said on the map, where it was asked for — it used
        // to be visible only inside Settings.
        .alert("Could Not Spoof", isPresented: Binding(
            get: { spoofing.lastFailure != nil && !isConnectionPresented },
            set: { if !$0 { spoofing.lastFailure = nil } })) {
            Button("Connection") { spoofing.lastFailure = nil; isConnectionPresented = true }
            Button("OK", role: .cancel) { spoofing.lastFailure = nil }
        } message: {
            Text(spoofing.lastFailure ?? "")
        }
        .onChange(of: main.previewPlace) { _, place in
            // Picking a place closes the library so the map, the pin and its
            // Spoof button are in view.
            if place != nil, sizeClass != .regular { isLibraryPresented = false }
        }
        .task {
            // Nobody should reach the map without being told what this app does.
            if !didCompleteOnboarding { isOnboardingPresented = true }
        }
    }

    private var workspace: some View {
        SpoofMapView(onMapTap: handleMapTap, onWaypointTap: handleWaypointTap)
            .ignoresSafeArea(edges: sizeClass == .regular ? [] : .top)
            .overlay { crosshair }
            .overlay(alignment: .topTrailing) {
                MapOverlayControls()
                    .padding(.trailing, 12)
                    .padding(.top, 12)
            }
            .overlay(alignment: .top) { tapModeBanner }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let place = main.previewPlace { placeCard(place) }
                    SimulationBar()
                }
            }
            .navigationTitle("Dissappear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
    }

    /// Marks the spot Spoof Here uses.
    private var crosshair: some View {
        Image(systemName: "plus")
            .font(.title3.weight(.light))
            .foregroundStyle(.primary.opacity(0.7))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func placeCard(_ place: PlaceResult) -> some View {
        PreviewCard(place: place)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { main.previewPlace = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("Close")
            }
            .glassPanel(cornerRadius: 22)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { isConnectionPresented = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: spoofing.canSpoof ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(spoofing.canSpoof ? Color.green : Color.orange)
                    Text(connectionTitle).font(.footnote)
                }
            }
            .accessibilityLabel("Connection: \(connectionTitle)")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if sizeClass != .regular {
                Button { isLibraryPresented = true } label: {
                    Label("Library", systemImage: "sidebar.leading")
                }
            }
            Menu {
                Button {
                    isConnectionPresented = true
                } label: {
                    Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    isOnboardingPresented = true
                } label: {
                    Label("What This App Does", systemImage: "questionmark.circle")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var connectionTitle: String {
        switch spoofing.route {
        case .onDevice: return "This iPhone"
        case .companion: return "Mac"
        case .unavailable: return "Set Up"
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
        case .inspect, .dropPin:
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
