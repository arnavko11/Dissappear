import SwiftData
import SwiftUI

@main
struct DissappearApp: App {
    @AppStorage(PreferenceKey.appearance) private var appearanceRaw = AppearanceOption.system.rawValue
    @AppStorage(PreferenceKey.defaultSpeed) private var defaultSpeed = 1.0
    @AppStorage(PreferenceKey.updateFrequency) private var updateFrequency = 20.0

    @State private var main = MainViewModel()
    @State private var engine: SimulationEngine
    @State private var simulation: SimulationViewModel
    @State private var searchService = LocationSearchService()
    @State private var routeEditor = RouteEditorViewModel()
    @State private var authorization = LocationAuthorizationService()
    @State private var remoteControl = RemoteControlClient()
    private let bridge = RemoteLocationBridge()

    private let container: ModelContainer

    init() {
        let engine = SimulationEngine()
        _engine = State(initialValue: engine)
        _simulation = State(initialValue: SimulationViewModel(engine: engine))
        container = Self.makeContainer()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(main)
                .environment(engine)
                .environment(simulation)
                .environment(searchService)
                .environment(routeEditor)
                .environment(authorization)
                .environment(remoteControl)
                .preferredColorScheme(AppearanceOption(rawValue: appearanceRaw)?.colorScheme)
                .task {
                    engine.speedMultiplier = defaultSpeed
                    engine.updateFrequency = updateFrequency
                    PersistenceService(context: container.mainContext).seedIfNeeded()
                }
                .task {
                    // A playing route drives the real device, not a dot in here.
                    await bridge.run(engine: engine, client: remoteControl)
                }
        }
        .modelContainer(container)
    }

    private static let models: [any PersistentModel.Type] = [
        SavedLocation.self, TestRoute.self, RouteWaypoint.self, TestScenario.self
    ]

    /// Falls back to an in-memory store so a damaged on-disk store cannot make
    /// the app unlaunchable; saved data is then session-only.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema(models)
        if let container = try? ModelContainer(for: schema) {
            return container
        }
        if let container = try? ModelContainer(for: schema,
                                               configurations: ModelConfiguration(isStoredInMemoryOnly: true)) {
            return container
        }
        fatalError("Unable to create a SwiftData container for the location library.")
    }
}
