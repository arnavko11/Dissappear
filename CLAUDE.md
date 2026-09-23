# Dissappear — working notes

## What this is

A location spoofer for iPhone. It drives Apple's own developer location service
(`com.apple.dt.simulatelocation`, behind DVT) so the phone reports a coordinate
you choose, device-wide. No jailbreak, nothing patched.

Two targets: `Dissappear` (iOS 17+) and `DissappearCompanion` (macOS 14+), one
Xcode project, `Shared/` compiled into both. Groups are
`PBXFileSystemSynchronizedRootGroup`, so **new source files need no pbxproj
edit** — dropping them in `iOS/`, `macOS/` or `Shared/` is enough.

## The two spoofing paths

| | Client | Where it runs |
| --- | --- | --- |
| Mac companion | pymobiledevice3 (Python CLI) | On the Mac, over USB or Bonjour |
| On device | idevice (Rust, linked in) | On the phone, through a loopback VPN |

`SpoofingCoordinator` (iOS) picks between them. It prefers on-device **only
when a pairing record is imported and the loopback answers** — otherwise it
falls back to the Mac. An error naming Python on a phone set up for Rust means
the request went through the Mac; that is not a bug.

## Things that cost real time to learn

**`simulate-location set` never exits.** After applying the coordinate it calls
`wait_return()`, which on macOS is `signal.sigwait([SIGINT, SIGTERM])`. The
spoof lasts exactly as long as that process lives, and terminating it clears the
location. So `set` and `play` must be **started and held** (`ProcessRunner.start`),
never `run`. Calling `run` on them hangs the app forever. `clear` and
`mounter auto-mount` do exit and use `run`.

**Everything after `--` is positional.** Device options (`--udid`, `--native`,
`--mobdev2`) must come *before* the `--` that precedes the coordinates, or the
tool rejects them as extra arguments. `attempt`/`attemptHeld` take the verb and
the trailing positional arguments separately for this reason.

**idevice's C API moves some handles and borrows others.** Freeing a moved one
is a double free; reading it is a use-after-free. Confirmed from the Rust source:

- `idevice_tcp_provider_new` **consumes** the pairing file
- `core_device_proxy_create_tcp_adapter` **consumes** the proxy — so read the
  RSD port *before* creating the adapter
- `rsd_handshake_new` **consumes** the stream
- `core_device_proxy_connect`, `remote_server_connect_rsd` and
  `location_simulation_new` **borrow**, so those handles are still ours

When touching `OnDeviceSpoofing.swift`, check the FFI source rather than
inferring ownership from the C signature.

**Export a fresh pairing, never the Mac's own record.** `lockdown
save-pair-record` hands back what usbmuxd holds, which lacks the `EscrowBag`,
and the phone then hangs up (EPIPE) on every on-device session. The export
pairs again under a new HostID (`PairingRecordService.pairScript`); reusing the
Mac's HostID would replace the Mac's own trust on the phone.

**Phone↔Mac pairing is automatic.** `POST /pair` is the only unauthenticated
endpoint; the Mac shows Allow/Don't Allow and returns the code. No address or
code UI exists on either side — don't add it back.

**The loopback VPN is a separate app.** StosVPN or LocalDevVPN. A
`NEPacketTunnelProvider` of our own needs the NetworkExtension entitlement,
which free personal teams cannot enable — which is why SideStore ships StosVPN
separately rather than bundling it.

**Rebuilding a session per coordinate does not work.** Both paths take seconds
to open one. Routes are handed to the companion whole (`POST /route`); the
on-device connection is held open between calls.

**macOS blocks incoming connections to an ad-hoc signed app silently.** The
control server binds, reports itself listening, and the phone's packets never
arrive. `FirewallService` detects this; there is no prompt to wait for.

**NWConnection parks in `.waiting`, not `.failed`**, when a connection is
refused or filtered, and retries there forever. Anything using it needs a
timeout and a `.waiting` handler, or it hangs.

## Conventions

- Views read state and call intents. All process invocation is in
  `ProcessRunner.swift`.
- Failures become `CompanionError`: title, plain-language details, recommended
  action, and the exact command and output. The alert shows the tail and offers
  **Copy Details** — collecting details and not showing them is how a dialog
  becomes a dead end.
- `ProcessRunner.run` timeouts: `defaultTimeout` 10 min, `deviceTimeout` 90 s
  for device chatter, `buildTimeout` 40 min for `xcodebuild`. The point is to
  bound an infinite hang, not to hold work to a schedule — a blanket short
  timeout kills installs and builds.
- Anything that can put the real location back must **not** be gated on
  `isBusy`. It is the way out of a wedged state.
- Comments say *why*, especially where the code looks wrong until you know the
  constraint. Several of these constraints are invisible from the call site.

## Building

```
Scripts/fetch-idevice.sh    # required once: ~190 MB, Vendor/ is gitignored
Scripts/build-check.sh      # both schemes, as CI does
```

CI (`build.yml`) runs on push and PR; `release.yml` publishes a `.pkg` on main.
The repository is public, so Actions minutes are free. macOS runners bill at
10x, so docs-only changes skip the build.

## Status

Verified: the Mac path's argument handling and the date-line maths, both
checked against the real tools. Everything else is compile-and-reason.

**Never exercised against hardware:** the on-device path in its entirety — the
transports, the `10.7.0.1` loopback default, the FFI chain — and the Apple ID
signing path. Treat a first run of either as the real test.
