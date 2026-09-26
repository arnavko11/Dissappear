import AppKit
import Foundation
import Security
import SwiftUI

@MainActor
final class CompanionModel: ObservableObject {
    @Published private(set) var toolchain: ToolchainStatus = .unknown
    @Published private(set) var devices: [Device] = []
    @Published private(set) var diagnostics: DeviceDiscovery?
    @Published private(set) var tools: [ResolvedTool] = []
    @Published private(set) var bundledBuildSize: String?
    @Published var profileURL: URL? {
        didSet { Preferences.profilePath = profileURL?.path }
    }
    @Published private(set) var selectedProfile: ProvisioningProfile?
    @Published private(set) var appleIDSession: AppleIDAuthService.Session?
    @Published private(set) var teams: [DeveloperTeam] = []
    @Published var selectedTeamID: String?
    @Published private(set) var twoFactorContext: AppleIDAuthService.TwoFactorContext?
    @Published private(set) var isSigningIn = false
    @Published private(set) var locationTooling: LocationSimulationService.Availability = .notInstalled
    /// The coordinate currently pushed to the device, if this app set it.
    @Published private(set) var deviceLocation: SimulatedCoordinate?
    @Published private(set) var deviceLocationName: String?
    /// The live spoofing session, held open or latched on the device.
    fileprivate var locationSession: LocationSimulationService.Session?
    fileprivate var locationSessionMonitor: Task<Void, Never>?
    /// Whether the iOS 17+ developer tunnel is up, and what the installer is doing.
    @Published private(set) var isDeveloperTunnelRunning = false
    @Published private(set) var toolingInstallActivity: String?
    /// Set when a live session stopped on its own, so the phone can say why.
    @Published private(set) var sessionLostReason: String?
    /// The phone left while a spoofed location was in force on it. The spoof
    /// is still set; nothing here can reach it until the phone is back.
    @Published private(set) var isDeviceDetached = false
    /// Automatic re-opens since the last spoof the user asked for, so a
    /// phone that is really gone is not retried forever.
    private var resumeAttempts = 0
    /// How the tool last reached the device, so the next command starts with
    /// what already worked instead of searching again.
    @Published private(set) var deviceLink: LocationSimulationService.Link?
    @Published private(set) var controlServerAddress: String?
    @Published private(set) var controlServerCode: String?
    @Published private(set) var controlServerStatus: ControlServerStatus = .off
    /// Whether macOS is quietly dropping the phone's connections.
    @Published private(set) var firewallStatus: FirewallService.Status = .unknown
    @Published private(set) var isKeepingAwake = false
    @Published var selectedDeviceID: Device.ID?
    @Published private(set) var identities: [SigningIdentity] = []
    @Published var selectedIdentityID: SigningIdentity.ID?
    @Published private(set) var profiles: [ProvisioningProfile] = []
    @Published private(set) var provisioning: ProvisioningStatus = .unknown
    @Published private(set) var signingState: DevelopmentSigningState = .empty
    @Published private(set) var installedApp: InstalledApp?
    @Published private(set) var product: BuildProduct?
    @Published private(set) var stages: [PipelineStage: StageState] = [:]
    @Published private(set) var activity: String?
    @Published private(set) var log: [String] = []
    @Published var configuration: BuildConfiguration {
        didSet { Preferences.projectPath = configuration.projectPath }
    }
    @Published var error: CompanionError?
    /// Result of the last pairing export, shown under the button.
    @Published var pairingRecordNotice: String?
    @Published private(set) var isBusy = false

    private let toolchainService = ToolchainService()
    private let deviceService = DeviceService()
    fileprivate let signingService = SigningService()
    private let buildService = BuildService()
    fileprivate let installationService = InstallationService()
    private let toolingService = DeviceToolingService()
    fileprivate let bundledBuildService = BundledBuildService()
    fileprivate let resignService = ResignService()
    fileprivate let appleIDAuth = AppleIDAuthService()
    fileprivate let freeProvisioning = FreeProvisioningService()
    fileprivate let locationSimulation = LocationSimulationService()
    fileprivate let toolInstaller = PyMobileDevice3Installer()
    fileprivate let controlServer = ControlServer()
    fileprivate let wakeAssertion = WakeAssertion()
    fileprivate let firewall = FirewallService()
    fileprivate let pairingRecords = PairingRecordService()
    private let libraryStore: LibraryStore

    fileprivate var bundleIdentifier = "com.dissappear.testapp"

