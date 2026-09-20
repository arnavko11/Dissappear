# Dissappear

A two-target Apple project:

| Target | Platform | Role |
| --- | --- | --- |
| `Dissappear` | iOS 17+ | Location-simulation **test app** (in-app simulation only) |
| `DissappearCompanion` | macOS 14+ | SwiftUI **control center** that prepares, builds, signs, installs and manages the development build |

Open `Dissappear.xcodeproj` in Xcode 16 or later.

## What the companion does

The companion orchestrates Apple's own developer tooling — it never re-implements
signing, never handles an Apple ID password, and never works around the
development-signing lifetime.

```
Connect iPhone → Developer Mode → Signing identity → Prepare → Build
→ Code sign → Provision → Install → Launch
```

Each stage is shown in **Build** with its own state, and every failure is
translated into a title, a plain-language explanation, a recommended action and
an expandable **Technical Details** section containing the exact command and its
output.

### Apple tools used

| Tool | Used for |
| --- | --- |
| `xcode-select`, `xcodebuild -version`, `xcrun --find` | Toolchain detection, graceful degradation |
| `xcrun devicectl list devices` | Device name, model, iOS version, Developer Mode, pairing state |
| `xcodebuild … -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic` | Build, code signing, certificate/profile/device registration (managed by Xcode) |
| `codesign -dv` | Reading the signing authority applied to the built product |
| `security find-identity`, `security cms -D` | Listing Apple Development identities and reading installed provisioning profiles |
| `xcrun devicectl device install/launch/uninstall/info apps` | Install, launch, remove, installed-state |

All process invocation lives in `macOS/Utilities/ProcessRunner.swift`; views never
shell out.

### Development signing lifecycle

The companion reads the expiration date from the embedded provisioning profile
and reports **Signed / Installed / Expiration / Days remaining / Needs rebuild**.
When the period lapses, **Refresh Build** re-runs prepare → build → sign →
provision → install through the same supported tooling. Nothing attempts to
extend or bypass Apple's limits.

### When Apple requires you

The companion detects and explains, rather than working around:

- Xcode or the command line developer tools missing
- No Apple Development certificate (sign in under Xcode ▸ Settings ▸ Accounts)
- Developer Mode off (Settings ▸ Privacy & Security ▸ Developer Mode on the iPhone)
- Device not trusted / not paired
- Device not registered in a provisioning profile
- Locked device during install

## iOS app — Location Tester

A native SwiftUI location-testing tool for developers. All simulation happens
inside this app's own testing surfaces: it does not hook into Core Location's
system providers, does not modify system location services, and never changes
what any other app receives.

**Map-first workspace.** A MapKit map fills the content area (standard, hybrid
or satellite, with zoom and recentre controls). On iPad it sits in a
`NavigationSplitView` beside the library; on iPhone the library is a detented
sheet. A persistent bottom bar shows the current simulated coordinate and the
transport controls.

**Locations.** Search addresses, businesses, cities and landmarks with
`MKLocalSearchCompleter` (debounced, updating as you type), enter a coordinate
directly in the search field or the manual latitude/longitude fields, or drop a
pin on the map (reverse geocoded for a readable name). Selected places show
name, address and coordinate with **Set Test Location**, **Save** and **Add
Waypoint** actions. Saved locations support favourites and deletion.

**Routes.** Add waypoints from the map or from saved locations, reorder by
dragging, delete, move a waypoint by selecting it and tapping the map, reverse,
clear, and set base speed and looping. Routes show waypoint count, total
distance and estimated duration, drawn as a polyline with numbered waypoints.

**Simulation.** `SimulationEngine` interpolates along the route at 5–60 Hz with
start, pause, resume, stop and restart, and 0.25× to 10× speed. Progress,
remaining distance and estimated time remaining update live; the marker
animates between fixes unless Reduce Motion is on.

**Scenarios.** Pair a route with a speed for a repeatable run — create, edit,
rename, duplicate, delete and run.

**Session state.** A compact indicator reports Disconnected, Connecting,
Connected, Simulation Running, Simulation Paused or Error using a symbol and
text, never colour alone. **Reset Test Environment** returns everything to the
default state.

**Persistence.** SwiftData stores saved locations, routes, waypoints and
scenarios; preferences (map style, default speed, units, appearance, update
frequency, marker animation) live in `@AppStorage`. On first launch the library
prepared by the macOS companion and embedded in the build is imported.

**Settings.** General (default map style, default speed, distance units),
Appearance (system/light/dark), Simulation (update frequency, marker
animation), Real Location (Core Location authorization, optional) and About
(version, build, provisioning profile and days remaining).

Accessibility: Dynamic Type throughout, VoiceOver labels/values/hints on the
map, transport and rows, Reduce Motion respected, and hardware-keyboard support
for the transport controls.

## Layout

```
Shared/    SimulationModels.swift (both targets)
iOS/       App/ Models/ Services/ ViewModels/ Components/ Resources/
           Views/MainWindow Views/Sidebar Views/Map Views/Locations
           Views/Routes Views/Scenarios Views/SimulationControls Views/Settings
macOS/     App/ Views/ ViewModels/ Services/ Models/
           Signing/ Devices/ Build/ Installation/ Utilities/
```

The iOS app follows MVVM: SwiftData models, services (`SimulationEngine`,
`LocationSearchService`, `PersistenceService`, `LocationAuthorizationService`),
`@Observable` view models, and small views that only read state and call
intents.

`Services/` holds `ToolchainService`, `DeviceService`, `SigningService`,
`BuildService` and `InstallationService`. `CompanionModel` sequences them into
the pipeline; SwiftUI views only read state and call intents.

## Setup

1. Install Xcode and open it once to accept the license.
2. Xcode ▸ Settings ▸ Accounts: sign in with your Apple ID so Xcode can create a
   development certificate and manage provisioning.
3. Connect an iPhone over USB, unlock it and tap **Trust**.
4. Enable Developer Mode on the iPhone if prompted.
5. Run the `DissappearCompanion` scheme, pick your development team in
   **Build**, then **Build & Install**.

In Settings the companion defaults to the repository it was compiled from; choose
`Dissappear.xcodeproj` manually if you move it.

The companion runs unsandboxed (`ENABLE_APP_SANDBOX = NO`) because it drives
command line developer tools; it is meant to be run from your own build.
