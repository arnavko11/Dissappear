import Foundation
import SwiftUI

@MainActor
final class CompanionModel: ObservableObject {
    @Published private(set) var toolchain: ToolchainStatus = .unknown
    @Published private(set) var devices: [Device] = []
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
    private let signingService = SigningService()
    private let buildService = BuildService()
    private let installationService = InstallationService()
    private let libraryStore: LibraryStore

    private var bundleIdentifier = "com.dissappear.testapp"

    init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
        var configuration = BuildConfiguration.default
        if let stored = Preferences.projectPath, !stored.isEmpty {
            configuration.projectPath = stored
        }
        self.configuration = configuration
        selectedIdentityID = Preferences.identityID
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

    // MARK: - Refresh

    func refreshAll() async {
        toolchain = await toolchainService.status()
        await refreshDevices()
        await refreshSigning()
        await refreshInstallationState()
    }

    func refreshDevices() async {
        guard toolchain.hasDeviceCtl else {
            devices = []
            return
        }
        do {
            let discovered = try await deviceService.connectedDevices().filter(\.isPhysicalIOSDevice)
            devices = discovered
            if selectedDeviceID == nil || !discovered.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = discovered.first?.id
            }
        } catch let failure as CompanionError {
            error = failure
            devices = []
        } catch {
            self.error = .generic("Device discovery failed", error)
            devices = []
        }
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
            let apps = try await installationService.installedApps(on: device)
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
        await runWorkflow(launchWhenInstalled: false)
    }

    func reinstall() async {
        await runWorkflow(launchWhenInstalled: true)
    }

    func launchInstalledApp() async {
        guard let device = selectedDevice else { return }
        isBusy = true
        defer { isBusy = false; activity = nil }
        activity = "Launching on \(device.name)"
        do {
            try await installationService.launch(bundleIdentifier: bundleIdentifier, on: device)
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
            try await installationService.uninstall(bundleIdentifier: bundleIdentifier, from: device)
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
            try await installationService.install(product: built, on: device) { [weak self] line in
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
            try await installationService.launch(bundleIdentifier: built.bundleIdentifier, on: device)
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
}