    init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
        var configuration = BuildConfiguration.default
        if let stored = Preferences.projectPath, !stored.isEmpty {
            configuration.projectPath = stored
        }
        self.configuration = configuration
        selectedIdentityID = Preferences.identityID
        if let stored = Preferences.profilePath {
            profileURL = URL(fileURLWithPath: stored)
        }
    }

    var selectedDevice: Device? {
        devices.first { $0.id == selectedDeviceID } ?? devices.first
    }

    var selectedIdentity: SigningIdentity? {
        identities.first { $0.id == selectedIdentityID } ?? identities.first
    }

    var teamID: String? {
        let team = selectedIdentity?.teamID
        return (team?.isEmpty == false) ? team : nil
    }

    var isAppInstalled: Bool { installedApp != nil }

    /// Apple's own tooling is preferred when present.
    var preferredTool: ResolvedTool? { tools.first }

    var hasBundledBuild: Bool { bundledBuildService.isAvailable }

    private func requireTool() throws -> ResolvedTool {
        guard let preferredTool else {
            throw CompanionError(title: "No Install Tool Available",
                                 details: "Nothing on this Mac can install a build on a device.",
                                 recommendedAction: "Install Xcode, or Apple Configurator plus its automation tools, or the libimobiledevice tools.",
                                 technicalDetails: "No devicectl, cfgutil or ideviceinstaller found")
        }
        return preferredTool
    }

    // MARK: - Refresh

    func refreshAll() async {
        toolchain = await toolchainService.status()
        tools = await toolingService.availableTools()
        bundledBuildSize = bundledBuildService.version
        locationTooling = await locationSimulation.availability()
        isDeveloperTunnelRunning = await locationSimulation.isTunnelRunning()
        await refreshDevices()
        await refreshSigning()
        await refreshInstallationState()
        if Preferences.remoteControlEnabled, !isControlServerRunning {
            startControlServer()
        }
        await refreshFirewallStatus()

        // Spoofing needs pymobiledevice3 and nothing about installing it needs
        // a decision from the user, so it is fetched once, in the background,
        // rather than left as a chore in a setup screen.
        if locationTooling.tool == nil, !Preferences.didAttemptToolingInstall {
            Preferences.didAttemptToolingInstall = true
            await installLocationTooling(announcingFailures: false)
        }
    }

    func refreshDevices() async {
        activity = "Looking for connected devices"
        defer { if !isBusy { activity = nil } }

        var discovery = await deviceService.discover()
        var found = discovery.devices.filter(\.isPhysicalIOSDevice)

        // devicectl ships inside Xcode; fall back to libimobiledevice when present.
        if found.isEmpty {
            found = await toolingService.devicesFromLibimobiledevice()
        }
        // Only pay for the USB scan when nothing was found — that is exactly
        // when the user needs to know whether the cable is the problem.
        if found.isEmpty {
            discovery.usbDeviceNames = await deviceService.attachedAppleDeviceNames()
        }

        devices = found
        diagnostics = discovery
        if selectedDeviceID == nil || !found.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = found.first?.id
        }

        // Once per phone per launch: lets the phone's own app spoof it. The
        // setting lives on the phone, so an already-exported pairing record
        // starts working without a new export.
        if let tool = locationTooling.tool {
            for device in found where !networkConnectionsEnabled.contains(device.udid) {
                if await pairingRecords.enableNetworkConnections(device: device, tool: tool) {
                    networkConnectionsEnabled.insert(device.udid)
                    appendLog("Enabled network connections on \(device.name), so it can spoof itself")
                }
            }
        }
    }

    private var networkConnectionsEnabled: Set<String> = []

    /// Why the Devices screen looks the way it does, in the user's terms.
    var deviceHint: (title: String, message: String, action: String?)? {
        guard devices.isEmpty else { return nil }

        if !toolchain.hasDeviceCtl {
            return ("Xcode Is Required",
                    "devicectl ships inside Xcode, not with the Command Line Tools. macOS can show your iPhone in Finder without it, which is why the device appears there but not here.",
                    "Install Xcode from the App Store, open it once to accept the license, then choose Xcode ▸ Settings ▸ Locations and set Command Line Tools to that Xcode.")
        }

        if let usb = diagnostics?.usbDeviceNames, !usb.isEmpty {
            return ("\(usb.joined(separator: ", ")) Connected, But Not Available for Development",
                    "macOS sees the device on USB, but devicectl reports no development devices. A device paired for Finder sync is not automatically paired for development.",
                    "Unlock the iPhone and keep it unlocked, then open Xcode ▸ Window ▸ Devices and Simulators and select it so Xcode can prepare it. Enable Settings ▸ Privacy & Security ▸ Developer Mode on the iPhone and restart it when asked.")
        }

        if let diagnostics, !diagnostics.succeeded {
            return ("Device Discovery Failed",
                    "devicectl exited with code \(diagnostics.exitCode).",
                    "Check the technical details below, then confirm the command works in Terminal.")
        }

        return nil
    }

    func refreshSigning() async {
        do {
            identities = try await signingService.developmentIdentities()
            if selectedIdentityID == nil || !identities.contains(where: { $0.id == selectedIdentityID }) {
                selectedIdentityID = identities.first?.id
            }
            Preferences.identityID = selectedIdentityID
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Reading signing identities failed", error)
        }

        profiles = await signingService.provisioningProfiles()
        updateProvisioningStatus()
    }

    func refreshInstallationState() async {
        guard let device = selectedDevice, device.connection == .connected else {
            installedApp = nil
            signingState.isInstalled = false
            return
        }
        do {
            guard let tool = preferredTool else { installedApp = nil; return }
            let apps = try await installationService.installedApps(on: device, using: tool)
            installedApp = apps.first { $0.bundleIdentifier == bundleIdentifier }
            signingState.isInstalled = installedApp != nil
        } catch {
            installedApp = nil
            signingState.isInstalled = false
        }
        updateProvisioningStatus()
    }

    private func updateProvisioningStatus() {
        provisioning = signingService.provisioningStatus(bundleIdentifier: bundleIdentifier,
                                                         teamID: teamID,
                                                         deviceUDID: selectedDevice?.udid,
                                                         profiles: profiles)
        if let profile = provisioning.profile {
            signingState.isSigned = true
            signingState.teamID = profile.teamID
            signingState.profileName = profile.name
            signingState.expirationDate = profile.expirationDate
        } else if product == nil {
            signingState.isSigned = false
            signingState.expirationDate = nil
            signingState.profileName = nil
        }
    }

    // MARK: - Workflow

    func runWorkflow(launchWhenInstalled: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        stages = [:]
        log = []
        error = nil
        defer { isBusy = false; activity = nil }

        do {
            let device = try requireDevice()
            try requireDeveloperMode(device)
            let team = try requireIdentity()
            try prepareProject()
            let built = try await buildProject(device: device, team: team)
            try await signAndProvision(built)
            try await installBuild(built, on: device)
            if launchWhenInstalled {
                try await launchBuild(built, on: device)
            } else {
                stages[.launch] = .skipped("Not launched")
            }
            await refreshInstallationState()
        } catch let failure as CompanionError {
            error = failure
            appendLog("✗ \(failure.title): \(failure.details)")
        } catch {
            let failure = CompanionError.generic("Workflow failed", error)
            self.error = failure
            appendLog("✗ \(failure.title)")
        }
    }

    func refreshBuild() async {
        await install(launchWhenInstalled: false)
    }

    func reinstall() async {
        await install(launchWhenInstalled: true)
    }

    /// Picks whichever route can actually run, so Reinstall works whether or
    /// not an Xcode project is set up. Building from source is only used when
    /// a project has been chosen deliberately.
    func install(launchWhenInstalled: Bool) async {
        if configuration.isConfigured {
            await runWorkflow(launchWhenInstalled: launchWhenInstalled)
            return
        }
        if hasBundledBuild, isSignedInWithAppleID, selectedTeam != nil {
            await installUsingAppleID(launchWhenInstalled: launchWhenInstalled)
            return
        }
        if hasBundledBuild, selectedProfile != nil, selectedIdentity != nil {
            await installBundledBuild(launchWhenInstalled: launchWhenInstalled)
            return
        }

        error = CompanionError(title: "Nothing to Install Yet",
                               details: missingRequirement,
                               recommendedAction: "Open Build and either sign in under Apple ID Signing, or choose a provisioning profile under Install Without Building.",
                               technicalDetails: """
                               bundled build: \(hasBundledBuild ? "present" : "missing")
                               Apple ID: \(isSignedInWithAppleID ? "signed in" : "signed out")
                               identity: \(selectedIdentity?.commonName ?? "none")
                               profile: \(selectedProfile?.name ?? "none")
                               Xcode project: \(configuration.projectPath.isEmpty ? "not selected" : configuration.projectPath)
                               """)
    }

    private var missingRequirement: String {
        guard hasBundledBuild else {
            return "This copy of the companion has no iOS build embedded, and no Xcode project is selected."
        }
        if selectedIdentity == nil {
            return "The bundled build is ready, but no Apple Development certificate is available to sign it with."
        }
        return "The bundled build is ready, but it needs either an Apple ID sign-in or a provisioning profile before it can be signed."
    }

    func launchInstalledApp() async {
        guard let device = selectedDevice else { return }
        isBusy = true
        defer { isBusy = false; activity = nil }
        activity = "Launching on \(device.name)"
        do {
            try await installationService.launch(bundleIdentifier: bundleIdentifier, on: device, using: requireTool())
            appendLog("Launched \(bundleIdentifier) on \(device.name)")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Launch failed", error)
        }
    }

    func removeInstalledApp() async {
        guard let device = selectedDevice else { return }
        isBusy = true
        defer { isBusy = false; activity = nil }
        activity = "Removing the iPhone app"
        do {
            try await installationService.uninstall(bundleIdentifier: bundleIdentifier, from: device, using: requireTool())
            appendLog("Removed \(bundleIdentifier) from \(device.name)")
            await refreshInstallationState()
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Remove failed", error)
        }
    }

    func cleanBuildFolder() async {
        isBusy = true
        defer { isBusy = false; activity = nil }
        activity = "Cleaning build folder"
        do {
            try await buildService.clean(configuration: configuration)
            product = nil
            appendLog("Cleaned derived data for \(configuration.scheme)")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Clean failed", error)
        }
    }

    func openXcode() {
        Task { await toolchainService.openXcodeAccounts() }
    }

    // MARK: - Stages

    private func requireDevice() throws -> Device {
        stages[.connect] = .running
        guard let device = selectedDevice else {
            stages[.connect] = .failed("No iPhone detected")
            throw CompanionError(title: "No iPhone connected",
                                 details: "No development device was reported by devicectl.",
                                 recommendedAction: "Connect an iPhone over USB, unlock it and tap Trust when prompted.",
                                 technicalDetails: "devicectl list devices returned no iOS devices")
        }
        guard device.connection == .connected else {
            stages[.connect] = .failed(device.connection.displayName)
            throw CompanionError(title: "Device is not ready",
                                 details: "\(device.name) is \(device.connection.displayName.lowercased()).",
                                 recommendedAction: "Unlock the iPhone and tap Trust when asked to trust this computer.",
                                 technicalDetails: "pairing/tunnel state reported by devicectl: \(device.connection.rawValue)")
        }
        stages[.connect] = .succeeded("\(device.name) · \(device.displayModel)")
        return device
    }

    private func requireDeveloperMode(_ device: Device) throws {
        stages[.developerMode] = .running
        switch device.developerMode {
        case .enabled:
            stages[.developerMode] = .succeeded("Enabled")
        case .disabled, .restricted:
            stages[.developerMode] = .failed(device.developerMode.displayName)
            throw CompanionError(title: "Developer Mode required",
                                 details: "Developer Mode is \(device.developerMode.displayName.lowercased()) on \(device.name).",
                                 recommendedAction: "On the iPhone open Settings ▸ Privacy & Security ▸ Developer Mode, turn it on and restart when prompted.",
                                 technicalDetails: "developerModeStatus = \(device.developerMode.rawValue)")
        case .unknown:
            stages[.developerMode] = .skipped("Not reported")
        }
    }

    private func requireIdentity() throws -> String {
        stages[.identity] = .running
        guard let identity = selectedIdentity, !identity.teamID.isEmpty else {
            stages[.identity] = .failed("No development identity")
            throw CompanionError(title: "No signing identity",
                                 details: "No Apple Development certificate was found in your keychain.",
                                 recommendedAction: "Open Xcode ▸ Settings ▸ Accounts, sign in with your Apple ID and let Xcode create a development certificate.",
                                 technicalDetails: "security find-identity -v -p codesigning returned no Apple Development identities")
        }
        stages[.identity] = .succeeded("\(identity.commonName)")
        return identity.teamID
    }

    private func prepareProject() throws {
        stages[.prepare] = .running
        guard configuration.isConfigured else {
            stages[.prepare] = .failed("Project not found")
            throw CompanionError(title: "Project not found",
                                 details: "Dissappear.xcodeproj could not be located.",
                                 recommendedAction: "Choose the project location in Settings.",
                                 technicalDetails: "projectPath = \(configuration.projectPath)")
        }
        do {
            let written = try buildService.prepare(configuration: configuration, library: libraryStore.library)
            let counts = "\(libraryStore.library.locations.count) locations · \(libraryStore.library.routes.count) routes"
            stages[.prepare] = .succeeded(counts)
            appendLog("Prepared location library at \(written.path)")
        } catch let failure as CompanionError {
            stages[.prepare] = .failed(failure.details)
            throw failure
        } catch {
            stages[.prepare] = .failed(error.localizedDescription)
            throw CompanionError.generic("Prepare failed", error)
        }
    }

    private func buildProject(device: Device, team: String) async throws -> BuildProduct {
        stages[.build] = .running
        activity = "Building \(configuration.scheme) for \(device.name)"
        do {
            let built = try await buildService.build(configuration: configuration,
                                                     device: device,
                                                     teamID: team) { [weak self] line in
                Task { @MainActor in self?.appendBuildLine(line) }
            }
            product = built
            bundleIdentifier = built.bundleIdentifier
            stages[.build] = .succeeded(built.appURL.lastPathComponent)
            return built
        } catch let failure as CompanionError {
            stages[.build] = .failed(failure.details)
            throw failure
        }
    }

    private func signAndProvision(_ built: BuildProduct) async throws {
        stages[.sign] = .running
        activity = "Verifying code signature"
        do {
            let authority = try await buildService.verifySignature(of: built)
            stages[.sign] = .succeeded(authority)
        } catch let failure as CompanionError {
            stages[.sign] = .failed(failure.details)
            throw failure
        }

        stages[.provision] = .running
        if let profile = buildService.embeddedProfile(in: built) {
            signingState.isSigned = true
            signingState.teamID = profile.teamID
            signingState.profileName = profile.name
            signingState.expirationDate = profile.expirationDate
            provisioning = profile.expirationDate > Date() ? .valid(profile) : .expired(profile)
            let days = signingState.daysRemaining.map { "\($0) days remaining" } ?? "expiration unknown"
            stages[.provision] = .succeeded("\(profile.name) · \(days)")
        } else {
            stages[.provision] = .skipped("No embedded profile found")
        }
    }

    private func installBuild(_ built: BuildProduct, on device: Device) async throws {
        stages[.install] = .running
        activity = "Installing on \(device.name)"
        do {
            try await installationService.install(appURL: built.appURL,
                                                  ipaURL: nil,
                                                  on: device,
                                                  using: requireTool()) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            stages[.install] = .succeeded("Installed on \(device.name)")
            signingState.isInstalled = true
        } catch let failure as CompanionError {
            stages[.install] = .failed(failure.details)
            throw failure
        }
    }

    private func launchBuild(_ built: BuildProduct, on device: Device) async throws {
        stages[.launch] = .running
        activity = "Launching \(built.bundleIdentifier)"
        do {
            try await installationService.launch(bundleIdentifier: built.bundleIdentifier, on: device, using: requireTool())
            stages[.launch] = .succeeded("Running on \(device.name)")
        } catch let failure as CompanionError {
            stages[.launch] = .failed(failure.details)
            throw failure
        }
    }

    // MARK: - Log

    private func appendBuildLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let interesting = ["CompileSwift", "CodeSign", "Ld ", "ProcessProductPackaging", "error:", "warning:", "BUILD", "Signing Identity", "Provisioning Profile"]
        if interesting.contains(where: trimmed.contains) || trimmed.hasPrefix("**") {
            appendLog(trimmed)
        }
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    var logText: String { log.joined(separator: "\n") }
}

