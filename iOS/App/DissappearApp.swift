import SwiftUI

@main
struct DissappearApp: App {
    @StateObject private var model = SimulationModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(model)
        }
    }
}
