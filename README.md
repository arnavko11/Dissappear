# Dissappear

**Dissappear spoofs the location your iPhone reports.** You pick a point
anywhere on Earth, and the phone says it is there — to every app on it, not
just this one. That is what it is for.

It does this through Apple's own developer location service, the one behind
Xcode's Simulate Location. That means it is visible to whoever holds the phone
(Developer Mode has to be switched on by hand) and it is never hidden from
them. No jailbreak, nothing patched. Spoof phones you own.

| Target | Platform | Role |
| --- | --- | --- |
| `Dissappear` | iOS 17+ | The phone app: pick places, walk routes, and — with a pairing record — spoof this phone on its own |
| `DissappearCompanion` | macOS 14+ | The Mac app: sets up the tooling, holds a spoofing session, serves the controls to the phone |

Open `Dissappear.xcodeproj` in Xcode 26 or later. Before building the iOS app,
run `Scripts/fetch-idevice.sh` once — it downloads the library the phone uses to
drive its own developer services. It is about 190 MB a slice, so it is fetched
rather than committed, and `Vendor/` is ignored.

## Two ways to reach the phone

Either way the spoof is device-wide: every app on the phone sees it.

| Route | Needs | Works |
| --- | --- | --- |
| **On the phone itself** | A pairing record, and a loopback VPN | Anywhere, no computer present |
| **Through the Mac companion** | The Mac to reach the phone over USB or the local network | Only while both are together |

The phone's own route is preferred whenever a pairing record is imported *and*
the loopback VPN is answering. If the VPN is off, the app falls back to the Mac
rather than pretending it can work.

**A spoof lasts exactly as long as the session holding it.** The tool clears the
location as it closes that session, so Stop Spoofing and quitting the companion
both restore real GPS. Unplugging breaks the session rather than closing it,
which can leave the phone stuck on the last coordinate — stop before you
disconnect.

## Getting started

Install the macOS companion from the `.pkg` in the
[latest release](../../releases/latest), open it, and follow **Setup**. It
checks each thing the developer location service needs, in order, and fixes
what it can by itself:

1. **Xcode** — linked straight to its App Store page
2. **pymobiledevice3** — installed automatically into a private folder the app owns, no password, nothing else on the Mac touched
3. **An iPhone** — connected, unlocked, trusting this Mac
4. **Developer Mode** — on the phone, under Settings ▸ Privacy & Security
5. **A way in** — worked out on first use; see below
6. **Pairing** — remote control is on by default; type its code into the phone app

Then open **Locations**, pick anywhere, and the phone is there.

### How the Mac reaches the phone

Four routes are tried in turn, cheapest and least invasive first, and the one
that works is remembered. A password is never asked for on a guess.

| Route | Needs | Notes |
| --- | --- | --- |
| `--native` | macOS | Rides Apple's own tunnel through `remotepairingd`. No root, and `remoted` keeps running, so Xcode and `devicectl` still work |
| `--userspace` | nothing | An iOS 17+ tunnel built in-process in pure Python. No root, just slower |
| plain lockdown | nothing | All that iOS 16 and earlier need |
| `tunneld` | an administrator password | Last resort. Installed as a launchd daemon, so it survives a restart. Start it from **Devices** |

Each route can find the phone over Bonjour instead of USB, so turning on Wi-Fi
sync in Finder keeps the Mac in touch without a cable.

## Spoofing with no computer at all

iOS only opens its developer services to something the device already trusts,
and that trust is established by a computer — once. After that the phone can do
it alone, which is how this works away from home.

1. In the companion, under **Devices**, choose **Export Pairing Record**. Keep
   the file private: anything holding it can reach that device's developer
   services.
2. On the phone, install and connect a loopback VPN — [StosVPN] or
   LocalDevVPN. This app ships neither and will never ask you to add a VPN
   configuration. iOS forbids an app from reaching its own device's services
   directly, so one of those has to publish a local address that routes back.
3. In Dissappear's Settings, **Import Pairing Record**. The **Spoofing Through**
   row should then read *This iPhone*.

If the connection is refused, the loopback address in Settings is the first
thing to check — the default is StosVPN's.

[StosVPN]: https://github.com/StephenDev0/StosVPN

> **Status:** the on-device path compiles and links but has never been run
> against hardware. The transports, the loopback default and the whole FFI
> chain are reasoned about, not observed.

## The iPhone app

A SwiftUI map workspace. Nothing in it can change a location without one of the
two routes above: there is no in-app-only mode, because a position this app
believed in privately would look like spoofing without being it.

