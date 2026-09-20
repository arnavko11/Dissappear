import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            SimulationView()
                .tabItem { Label("Simulation", systemImage: "location.viewfinder") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "list.bullet.rectangle") }
            BuildInfoView()
                .tabItem { Label("Build", systemImage: "hammer") }
        }
    }
}
