import Foundation
import Network
import Observation
import UIKit

/// Talks to the macOS companion over the local network so the phone can steer
/// the simulated location while the Mac holds the developer session.
///
/// Built on Network.framework rather than URLSession: these are plain local
/// connections, which the URL loading system would refuse without an App
/// Transport Security exception.
@MainActor
@Observable
final class RemoteControlClient {
    struct Status: Equatable {
        var device: String
        var simulating: Bool
        var latitude: Double
        var longitude: Double
        var name: String
        var ready: Bool
        /// Non-empty when the companion's session ended on its own.
        var sessionLost: String
        /// The phone left the Mac while a spoofed location was in force. It is
        /// still in force, and nothing can change it until the cable is back.
        var detached: Bool
    }

    /// Why the last attempt failed, kept apart so the UI can tell "the Mac is
    /// unreachable" from "the Mac is there and the session died".
    enum Trouble: Equatable {
        case unreachable(String)
        case refused(String)
    }

    struct SavedPlace: Identifiable, Equatable {
        var id: String { "\(name)-\(latitude)-\(longitude)" }
        var name: String
        var latitude: Double
        var longitude: Double
    }

    /// Handed over by the Mac when someone there approves this phone.
    private(set) var pairingCode: String {
        didSet { UserDefaults.standard.set(pairingCode, forKey: "remoteCode") }
    }
    /// The Mac this phone paired with, so it reconnects to the same one.
    private var pairedName: String {
        didSet { UserDefaults.standard.set(pairedName, forKey: "remoteName") }
    }

    enum Pairing: Equatable {
        case searching
        case waitingForApproval(String)
        case declined(String)
        case paired
    }

    private(set) var pairing: Pairing = .searching
    private(set) var status: Status?
    private(set) var places: [SavedPlace] = []
    private(set) var lastError: String?
    private(set) var trouble: Trouble?
    private(set) var isBusy = false
    /// Remembered so a lost session can be re-applied in one tap.
    private(set) var lastSent: (latitude: Double, longitude: Double, name: String?)?

    let discovery = RemoteDiscovery()
    private(set) var discovered: RemoteDiscovery.Companion?
    private var loop: Task<Void, Never>?

    init() {
        pairingCode = UserDefaults.standard.string(forKey: "remoteCode") ?? ""
        pairedName = UserDefaults.standard.string(forKey: "remoteName") ?? ""
    }

