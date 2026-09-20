import SwiftUI

@main
struct DissappearCompanionApp: App {
    @StateObject private var libraryStore: LibraryStore
    @StateObject private var model: CompanionModel

    init() {
        let store = LibraryStore()
        _libraryStore = StateObject(wrappedValue: store)
        _model = StateObject(wrappedValue: CompanionModel(libraryStore: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(libraryStore)
                .frame(minWidth: 940, minHeight: 620)
                .task { await model.refreshAll() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Devices") {
                    Task { await model.refreshDevices() }
                }
                .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