extension CompanionModel {
    /// Signs and installs the iOS build embedded in this app, with no Xcode
    /// project and no build step. Certificate and profile both come from the
    /// user: Apple issues them, this app only uses them.
    func installBundledBuild(launchWhenInstalled: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false; activity = nil }
        await performBundledInstall(launchWhenInstalled: launchWhenInstalled)
    }

    /// Shared by the manual-profile path and the Apple ID path, which has
    /// already set the identity and profile by the time it calls this.
    fileprivate func performBundledInstall(launchWhenInstalled: Bool, resetState: Bool = true) async {
        if resetState {
            stages = [:]
            log = []
            error = nil
        }

        do {
            let device = try requireDevice()
            let tool = try requireTool()
            stages[.developerMode] = device.developerMode == .enabled
                ? .succeeded("Enabled")
                : .skipped(device.developerMode.displayName)

            guard let identity = selectedIdentity else {
                stages[.identity] = .failed("No development identity")
                throw CompanionError(title: "No Signing Identity",
                                     details: "No Apple Development certificate was found in your keychain.",
                                     recommendedAction: "Import a development certificate, or create one on any Mac with Xcode and export it as a .p12.",
                                     technicalDetails: "security find-identity -v -p codesigning returned no Apple Development identities")
            }
            stages[.identity] = .succeeded(identity.commonName)

            guard let profileURL, let profile = selectedProfile else {
                stages[.provision] = .failed("No provisioning profile")
                throw CompanionError(title: "No Provisioning Profile",
                                     details: "A development profile decides which devices may run the build.",
                                     recommendedAction: "Choose a .mobileprovision file that includes this device and matches your signing identity's team.",
                                     technicalDetails: "profileURL is nil")
            }
            guard profile.includes(deviceUDID: device.udid) else {
                stages[.provision] = .failed("Device not in profile")
                throw CompanionError(title: "Device Not in Profile",
                                     details: "\(device.name) is not one of the devices listed in \(profile.name).",
                                     recommendedAction: "Register this device with your team and download an updated profile.",
                                     technicalDetails: "UDID \(device.udid) not in \(profile.provisionedDeviceUDIDs.count) provisioned devices")
            }

            stages[.build] = .skipped("Using bundled build")
            stages[.prepare] = .running
            activity = "Unpacking bundled build"
            let app = try await bundledBuildService.extract()
            stages[.prepare] = .succeeded(app.lastPathComponent)

            stages[.sign] = .running
            activity = "Signing with \(identity.commonName)"
            let outcome = try await resignService.resign(appURL: app,
                                                         identity: identity,
                                                         profileURL: profileURL,
                                                         profile: profile) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            stages[.sign] = .succeeded(outcome.authority)
            bundleIdentifier = outcome.bundleIdentifier

            signingState.isSigned = true
            signingState.teamID = profile.teamID
            signingState.profileName = profile.name
            signingState.expirationDate = profile.expirationDate
            provisioning = profile.expirationDate > Date() ? .valid(profile) : .expired(profile)
            let remaining = signingState.daysRemaining.map { "\($0) days remaining" } ?? "expiration unknown"
            stages[.provision] = .succeeded("\(profile.name) · \(remaining)")

            stages[.install] = .running
            activity = "Installing with \(tool.backend.displayName)"
            try await installationService.install(appURL: outcome.appURL,
                                                  ipaURL: nil,
                                                  on: device,
                                                  using: tool) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            stages[.install] = .succeeded("Installed on \(device.name)")
            signingState.isInstalled = true

            if launchWhenInstalled, tool.backend.supportsLaunch {
                try await installationService.launch(bundleIdentifier: outcome.bundleIdentifier, on: device, using: tool)
                stages[.launch] = .succeeded("Running on \(device.name)")
            } else {
                stages[.launch] = .skipped("Open the app on \(device.name)")
            }

            await refreshInstallationState()
        } catch let failure as CompanionError {
            error = failure
            appendLog("✗ \(failure.title): \(failure.details)")
        } catch {
            let failure = CompanionError.generic("Install failed", error)
            self.error = failure
            appendLog("✗ \(failure.title)")
        }
    }

    func loadProfile(at url: URL) async {
        profileURL = url
        selectedProfile = await signingService.profile(at: url)
        if selectedProfile == nil {
            error = CompanionError(title: "Profile Could Not Be Read",
                                   details: "That file is not a readable provisioning profile.",
                                   recommendedAction: "Choose a .mobileprovision file exported from your Apple developer account.",
                                   technicalDetails: url.path)
        }
    }
}