    /// Finds the Mac and keeps the connection current, with nothing for the
    /// user to type. Runs for the life of the app.
    func start() {
        guard loop == nil else { return }
        discovery.start()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func tick() async {
        let companions = discovery.companions
        // The Mac paired before, or — when there is exactly one — that one.
        let pick = companions.first { $0.name == pairedName }
            ?? (companions.count == 1 ? companions.first : nil)
        guard let pick else {
            discovered = nil
            status = nil
            if case .declined = pairing { return }
            pairing = .searching
            return
        }
        if discovered != pick { discovered = pick }

        if pick.name != pairedName || pairingCode.isEmpty {
            if case .declined = pairing { return }
            await pair(with: pick)
            return
        }
        if pairing != .paired { pairing = .paired }
        if !isBusy { await refresh() }
    }

    /// Asks the Mac for a code. Someone there has to click Allow.
    func pair(with companion: RemoteDiscovery.Companion) async {
        pairing = .waitingForApproval(companion.name)
        let body = try? JSONSerialization.data(withJSONObject: ["name": UIDevice.current.name])
        do {
            let reply = try parse(await exchange(endpoint: companion.endpoint,
                                                 payload: requestData(method: "POST", path: "/pair", body: body),
                                                 timeout: .seconds(120)))
            guard let code = reply["code"] as? String, !code.isEmpty else { throw RemoteError(message: "The Mac sent no code.") }
            pairingCode = code
            pairedName = companion.name
            pairing = .paired
            await refresh()
        } catch let failure as RemoteError where failure.message.contains("already waiting") {
            // Our own earlier request, still on screen at the Mac.
            pairing = .waitingForApproval(companion.name)
        } catch let failure as RemoteError where !failure.isReachability {
            pairing = .declined(failure.message)
        } catch {
            pairing = .searching
        }
    }

    /// Clears a refusal so the next pass asks the Mac again.
    func retryPairing() {
        pairing = .searching
        pairingCode = ""
    }

    var isConfigured: Bool { discovered != nil && !pairingCode.isEmpty && pairing == .paired }

    /// A companion answered and is not in trouble. Nothing in this app may
    /// change a location unless this is true: without a companion there is no
    /// device to spoof.
    var isConnected: Bool { status != nil && trouble == nil }

    /// The companion is connected and has a device it can actually spoof.
    var canSpoof: Bool { isConnected && (status?.ready ?? false) && status?.detached != true }

    /// Why spoofing is unavailable, in one line, or nil when it is available.
    var unavailableReason: String? {
        switch pairing {
        case .searching:
            return "Looking for the Mac companion on this Wi-Fi."
        case let .waitingForApproval(name):
            return "Click Allow on \(name) to pair."
        case let .declined(message):
            return "Pairing failed: \(message)"
        case .paired:
            break
        }
        if !isConnected {
            switch trouble {
            case let .unreachable(message), let .refused(message): return message
            case nil: return "Connecting to the Mac companion…"
            }
        }
        if status?.detached == true {
            return "The iPhone left the Mac. Plug it back in, or use the same Wi-Fi."
        }
        if status?.ready != true { return "The Mac has no iPhone it can spoof. Plug it in once and check Developer Mode." }
        return nil
    }

    // MARK: - Calls

    func refresh() async {
        guard isConfigured else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let statusPayload = try await send(method: "GET", path: "/status", body: nil)
            status = Status(device: statusPayload["device"] as? String ?? "",
                            simulating: statusPayload["simulating"] as? Bool ?? false,
                            latitude: statusPayload["latitude"] as? Double ?? 0,
                            longitude: statusPayload["longitude"] as? Double ?? 0,
                            name: statusPayload["name"] as? String ?? "",
                            ready: statusPayload["ready"] as? Bool ?? false,
                            sessionLost: statusPayload["sessionLost"] as? String ?? "",
                            detached: statusPayload["detached"] as? Bool ?? false)

            let placesPayload = try await send(method: "GET", path: "/locations", body: nil)
            places = (placesPayload["locations"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let name = entry["name"] as? String,
                      let latitude = entry["latitude"] as? Double,
                      let longitude = entry["longitude"] as? Double else { return nil }
                return SavedPlace(name: name, latitude: latitude, longitude: longitude)
            }
            lastError = nil
            trouble = nil
        } catch {
            record(error)
        }
    }

    /// Sends a coordinate without the status round trip that follows an
    /// explicit change. Used while a route is playing, where a refresh per
    /// point would triple the traffic for nothing.
    func push(latitude: Double, longitude: Double, name: String?) async {
        guard isConfigured else { return }

        var payload: [String: Any] = ["latitude": latitude, "longitude": longitude]
        if let name { payload["name"] = name }

        do {
            _ = try await send(method: "POST", path: "/location",
                               body: try JSONSerialization.data(withJSONObject: payload))
            lastSent = (latitude, longitude, name)
            trouble = nil
        } catch {
            record(error)
        }
    }

    /// Hands the companion a whole route to play in one session.
    ///
    /// Sending a route point by point does not work: each coordinate makes
    /// the companion open a fresh developer session, which takes seconds, so
    /// a route arriving once a second can never keep up with itself.
    func playRoute(name: String, waypoints: [(latitude: Double, longitude: Double)],
                   speed: Double, loops: Bool) async -> Bool {
        guard isConfigured, waypoints.count > 1 else { return false }
        isBusy = true
        defer { isBusy = false }

        let payload: [String: Any] = [
            "name": name,
            "speed": speed,
            "loops": loops,
            "waypoints": waypoints.map { ["latitude": $0.latitude, "longitude": $0.longitude] }
        ]

        do {
            _ = try await send(method: "POST", path: "/route",
                               body: try JSONSerialization.data(withJSONObject: payload))
            lastError = nil
            trouble = nil
            return true
        } catch {
            record(error)
            return false
        }
    }

    /// Re-sends the last coordinate, for when the companion lost its session.
    func reapplyLastLocation() async {
        guard let lastSent else { return }
        await setLocation(latitude: lastSent.latitude, longitude: lastSent.longitude, name: lastSent.name)
    }

    private func record(_ error: Error) {
        let message = (error as? RemoteError)?.message ?? error.localizedDescription
        lastError = message
        trouble = (error as? RemoteError)?.isReachability == true ? .unreachable(message) : .refused(message)
    }

    @discardableResult
    func setLocation(latitude: Double, longitude: Double, name: String?) async -> Bool {
        guard isConfigured else { return false }
        isBusy = true
        defer { isBusy = false }

        var payload: [String: Any] = ["latitude": latitude, "longitude": longitude]
        if let name { payload["name"] = name }

        do {
            _ = try await send(method: "POST", path: "/location",
                               body: try JSONSerialization.data(withJSONObject: payload))
            lastError = nil
            trouble = nil
            lastSent = (latitude, longitude, name)
            await refresh()
            return true
        } catch {
            record(error)
            return false
        }
    }

    func clearLocation() async {
        guard isConfigured else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await send(method: "POST", path: "/clear", body: nil)
            lastError = nil
            trouble = nil
            lastSent = nil
            await refresh()
        } catch {
            record(error)
        }
    }

    // MARK: - Transport