**Locations.** Search addresses and places with `MKLocalSearchCompleter`, enter
a coordinate directly, or drop a pin (reverse geocoded for a readable name).
Save favourites.

**Routes.** Add waypoints from the map or saved locations, reorder by dragging,
move one by selecting it and tapping the map, reverse, clear, set base speed and
looping. Drawn as a polyline with numbered waypoints.

**Walking a route.** The engine interpolates along the route and acts as the
clock. Through the companion the whole track is handed over and replayed in one
session; on the phone's own route the points are streamed, which is affordable
there because the connection is held open between them.

**Scenarios.** A route paired with a speed, for a repeatable run.

**Remote.** Finds companions over Bonjour, takes the pairing code, and reports
what the Mac can see. Every request carries the code, and nothing but the
location controls is exposed.

Accessibility: Dynamic Type throughout, VoiceOver labels on the map, transport
and rows, Reduce Motion respected, hardware-keyboard support for the transport.

## Getting the iPhone app onto a phone

Three ways, all ending in a build signed by Apple-issued credentials. None works
around the development-signing lifetime.

| Path | Needs | Good for |
| --- | --- | --- |
| **Build from source** | Xcode | Working on the app itself |
| **Bundled build + your own profile** | Command Line Tools, an install tool, a `.mobileprovision` | Installing without Xcode when you have a profile |
| **Bundled build + Apple ID** | Command Line Tools, an install tool | Installing with nothing but an Apple ID |

Only the Apple ID path needs an anisette server, and **Settings ▸ Find One For
Me** picks a working one from the published list.

Release builds embed the prebuilt iOS app, so there is no project to check out.
The companion re-signs it and installs through whichever tool is present:
`devicectl` (Xcode), `cfgutil` (Apple Configurator) or `ideviceinstaller`
(libimobiledevice). Device discovery falls back to libimobiledevice when
`devicectl` is missing, and the Devices screen tells "no iPhone attached" apart
from "attached but Xcode's tooling cannot see it" by reading the USB bus.

### Apple ID signing

**Build ▸ Apple ID Signing** obtains the same certificate and profile Xcode's
Accounts pane would. The password completes Apple's SRP exchange on this Mac and
is never written to disk, logged, or sent to Apple — SRP is zero-knowledge, so
Apple receives a proof. Only the session token is persisted, in the Keychain;
the private key is generated by the Security framework and never leaves it.

A free Apple ID gives a 7-day signature and a limited number of App IDs, and the
first launch needs Settings ▸ General ▸ VPN & Device Management on the iPhone to
trust the developer.

> **Status:** the Apple ID path compiles but has not been exercised against
> Apple's servers.

## When Apple requires you

The companion detects and explains, rather than working around:

- Xcode or the command line developer tools missing
- No Apple Development certificate
- Developer Mode off
- Device not trusted, not paired, or locked during install
- Device not registered in a provisioning profile
- A device paired for Finder sync but never prepared for development — a
  separate pairing, which is why Finder can show an iPhone the companion cannot
  use until you connect it once in Xcode ▸ Window ▸ Devices and Simulators
- macOS blocking incoming connections to the companion, which is silent: the
  server binds and the phone's packets never arrive

Every failure is translated into a title, a plain-language explanation, a
recommended action, and the exact command and output behind it — with **Copy
Details** for the whole thing.

## Layout

```
Shared/    SimulationModels.swift, GlassStyling.swift (both targets)
Scripts/   fetch-idevice.sh, build-check.sh
iOS/       App/ Models/ Services/ ViewModels/ Components/ Resources/ Support/
           Views/MainWindow Views/Sidebar Views/Map Views/Locations
           Views/Routes Views/Scenarios Views/SimulationControls
           Views/Settings Views/Remote Views/Onboarding
macOS/     App/ Views/ ViewModels/ Services/ Devices/ Build/
           Installation/ Signing/ Utilities/ Resources/
```

Both apps keep views thin: they read state and call intents. `CompanionModel`
sequences the macOS services; `SpoofingCoordinator` decides which route a
location change takes on iOS. All process invocation lives in
`macOS/Utilities/ProcessRunner.swift` — views never shell out.

## Building

```
Scripts/fetch-idevice.sh     # once, before the iOS app will link
Scripts/build-check.sh       # both schemes, the way CI does
```

The companion runs unsandboxed (`ENABLE_APP_SANDBOX = NO`) because it drives
command line developer tools.
