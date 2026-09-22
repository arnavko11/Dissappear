import SwiftUI

@main
struct DissappearCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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
                .task {
                    delegate.model = model
                    await model.refreshAll()
                }
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


/// Holds quitting open long enough to end the spoofing session.
///
/// A tool process outlives the app that started it, and terminating it is
/// what puts the real location back, so quitting without waiting would leave
/// the phone reporting a lie that nothing could then correct. A notification
/// observer is not enough: the app is gone before the work runs.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the scene appears; only ever touched on the main thread.
    var model: CompanionModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }

        Task { @MainActor in
            await model.shutDown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
