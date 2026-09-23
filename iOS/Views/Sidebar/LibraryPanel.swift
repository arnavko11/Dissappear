import SwiftUI

/// The sidebar content: search, saved locations and routes.
struct LibraryPanel: View {
    @Environment(MainViewModel.self) private var main

    var body: some View {
        @Bindable var main = main

        NavigationStack {
            VStack(spacing: 0) {
                Picker("Library", selection: $main.section) {
                    ForEach(LibrarySection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbolName)
                            .tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .accessibilityLabel("Library section")

                Divider()

                Group {
                    switch main.section {
                    case .search: SearchPanel()
                    case .saved: SavedLocationsPanel()
                    case .routes: RoutesPanel()
                    }
                }
                .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.18), value: main.section)
            .navigationTitle(main.section.rawValue)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
