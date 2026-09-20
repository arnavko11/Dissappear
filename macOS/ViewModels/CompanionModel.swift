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
        await refreshDevices()
        await refreshSigning()
        await refreshInstallationState()
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
    }

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
        activity = "Removing test app"
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
            let counts = "\(libraryStore.library.locations.count) locations · \(libraryStore.library.routes.count) routes · \(libraryStore.library.scenarios.count) scenarios"
            stages[.prepare] = .succeeded(counts)
            appendLog("Prepared simulation library at \(written.path)")
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

    /// Mounts the developer disk image so the location service is reachable.
    func prepareDeviceForLocation() async {
        guard !isBusy, let tool = locationTooling.tool else { return }
        isBusy = true
        activity = "Preparing developer services"
        defer { isBusy = false; activity = nil }

        do {
            try await locationSimulation.prepare(tool: tool) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            appendLog("Developer disk image ready")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Preparing developer services failed", error)
        }
    }

    /// Sets the location the whole device reports, using Apple's developer
    /// location service. Every app on the phone sees it until it is cleared.
    func setDeviceLocation(latitude: Double, longitude: Double, name: String?) async {
        guard !isBusy, let device = selectedDevice else { return }
        guard let tool = locationTooling.tool else {
            error = CompanionError(title: "pymobiledevice3 Not Installed",
                                   details: "Setting the device's location needs a client for Apple's developer services.",
                                   recommendedAction: LocationSimulationService.installGuidance,
                                   technicalDetails: "No pymobiledevice3 executable found in the usual locations")
            return
        }
        isBusy = true
        activity = "Setting location on \(device.name)"
        defer { isBusy = false; activity = nil }

        do {
            try await locationSimulation.setLocation(latitude: latitude,
                                                     longitude: longitude,
                                                     device: device,
                                                     tool: tool) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            deviceLocation = SimulatedCoordinate(latitude: latitude, longitude: longitude)
            deviceLocationName = name
            appendLog("Device location set to \(String(format: "%.5f, %.5f", latitude, longitude))")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Setting the device location failed", error)
        }
    }

    func clearDeviceLocation() async {
        guard !isBusy, let device = selectedDevice, let tool = locationTooling.tool else { return }
        isBusy = true
        activity = "Restoring real location on \(device.name)"
        defer { isBusy = false; activity = nil }

        do {
            try await locationSimulation.clearLocation(device: device, tool: tool) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            deviceLocation = nil
            deviceLocationName = nil
            appendLog("Device returned to real location")
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Clearing the device location failed", error)
        }
    }

    /// Replays a saved route on the device by handing the service a GPX track.
    func playRouteOnDevice(_ route: SimulatedRoute) async {
        guard !isBusy, let device = selectedDevice, let tool = locationTooling.tool else { return }
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
            let points = Self.densify(route: route)
            let gpx = try GPXWriter.write(coordinates: points, name: route.name)
            try await locationSimulation.playRoute(gpxURL: gpx, device: device, tool: tool) { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            }
            deviceLocationName = route.name
            deviceLocation = points.last.map { SimulatedCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        } catch let failure as CompanionError {
            error = failure
        } catch {
            self.error = .generic("Playing the route failed", error)
        }
    }

    /// One point per second of travel, so playback moves at the route's speed.
    private static func densify(route: SimulatedRoute) -> [(latitude: Double, longitude: Double)] {
        var points: [(latitude: Double, longitude: Double)] = []
        let step = max(route.speed, 0.5)

        for (start, end) in zip(route.waypoints, route.waypoints.dropFirst()) {
            let distance = GeoMath.distance(start, end)
            let count = max(1, Int(distance / step))
            for index in 0..<count {
                let coordinate = GeoMath.interpolate(start, end, fraction: Double(index) / Double(count))
                points.append((coordinate.latitude, coordinate.longitude))
            }
        }
        if let last = route.waypoints.last {
            points.append((last.latitude, last.longitude))
        }
        return points
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

    /// Stable 16-byte identifier the v3 anisette protocol expects.
    static var anisetteIdentifier: String {
        if let stored = defaults.string(forKey: "anisetteIdentifier") { return stored }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let encoded = Data(bytes).base64EncodedString()
        defaults.set(encoded, forKey: "anisetteIdentifier")
        return encoded
    }
}
