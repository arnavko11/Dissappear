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

## iOS test app

Three tabs: **Simulation** (run a scenario and watch the simulated fix on a map),
**Library** (locations, routes, scenarios embedded in the build) and **Build**
(bundle identifier, profile, team, expiration, days remaining).

The simulation engine (`iOS/Simulation/SimulationEngine.swift`) is self-contained:
it produces fixes for this app's own testing surfaces only. It does not hook into
Core Location's system providers and does not alter location delivered to any
other app. `SystemLocationProvider` uses standard Core Location with the normal
authorization prompt for side-by-side comparison.

## Layout

```
Shared/                     SimulationModels.swift (both targets)
iOS/       App/ Views/ Simulation/ Models/ Resources/
macOS/     App/ Views/ ViewModels/ Services/ Models/
           Signing/ Devices/ Build/ Installation/ Utilities/
```

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