// MARK: - Device location

extension CompanionModel {
    var canSimulateDeviceLocation: Bool {
        locationTooling.tool != nil && selectedDevice != nil
    }

    /// Everything the developer location service needs is in place.
    var isReadyToSpoof: Bool {
        toolchain.hasDeviceCtl
            && locationTooling.tool != nil
            && selectedDevice?.developerMode == .enabled
    }

    /// Opens Xcode's App Store page, so "install Xcode" is one click rather
    /// than a search.
    func openXcodeInAppStore() {
        guard let url = URL(string: "macappstore://apps.apple.com/app/xcode/id497799835") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Finds a working anisette server and stores it, so Apple ID sign-in can
    /// be tried without the user researching what anisette even is.
    func findAnisetteServer() async {
        activity = "Looking for an anisette server"
        defer { if !isBusy { activity = nil } }

        guard let server = await AnisetteDiscovery().firstReachable() else {
            error = CompanionError(
                title: "No Anisette Server Answered",
                details: "None of the published servers could be reached.",
                recommendedAction: "You do not need one to spoof a location. It is only for Build ▸ Apple ID Signing; installing with a provisioning profile from Xcode needs none of this.",
                technicalDetails: "https://servers.sidestore.io/servers.json")
            return
        }
        Preferences.anisetteServerString = server.address
        appendLog("Using anisette server \(server.name) — \(server.address)")
    }

    /// Writes the device's pairing record to a file.
    ///
    /// This is the one thing a computer is needed for if the phone is ever to
    /// drive its own developer services: the record is the trust iOS
    /// established when the device was paired, and nothing can forge it.
    func exportPairingRecord(to destination: URL) async {
        guard let device = selectedDevice else {
            error = CompanionError(title: "No iPhone Connected",
                                   details: "A pairing record belongs to a specific device.",
                                   recommendedAction: "Connect an iPhone over USB, unlock it, and try again.",
                                   technicalDetails: "devices = \(devices.count)")
            return
        }
        guard let tool = locationTooling.tool else {
            error = CompanionError(title: "pymobiledevice3 Not Installed",
                                   details: "Exporting the pairing record needs it.",
                                   recommendedAction: LocationSimulationService.installGuidance,
                                   technicalDetails: "locationTooling = notInstalled")
            return
        }

        isBusy = true
        activity = "Exporting the pairing record"
        defer { isBusy = false; activity = nil }

        do {
            let notPlaced = try await pairingRecords.export(device: device, tool: tool, to: destination) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            pairingRecordNotice = notPlaced == nil
                ? "Done — sent to the Dissappear app on \(device.name). Open it, switch on the VPN, and tap Spoof Here."
                : "Paired, but it could not be put into the iPhone app (\(notPlaced ?? "")). Is the Dissappear app installed on it? Otherwise use Export Pairing Record to a File, and import that in the app under Connection."
            appendLog(pairingRecordNotice ?? "")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Exporting the pairing record failed", error)
        }
    }

    /// One click: pairs, and writes the record straight into the iPhone app.
    /// The file only passes through a temporary folder — it is a credential,
    /// so nothing is left lying around on the Mac.
    func setUpOnDeviceSpoofing() async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        await exportPairingRecord(to: folder.appendingPathComponent("pairing-record.plist"))
    }

    /// Asks where to put the record, then writes it there.
    func exportPairingRecordWithSavePanel() async {
        let panel = NSSavePanel()
        panel.title = "Export Pairing Record"
        panel.nameFieldStringValue = suggestedPairingRecordName
        panel.canCreateDirectories = true
        panel.message = "This file lets an app on the phone open the phone's own developer services. Keep it as you would a password."

        guard await panel.begin() == .OK, let url = panel.url else { return }
        await exportPairingRecord(to: url)
    }

