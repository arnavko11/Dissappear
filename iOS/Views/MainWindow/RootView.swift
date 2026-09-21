import MapKit
import SwiftUI

struct RootView: View {
    @Environment(MainViewModel.self) private var main
    @Environment(SimulationEngine.self) private var engine
    @Environment(SimulationViewModel.self) private var simulation
    @Environment(RouteEditorViewModel.self) private var routeEditor
    @Environment(LocationSearchService.self) private var searchService
    @Environment(RemoteControlClient.self) private var client
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.modelContext) private var context
    @AppStorage(PreferenceKey.didCompleteOnboarding) private var didCompleteOnboarding = false
    @State private var isLibraryPresented = false
    @State private var isSettingsPresented = false
    @State private var isOnboardingPresented = false
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
        .fullScreenCover(isPresented: $isOnboardingPresented) {
            OnboardingView()
        }
        .alert(main.error?.title ?? "Error", isPresented: isErrorPresented, presenting: main.error) { _ in
            Button("OK", role: .cancel) { main.error = nil }
        } message: { error in
            Text(error.message)
        }
        .task {
            // Nobody should reach the map without being told what this app does.
            if !didCompleteOnboarding { isOnboardingPresented = true }
            await main.beginSession()
        }
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
            .overlay(alignment: .bottom) { disconnectedBanner }
            .safeAreaInset(edge: .bottom) { SimulationBar() }
            .navigationTitle("Dissappear")
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
                Button {
                    isOnboardingPresented = true
                } label: {
                    Label("What This App Does", systemImage: "questionmark.circle")
                }
                Divider()
                Button(role: .destructive, action: resetEnvironment) {
                    Label("Reset Spoofed Location", systemImage: "arrow.counterclockwise.circle")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    /// Without a companion there is no device to spoof, so the app says so
    /// rather than offering controls that would only move a dot in here.
    @ViewBuilder
    private var disconnectedBanner: some View {
        if let reason = client.unavailableReason {
            Button {
                main.section = .remote
                isLibraryPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Not spoofing").font(.footnote.weight(.semibold))
                        Text(reason).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .glassPanel(cornerRadius: 16)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
        Task { await client.clearLocation() }
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