    struct RemoteError: Error {
        var message: String
        /// True when the companion could not be reached at all, as opposed to
        /// reached and refusing.
        var isReachability = false
        /// The Mac no longer knows this phone's code.
        var isUnpaired = false
    }

    private func send(method: String, path: String, body: Data?) async throws -> [String: Any] {
        guard let discovered else {
            throw RemoteError(message: "The Mac companion is not on this network.", isReachability: true)
        }
        do {
            return try parse(await exchange(endpoint: discovered.endpoint,
                                            payload: requestData(method: method, path: path, body: body)))
        } catch let failure as RemoteError where failure.isUnpaired {
            // The Mac forgot this phone; ask again rather than failing forever.
            pairingCode = ""
            pairing = .searching
            throw failure
        }
    }

    private func requestData(method: String, path: String, body: Data?) -> Data {
        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: companion\r\n"
        request += "X-Pair-Code: \(pairingCode)\r\n"
        request += "Connection: close\r\n"
        if let body {
            request += "Content-Type: application/json\r\n"
            request += "Content-Length: \(body.count)\r\n"
        }
        request += "\r\n"

        var payload = Data(request.utf8)
        if let body { payload.append(body) }
        return payload
    }

    private func parse(_ response: Data) throws -> [String: Any] {
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw RemoteError(message: "The companion sent an unreadable reply.")
        }

        let head = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
        let bodyData = response[separator.upperBound...]
        let json = (try? JSONSerialization.jsonObject(with: Data(bodyData)) as? [String: Any]) ?? [:]

        guard head.contains(" 200 ") else {
            throw RemoteError(message: json["error"] as? String ?? "The companion refused the request.",
                              isUnpaired: head.contains(" 401 "))
        }
        return json
    }

    /// How long a single request may take before it is abandoned. Local
    /// network round trips are milliseconds; anything near this is a Mac that
    /// is not answering.
    private static let requestTimeout: Duration = .seconds(8)

    private func exchange(endpoint: NWEndpoint, payload: Data,
                          timeout: Duration = RemoteControlClient.requestTimeout) async throws -> Data {
        let connection = NWConnection(to: endpoint, using: .tcp)
        let finished = Finished()

        return try await withCheckedThrowingContinuation { continuation in
            // Nothing below may hang forever. A connection that is refused or
            // filtered — a firewall on the Mac, the companion switched off,
            // the phone on a different network — settles in `.waiting` and
            // retries there silently for as long as it is allowed to. That is
            // not `.failed`, so the old code never resumed: the request stayed
            // in flight, the spinner never stopped, and Connect stayed
            // disabled with no way back.
            let timeout = Task.detached {
                try? await Task.sleep(for: timeout)
                guard finished.claim() else { return }
                connection.cancel()
                continuation.resume(throwing: RemoteError(
                    message: "The Mac companion did not answer. Check it is open, and that macOS is not blocking incoming connections (companion ▸ Settings ▸ Remote Control).",
                    isReachability: true))
            }

            let fail: @Sendable (String) -> Void = { message in
                guard finished.claim() else { return }
                timeout.cancel()
                connection.cancel()
                continuation.resume(throwing: RemoteError(message: message, isReachability: true))
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error {
                            guard finished.claim() else { return }
                            timeout.cancel()
                            connection.cancel()
                            continuation.resume(throwing: RemoteError(message: error.localizedDescription))
                            return
                        }
                        Self.receiveAll(connection, buffer: Data()) { result in
                            guard finished.claim() else { return }
                            timeout.cancel()
                            connection.cancel()
                            continuation.resume(with: result)
                        }
                    })

                case let .waiting(error):
                    // A refusal is final, whatever Network.framework intends to
                    // do about it; anything vaguer is left to the timeout in
                    // case the interface is still coming up.
                    if Self.isFinal(error) {
                        fail("Could not reach the companion. \(error.localizedDescription)")
                    }

                case let .failed(error):
                    fail("Could not reach the companion. \(error.localizedDescription)")

                case .cancelled:
                    fail("The connection closed.")

                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Errors that will not resolve themselves by waiting.
    private nonisolated static func isFinal(_ error: NWError) -> Bool {
        guard case let .posix(code) = error else { return false }
        return code == .ECONNREFUSED || code == .EHOSTUNREACH
            || code == .ENETUNREACH || code == .ETIMEDOUT
    }

    /// Reads until the peer closes, which the companion does after replying.
    ///
    /// Runs on the connection's queue, not the main actor: it is driven by
    /// network callbacks.
    private nonisolated static func receiveAll(_ connection: NWConnection,
                                               buffer: Data,
                                               completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let error {
                completion(.failure(RemoteError(message: error.localizedDescription)))
                return
            }
            if isComplete {
                completion(.success(accumulated))
                return
            }
            receiveAll(connection, buffer: accumulated, completion: completion)
        }
    }

    /// Guards the continuation so it can only be resumed once.
    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