    /// A filename for the selected device's pairing record.
    var suggestedPairingRecordName: String {
        selectedDevice.map(PairingRecordService.suggestedFilename) ?? "device.mobiledevicepairing"
    }

    /// Installs pymobiledevice3 into a private environment this app owns, so
    /// spoofing works without anyone opening Terminal.
    func installLocationTooling(announcingFailures: Bool = true) async {
        guard toolingInstallActivity == nil else { return }
        toolingInstallActivity = "Preparing…"
        defer { toolingInstallActivity = nil }

        do {
            try await toolInstaller.install { [weak self] progress in
                switch progress {
                case .locatingPython: self?.toolingInstallActivity = "Looking for Python 3…"
                case .creatingEnvironment: self?.toolingInstallActivity = "Creating a private environment…"
                case .downloading: self?.toolingInstallActivity = "Downloading pymobiledevice3…"
                case let .finished(version): self?.appendLog("Installed \(version)")
                }
            } onOutputLine: { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            locationTooling = await locationSimulation.availability()
        } catch let failure as CompanionError {
            appendLog("✗ \(failure.title): \(failure.details)")
            if announcingFailures { error = failure }
        } catch {
            appendLog("✗ Installing pymobiledevice3 failed: \(error.localizedDescription)")
            if announcingFailures { self.error = .generic("Installing pymobiledevice3 failed", error) }
        }
    }

    /// Brings up the iOS 17+ developer tunnel behind the standard macOS
    /// administrator prompt, instead of sending the user to Terminal.
    func startDeveloperTunnel() async {
        guard let tool = locationTooling.tool else {
            error = CompanionError(title: "pymobiledevice3 Not Installed",
                                   details: "The developer tunnel is part of pymobiledevice3.",
                                   recommendedAction: LocationSimulationService.installGuidance,
                                   technicalDetails: "locationTooling = notInstalled")
            return
        }
        activity = "Starting the developer tunnel"
        defer { if !isBusy { activity = nil } }

        do {
            try await locationSimulation.startTunnel(tool: tool)
            isDeveloperTunnelRunning = await locationSimulation.isTunnelRunning()
            appendLog(isDeveloperTunnelRunning ? "Developer tunnel is up" : "Developer tunnel did not come up")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Starting the developer tunnel failed", error)
        }
    }

    /// Removes the tunnel daemon, so it is not left running as root.
    func stopDeveloperTunnel() async {
        activity = "Stopping the developer tunnel"
        defer { if !isBusy { activity = nil } }

        do {
            try await locationSimulation.stopTunnel()
            isDeveloperTunnelRunning = await locationSimulation.isTunnelRunning()
            appendLog("Developer tunnel removed")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Stopping the developer tunnel failed", error)
        }
    }

    /// Mounts the developer disk image so the location service is reachable.
    func prepareDeviceForLocation() async {
        guard !isBusy, let tool = locationTooling.tool, let device = selectedDevice else { return }
        isBusy = true
        activity = "Preparing developer services"
        defer { isBusy = false; activity = nil }

        do {
            deviceLink = try await locationSimulation.prepare(device: device, tool: tool, link: deviceLink) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            appendLog("Developer disk image ready via \(deviceLink?.label ?? "the device")")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Preparing developer services failed", error)
        }
    }

    /// Spoofs the location the whole device reports, using Apple's developer
    /// location service. Every app on the phone sees it until it is cleared.
    func setDeviceLocation(latitude: Double, longitude: Double, name: String?) async {
        guard let device = selectedDevice else {
            error = CompanionError(title: "No iPhone Selected",
                                   details: "Nothing is connected to spoof the location of.",
                                   recommendedAction: "Connect an iPhone by cable, unlock it, and trust this Mac.",
                                   technicalDetails: "devices = \(devices.count)")
            return
        }
        guard !isBusy else {
            error = CompanionError(title: "Busy",
                                   details: "Another operation is still running: \(activity ?? "please wait").",
                                   recommendedAction: "Wait for it to finish, then set the location again.",
                                   technicalDetails: "isBusy = true")
            return
        }
        guard let tool = locationTooling.tool else {
            error = CompanionError(title: "pymobiledevice3 Not Installed",
                                   details: "Spoofing the device's location needs a client for Apple's developer services.",
                                   recommendedAction: LocationSimulationService.installGuidance,
                                   technicalDetails: "No pymobiledevice3 executable found in the usual locations")
            return
        }
        isBusy = true
        activity = "Spoofing location on \(device.name)"
        defer { isBusy = false; activity = nil }

        do {
            if let existing = locationSession?.handle {
                await locationSimulation.endSession(existing)
            }

            // Mount the developer disk image first. It is idempotent, and
            // skipping it was the most common reason a first spoof failed.
            deviceLink = try? await locationSimulation.prepare(device: device, tool: tool, link: deviceLink) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }

            let outcome = try await locationSimulation.beginSession(latitude: latitude,
                                                                    longitude: longitude,
                                                                    device: device,
                                                                    tool: tool,
                                                                    link: deviceLink) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            locationSession = outcome.0
            deviceLink = outcome.1
            deviceLocation = SimulatedCoordinate(latitude: latitude, longitude: longitude)
            deviceLocationName = name
            sessionLostReason = nil
            isDeviceDetached = false
            monitorLocationSession()
            wakeAssertion.acquire(reason: WakeAssertion.Reason.locationSession)
            isKeepingAwake = wakeAssertion.isActive
            appendLog("Device location spoofed to \(String(format: "%.5f, %.5f", latitude, longitude)) via \(deviceLink?.label ?? "the device")")
            if locationSession?.isHeld == true {
                appendLog("Holding the session open and keeping this Mac awake.")
            } else {
                appendLog("The coordinate is latched on the device and lasts until it is cleared.")
            }
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Spoofing the device location failed", error)
        }
    }

