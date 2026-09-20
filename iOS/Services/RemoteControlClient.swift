import Foundation
import Network
import Observation

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
    }

    struct SavedPlace: Identifiable, Equatable {
        var id: String { "\(name)-\(latitude)-\(longitude)" }
        var name: String
        var latitude: Double
        var longitude: Double
    }

    var host: String {
        didSet { Self.store(host, forKey: "remoteHost") }
    }
    var port: String {
        didSet { Self.store(port, forKey: "remotePort") }
    }
    var pairingCode: String {
        didSet { Self.store(pairingCode, forKey: "remoteCode") }
    }

    private(set) var status: Status?
    private(set) var places: [SavedPlace] = []
    private(set) var lastError: String?
    private(set) var isBusy = false

    init() {
        host = UserDefaults.standard.string(forKey: "remoteHost") ?? ""
        port = UserDefaults.standard.string(forKey: "remotePort") ?? "8787"
        pairingCode = UserDefaults.standard.string(forKey: "remoteCode") ?? ""
    }

    private static func store(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !pairingCode.isEmpty
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
                            ready: statusPayload["ready"] as? Bool ?? false)

            let placesPayload = try await send(method: "GET", path: "/locations", body: nil)
            places = (placesPayload["locations"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let name = entry["name"] as? String,
                      let latitude = entry["latitude"] as? Double,
                      let longitude = entry["longitude"] as? Double else { return nil }
                return SavedPlace(name: name, latitude: latitude, longitude: longitude)
            }
            lastError = nil
        } catch {
            lastError = (error as? RemoteError)?.message ?? error.localizedDescription
        }
    }

    func setLocation(latitude: Double, longitude: Double, name: String?) async {
        guard isConfigured else { return }
        isBusy = true
        defer { isBusy = false }

        var payload: [String: Any] = ["latitude": latitude, "longitude": longitude]
        if let name { payload["name"] = name }

        do {
            _ = try await send(method: "POST", path: "/location",
                               body: try JSONSerialization.data(withJSONObject: payload))
            lastError = nil
            await refresh()
        } catch {
            lastError = (error as? RemoteError)?.message ?? error.localizedDescription
        }
    }

    func clearLocation() async {
        guard isConfigured else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await send(method: "POST", path: "/clear", body: nil)
            lastError = nil
            await refresh()
        } catch {
            lastError = (error as? RemoteError)?.message ?? error.localizedDescription
        }
    }

    // MARK: - Transport

    struct RemoteError: Error {
        var message: String
    }

    private func send(method: String, path: String, body: Data?) async throws -> [String: Any] {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard let portNumber = UInt16(port.trimmingCharacters(in: .whitespaces)),
              let endpointPort = NWEndpoint.Port(rawValue: portNumber) else {
            throw RemoteError(message: "That port is not valid.")
        }

        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: \(trimmedHost)\r\n"
        request += "X-Pair-Code: \(pairingCode)\r\n"
        request += "Connection: close\r\n"
        if let body {
            request += "Content-Type: application/json\r\n"
            request += "Content-Length: \(body.count)\r\n"
        }
        request += "\r\n"

        var payload = Data(request.utf8)
        if let body { payload.append(body) }

        let response = try await exchange(host: trimmedHost, port: endpointPort, payload: payload)
        guard let separator = response.range(of: Data("\r\n\r\n".utf8)) else {
            throw RemoteError(message: "The companion sent an unreadable reply.")
        }

        let head = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
        let bodyData = response[separator.upperBound...]
        let json = (try? JSONSerialization.jsonObject(with: Data(bodyData)) as? [String: Any]) ?? [:]

        guard head.contains(" 200 ") else {
            throw RemoteError(message: json["error"] as? String ?? "The companion refused the request.")
        }
        return json
    }

    private func exchange(host: String, port: NWEndpoint.Port, payload: Data) async throws -> Data {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)

        return try await withCheckedThrowingContinuation { continuation in
            let finished = Finished()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error {
                            if finished.claim() {
                                connection.cancel()
                                continuation.resume(throwing: RemoteError(message: error.localizedDescription))
                            }
                            return
                        }
                        Self.receiveAll(connection, buffer: Data()) { result in
                            guard finished.claim() else { return }
                            connection.cancel()
                            continuation.resume(with: result)
                        }
                    })
                case let .failed(error):
                    if finished.claim() {
                        connection.cancel()
                        continuation.resume(throwing: RemoteError(
                            message: "Could not reach the companion. \(error.localizedDescription)"))
                    }
                case .cancelled:
                    if finished.claim() {
                        continuation.resume(throwing: RemoteError(message: "The connection closed."))
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Reads until the peer closes, which the companion does after replying.
    private static func receiveAll(_ connection: NWConnection,
                                   buffer: Data,
                                   completion: @escaping (Result<Data, Error>) -> Void) {
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