    /// Watches a live spoof, both kinds.
    ///
    /// A held session dies with its process. A latched one does not: the
    /// coordinate stays on the phone, so unplugging the cable does not undo
    /// it — it only takes away the means to undo it. That case had no watcher
    /// at all, so the app went on claiming it was spoofing a device that was
    /// no longer there, with no way to put the real location back.
    private func monitorLocationSession() {
        locationSessionMonitor?.cancel()
        guard deviceLocation != nil else { return }
        let watchedUDID = selectedDevice?.udid

        locationSessionMonitor = Task { [weak self] in
            while !Task.isCancelled {
                // Each presence check runs devicectl, so this is deliberately
                // not frequent: it is watching for a cable being pulled, not
                // timing anything.
                try? await Task.sleep(for: .seconds(8))
                guard let self, !Task.isCancelled, self.deviceLocation != nil else { return }

                // A held process that exited means the spoof really is over.
                if let handle = self.locationSession?.handle,
                   !(await self.locationSimulation.isSessionActive(handle)) {
                    // Pulling the cable kills a session that ran over USB,
                    // but the phone can often still be reached over Wi-Fi.
                    // Re-open it there rather than dropping the spoof, so
                    // unplugging does not snap the phone back to real GPS.
                    if let location = self.deviceLocation,
                       !self.isBusy, self.resumeAttempts < 3,
                       let udid = watchedUDID, await self.isDevicePresent(udid: udid) {
                        self.resumeAttempts += 1
                        self.appendLog("Session dropped — re-opening it (attempt \(self.resumeAttempts))")
                        self.locationSession = nil
                        self.deviceLink = nil
                        await self.setDeviceLocation(latitude: location.latitude,
                                                     longitude: location.longitude,
                                                     name: self.deviceLocationName)
                        if self.locationSession != nil { return }   // a new monitor took over
                    }
                    self.locationSession = nil
                    self.deviceLocation = nil
                    self.sessionLostReason = "The spoofing session ended, so the device is back on real GPS."
                    self.wakeAssertion.release(reason: WakeAssertion.Reason.locationSession)
                    self.isKeepingAwake = self.wakeAssertion.isActive
                    self.appendLog("✗ Location session ended")
                    return
                }

                if self.locationSession?.handle != nil { self.resumeAttempts = 0 }

                // The phone going away is not the spoof ending. It is the
                // spoof becoming unreachable while still in force.
                guard let udid = watchedUDID else { continue }
                let present = await self.isDevicePresent(udid: udid)

                if !present, !self.isDeviceDetached {
                    self.isDeviceDetached = true
                    self.sessionLostReason = Self.detachedExplanation
                    self.appendLog("⚠︎ The iPhone was disconnected while a spoofed location was set")
                } else if present, self.isDeviceDetached {
                    self.isDeviceDetached = false
                    self.sessionLostReason = nil
                    self.appendLog("The iPhone is back — the spoofed location can be changed or cleared again")
                    await self.refreshDevices()
                }
            }
        }
    }

    static let detachedExplanation = """
    The iPhone has gone, and the session spoofing it went with it. A spoof \
    lasts only while that session is held, so the phone is either back on \
    real GPS already or stuck on the last coordinate because the session \
    broke rather than closed. Reconnect and press Stop Spoofing to be sure of \
    which; restarting the phone also clears it.
    """

    /// A cheap presence check for the watcher, which runs every few seconds.
    private func isDevicePresent(udid: String) async -> Bool {
        let discovery = await deviceService.discover()
        return discovery.devices.contains { $0.udid == udid && $0.isPhysicalIOSDevice }
    }

    func clearDeviceLocation() async {
        // A phone that left mid-spoof is still spoofed, so it is worth looking
        // again before refusing: the usual reason for clearing is that the
        // cable has just been plugged back in.
        if selectedDevice == nil || isDeviceDetached {
            await refreshDevices()
        }

        guard let device = selectedDevice, let tool = locationTooling.tool else {
            error = CompanionError(
                title: "The iPhone Is Not Connected",
                details: deviceLocation != nil
                    ? "A spoofed location is still set on the phone, and it stays set until something clears it. This Mac cannot reach the phone to do that."
                    : "No iPhone is connected, or pymobiledevice3 is not installed.",
                recommendedAction: deviceLocation != nil
                    ? "Plug the phone back in, unlock it, then press Stop Spoofing again. Restarting the phone also clears it."
                    : "Connect an iPhone, and install the location tooling from Setup.",
                technicalDetails: "device = \(selectedDevice?.name ?? "nil"), tool = \(locationTooling.tool?.executablePath ?? "nil")")
            return
        }
        // Deliberately not gated on isBusy. Putting the real location back is
        // the way out of a wedged state, so it must not be the thing that
        // refuses because the state is wedged.
        isBusy = true
        activity = "Restoring real location on \(device.name)"
        defer { isBusy = false; activity = nil }

        do {
            locationSessionMonitor?.cancel()
            locationSessionMonitor = nil
            sessionLostReason = nil
            // Ending the held process is what actually stops the spoof: the
            // tool clears the location as it shuts its session down. The
            // explicit clear afterwards covers a session that already died.
            if let handle = locationSession?.handle {
                await locationSimulation.endSession(handle)
                appendLog("Stopped the held spoofing session")
            }
            locationSession = nil
            deviceLink = try await locationSimulation.clearLocation(device: device, tool: tool, link: deviceLink) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            deviceLocation = nil
            deviceLocationName = nil
            isDeviceDetached = false
            wakeAssertion.release(reason: WakeAssertion.Reason.locationSession)
            isKeepingAwake = wakeAssertion.isActive
            appendLog("Device returned to its real location")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Clearing the device location failed", error)
        }
    }

    /// Replays a saved route on the device by handing the service a GPX track.
    func playRouteOnDevice(_ route: SimulatedRoute) async {
        guard let device = selectedDevice, let tool = locationTooling.tool else {
            error = CompanionError(title: "Nothing to Play On",
                                   details: "No iPhone is connected, or pymobiledevice3 is not installed.",
                                   recommendedAction: "Connect an iPhone, and install the tooling from Setup.",
                                   technicalDetails: "device = \(selectedDevice?.name ?? "nil")")
            return
        }
        guard !isBusy else {
            error = CompanionError(title: "Busy",
                                   details: "Another operation is still running: \(activity ?? "please wait").",
                                   recommendedAction: "Wait for it to finish, then try again.",
                                   technicalDetails: "isBusy = true")
            return
        }
        guard route.waypoints.count > 1 else {
            error = CompanionError(title: "Route Needs More Waypoints",
                                   details: "A route needs at least two waypoints to replay.",
                                   recommendedAction: "Add another waypoint in Routes.",
                                   technicalDetails: "waypoints = \(route.waypoints.count)")
            return
        }
        isBusy = true
        activity = "Playing \(route.name) on \(device.name)"
        defer { isBusy = false; activity = nil }

        do {
            // A route replaces whatever is held; two sessions would fight.
            if let existing = locationSession?.handle {
                await locationSimulation.endSession(existing)
                locationSession = nil
            }
            let points = Self.densify(route: route)
            let gpx = try GPXWriter.write(coordinates: points, name: route.name)
            let outcome = try await locationSimulation.playRoute(gpxURL: gpx, device: device,
                                                                 tool: tool, link: deviceLink) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            locationSession = outcome.0
            deviceLink = outcome.1
            deviceLocationName = route.name
            deviceLocation = points.last.map { SimulatedCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            sessionLostReason = nil
            isDeviceDetached = false
            monitorLocationSession()
            wakeAssertion.acquire(reason: WakeAssertion.Reason.locationSession)
            isKeepingAwake = wakeAssertion.isActive
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Playing the route failed", error)
        }
    }

    /// One point per second of travel, so playback moves at the route's speed.
    /// Turns a route's corners into a track the device can be walked along.
    ///
    /// The point count is capped. One point per second of travel is right for
    /// a short route, but a long one at walking pace works out at hundreds of
    /// thousands, which is a GPX file nothing wants to write or read; past
    /// the cap the spacing simply widens.
    private static func densify(route: SimulatedRoute) -> [(latitude: Double, longitude: Double)] {
        let maximumPoints = 20_000

        let legs = Array(zip(route.waypoints, route.waypoints.dropFirst()))
        let total = legs.reduce(0.0) { sum, leg in
            let distance = GeoMath.distance(leg.0, leg.1)
            return sum + (distance.isFinite ? distance : 0)
        }

        // A metre a point at the slowest, and wider if the route is long
        // enough that the cap would otherwise be passed.
        var step = max(route.speed, 0.5)
        if total / step > Double(maximumPoints) {
            step = total / Double(maximumPoints)
        }

        var points: [(latitude: Double, longitude: Double)] = []
        for (start, end) in legs {
            let distance = GeoMath.distance(start, end)
            // A non-finite distance means a corrupt coordinate, and Int() of
            // one traps rather than failing.
            guard distance.isFinite, step > 0 else { continue }

            let count = max(1, min(maximumPoints, Int(distance / step)))
            for index in 0..<count {
                let coordinate = GeoMath.interpolate(start, end, fraction: Double(index) / Double(count))
                points.append((coordinate.latitude, coordinate.longitude))
            }
            if points.count >= maximumPoints { break }
        }

        if let last = route.waypoints.last {
            points.append((last.latitude, last.longitude))
        }
        return points
    }
}

// MARK: - Remote control

extension CompanionModel {
    var isControlServerRunning: Bool {
        if case .off = controlServerStatus { return false }
        if case .failed = controlServerStatus { return false }
        return true
    }

    var libraryLocations: [SimulatedLocation] { libraryStore.library.locations }

    /// Development profiles already on this Mac, so a profile can be picked
    /// from a list rather than hunted for inside a hidden Library folder.
    var installedDevelopmentProfiles: [ProvisioningProfile] {
        profiles.filter { $0.isDevelopment && $0.expirationDate > Date() }
    }

    /// Says whether a profile is usable for the selected device.
    func describe(_ profile: ProvisioningProfile) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: profile.expirationDate).day ?? 0
        var parts = [profile.name, "\(max(0, days))d left"]
        if let device = selectedDevice {
            parts.append(profile.includes(deviceUDID: device.udid) ? "includes this device" : "other devices only")
        }
        return parts.joined(separator: " · ")
    }

    /// Lets the iOS app steer the spoofed location over the local network, so
    /// the Mac can stay put while you move.
    func startControlServer() {
        Preferences.remoteControlEnabled = true
        controlServerStatus = .starting

        controlServer.handler = { [weak self] request in
            await self?.handleControlRequest(request) ?? .error(503, "Not ready.")
        }
        controlServer.onStateChange = { [weak self] result in
            Task { @MainActor in self?.controlServerBecame(result) }
        }
        controlServer.onPairRequest = { [weak self] name in
            await self?.approvePairing(name: name) ?? false
        }

        do {
            try controlServer.start()
            controlServerCode = controlServer.pairingCode
        } catch {
            controlServerStatus = .failed(error.localizedDescription)
            controlServerAddress = nil
            appendLog("Remote control could not start: \(error.localizedDescription)")
        }
    }

    /// The listener reports itself ready or failed asynchronously, so the UI
    /// only claims to be listening once the port is actually bound.
    private func controlServerBecame(_ result: Result<UInt16, Error>) {
        switch result {
        case let .success(port):
            let host = ControlServer.localAddresses().first ?? "this Mac"
            controlServerAddress = "\(host):\(port)"
            controlServerCode = controlServer.pairingCode
            controlServerStatus = .running
            wakeAssertion.acquire(reason: WakeAssertion.Reason.remoteControl)
            isKeepingAwake = wakeAssertion.isActive
            appendLog("Remote control listening on \(controlServerAddress ?? "")")
            Task { await refreshFirewallStatus() }

        case let .failure(error):
            controlServerAddress = nil
            controlServerStatus = .failed(error.localizedDescription)
            wakeAssertion.release(reason: WakeAssertion.Reason.remoteControl)
            isKeepingAwake = wakeAssertion.isActive
            appendLog("Remote control failed: \(error.localizedDescription)")
            self.error = CompanionError(
                title: "Remote control could not start",
                details: error.localizedDescription,
                recommendedAction: "macOS 15 and later ask permission the first time an app uses the local network. Allow Dissappear Companion in System Settings ▸ Privacy & Security ▸ Local Network, then switch Remote Control off and on again.",
                technicalDetails: "NWListener on port 8787, then on a kernel-assigned port")
        }
    }

    func stopControlServer() {
        Preferences.remoteControlEnabled = false
        controlServer.onStateChange = nil
        controlServer.stop()
        controlServerAddress = nil
        controlServerCode = nil
        controlServerStatus = .off
        wakeAssertion.release(reason: WakeAssertion.Reason.remoteControl)
        isKeepingAwake = wakeAssertion.isActive
        appendLog("Remote control stopped")
    }

    /// A bound listener is not a reachable one: with the firewall on, macOS
    /// drops incoming connections to an app without a Developer ID signature
    /// and says nothing, so the phone just never gets an answer.
    func refreshFirewallStatus() async {
        firewallStatus = await firewall.status()
        if firewallStatus.isBlocking {
            appendLog("⚠︎ The firewall is blocking incoming connections to this app")
        }
    }

    func allowIncomingConnections() async {
        do {
            try await firewall.allowIncomingConnections()
            await refreshFirewallStatus()
            appendLog("Firewall now allows incoming connections")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Allowing incoming connections failed", error)
        }
    }

    /// Ends everything held before the app goes away.
    ///
    /// Terminating the spoofing session is what puts the real location back,
    /// so quitting without it leaves the phone reporting a lie that nothing
    /// can now correct.
    func shutDown() async {
        controlServer.stop()
        await ProcessRunner.shared.stopAll()
        wakeAssertion.release(reason: WakeAssertion.Reason.locationSession)
        wakeAssertion.release(reason: WakeAssertion.Reason.remoteControl)
    }

    /// Unpairs every phone: the code they were handed stops working, and
    /// each has to be approved again.
    func regeneratePairingCode() {
        controlServer.rotatePairingCode()
        controlServerCode = controlServer.pairingCode
        appendLog("Forgot all paired iPhones")
    }

    /// Shows the approval prompt when a phone on the network asks to pair.
    private func approvePairing(name: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow “\(name)” to control spoofing?"
        alert.informativeText = "It will be able to set and clear this Mac's spoofed location from the Dissappear app. Only allow your own iPhone."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        let allowed = alert.runModal() == .alertFirstButtonReturn
        appendLog(allowed ? "Paired \(name)" : "Declined pairing from \(name)")
        return allowed
    }

    private func handleControlRequest(_ request: ControlServer.Request) async -> ControlServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            return .ok([
                "device": selectedDevice?.name ?? "",
                "simulating": deviceLocation != nil,
                "latitude": deviceLocation?.latitude ?? 0,
                "longitude": deviceLocation?.longitude ?? 0,
                "name": deviceLocationName ?? "",
                "ready": canSimulateDeviceLocation,
                "tunnel": isDeveloperTunnelRunning,
                "detached": isDeviceDetached,
                "link": deviceLink?.label ?? "",
                "wireless": deviceLink?.isWireless ?? false,
                "busy": isBusy,
                "sessionLost": sessionLostReason ?? ""
            ])

        case ("GET", "/locations"):
            let locations = libraryLocations.map {
                ["name": $0.name, "latitude": $0.coordinate.latitude, "longitude": $0.coordinate.longitude]
            }
            return .ok(["locations": locations])

        case ("POST", "/location"):
            guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let latitude = payload["latitude"] as? Double,
                  let longitude = payload["longitude"] as? Double else {
                return .error(400, "Expected latitude and longitude.")
            }
            guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                return .error(400, "That coordinate is out of range.")
            }
            error = nil
            await setDeviceLocation(latitude: latitude, longitude: longitude,
                                    name: payload["name"] as? String)
            if let failure = error {
                return .error(500, "\(failure.title): \(failure.details)")
            }
            // Without this the phone was told the spoof succeeded whenever the
            // Mac was busy and the request had quietly been dropped.
            guard deviceLocation != nil else {
                return .error(500, "The companion did not apply the location.")
            }
            return .ok(["simulating": true, "latitude": latitude, "longitude": longitude])

        case ("POST", "/route"):
            guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let points = payload["waypoints"] as? [[String: Any]], points.count > 1 else {
                return .error(400, "Expected at least two waypoints.")
            }
            let waypoints = points.compactMap { point -> SimulatedCoordinate? in
                guard let latitude = point["latitude"] as? Double,
                      let longitude = point["longitude"] as? Double,
                      (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
                return SimulatedCoordinate(latitude: latitude, longitude: longitude)
            }
            guard waypoints.count == points.count else {
                return .error(400, "A waypoint was missing or out of range.")
            }

            error = nil
            let route = SimulatedRoute(name: payload["name"] as? String ?? "Route",
                                       waypoints: waypoints,
                                       speed: payload["speed"] as? Double ?? 11,
                                       loops: payload["loops"] as? Bool ?? false)
            await playRouteOnDevice(route)
            if let failure = error {
                return .error(500, "\(failure.title): \(failure.details)")
            }
            return .ok(["playing": true, "waypoints": waypoints.count])

        case ("POST", "/clear"):
            error = nil
            await clearDeviceLocation()
            if let failure = error {
                return .error(500, "\(failure.title): \(failure.details)")
            }
            return .ok(["simulating": false])

        default:
            return .error(404, "Unknown request.")
        }
    }
}

// MARK: - Apple ID signing

extension CompanionModel {
    var selectedTeam: DeveloperTeam? {
        teams.first { $0.id == selectedTeamID } ?? teams.first
    }

    var isSignedInWithAppleID: Bool { appleIDSession != nil }

    var needsVerificationCode: Bool { twoFactorContext != nil }

    /// Signs in with an Apple ID. The password is passed straight through to
    /// the SRP exchange and is never stored by this app.
    func signInWithAppleID(appleID: String, password: String) async {
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }

        do {
            switch try await appleIDAuth.authenticate(appleID: appleID, password: password) {
            case let .signedIn(session):
                appleIDSession = session
                twoFactorContext = nil
                AppleIDTokenStore.save(session)
                await loadTeams()
            case let .twoFactorRequired(context):
                twoFactorContext = context
                appendLog("A verification code was sent to your trusted devices.")
            }
        } catch {
            self.error = Self.companionError(from: error)
        }
    }

    func submitVerificationCode(_ code: String, password: String) async {
        guard let context = twoFactorContext else { return }
        isSigningIn = true
        error = nil
        defer { isSigningIn = false }

        do {
            let session = try await appleIDAuth.submitVerificationCode(code, context: context, password: password)
            appleIDSession = session
            twoFactorContext = nil
            AppleIDTokenStore.save(session)
            await loadTeams()
        } catch {
            self.error = Self.companionError(from: error)
        }
    }

    func signOutOfAppleID() {
        if let session = appleIDSession {
            AppleIDTokenStore.clear(appleID: session.appleID)
        }
        appleIDSession = nil
        twoFactorContext = nil
        teams = []
        selectedTeamID = nil
    }

    func restoreAppleIDSession(appleID: String) async {
        guard let stored = AppleIDTokenStore.load(appleID: appleID) else { return }
        appleIDSession = stored
        await loadTeams()
    }

    func loadTeams() async {
        guard let session = appleIDSession else { return }
        do {
            let loaded = try await DeveloperServicesClient(session: session).listTeams()
            teams = loaded
            if selectedTeamID == nil || !loaded.contains(where: { $0.id == selectedTeamID }) {
                selectedTeamID = loaded.first?.id
            }
        } catch {
            self.error = Self.companionError(from: error)
        }
    }

    /// Registers the device, obtains a certificate and profile from Apple, then
    /// signs and installs the bundled build — no Xcode project involved.
    func installUsingAppleID(launchWhenInstalled: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        stages = [:]
        log = []
        error = nil
        defer { isBusy = false; activity = nil }

        do {
            let device = try requireDevice()
            guard let session = appleIDSession else { throw AppleIDError.notSignedIn }
            guard let team = selectedTeam else {
                throw AppleIDError.protocolFailure("No development team is available for this Apple ID.")
            }

            stages[.identity] = .running
            activity = "Preparing signing with Apple ID"
            let result = try await freeProvisioning.provision(session: session,
                                                              team: team,
                                                              device: device,
                                                              baseBundleIdentifier: "com.dissappear.testapp") { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }

            await refreshSigning()
            selectedIdentityID = result.identity.id
            profileURL = result.profileURL
            selectedProfile = result.profile
            stages[.identity] = .succeeded("\(result.identity.commonName) · \(team.name)")

            await performBundledInstall(launchWhenInstalled: launchWhenInstalled, resetState: false)
        } catch {
            self.error = Self.companionError(from: error)
            appendLog("✗ \(self.error?.title ?? "Failed")")
        }
    }

    fileprivate static func companionError(from error: Error) -> CompanionError {
        if let failure = error as? CompanionError { return failure }
        if let failure = error as? AppleIDError {
            return CompanionError(title: "Apple ID Sign-In Failed",
                                  details: failure.errorDescription ?? "Apple rejected the request.",
                                  recommendedAction: failure.recoverySuggestion
                                      ?? "Check the details below, then try again.",
                                  technicalDetails: String(describing: failure))
        }
        return .generic("Apple ID Sign-In Failed", error, action: "Check your network connection and try again.")
    }
}

enum Preferences {
    private static let defaults = UserDefaults.standard

    static var projectPath: String? {
        get { defaults.string(forKey: "projectPath") }
        set { defaults.set(newValue, forKey: "projectPath") }
    }

    static var identityID: String? {
        get { defaults.string(forKey: "identityID") }
        set { defaults.set(newValue, forKey: "identityID") }
    }

    static var profilePath: String? {
        get { defaults.string(forKey: "profilePath") }
        set { defaults.set(newValue, forKey: "profilePath") }
    }

    /// Set once the app has tried to install pymobiledevice3 by itself, so a
    /// Mac with no network does not retry on every launch.
    static var didAttemptToolingInstall: Bool {
        get { defaults.bool(forKey: "didAttemptToolingInstall") }
        set { defaults.set(newValue, forKey: "didAttemptToolingInstall") }
    }

    /// Remote control is on unless it was explicitly switched off, so a phone
    /// can pair without anyone hunting through Settings first.
    static var remoteControlEnabled: Bool {
        get {
            if defaults.object(forKey: "remoteControlEnabled") == nil { return true }
            return defaults.bool(forKey: "remoteControlEnabled")
        }
        set { defaults.set(newValue, forKey: "remoteControlEnabled") }
    }

    /// Optional anisette server. Empty means this Mac's own anisette, which
    /// macOS 26 and later no longer provide to unentitled apps.
    static var anisetteServerString: String {
        get { defaults.string(forKey: "anisetteServer") ?? "" }
        set { defaults.set(newValue, forKey: "anisetteServer") }
    }

    static var anisetteServerURL: URL? {
        let trimmed = anisetteServerString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }
}
