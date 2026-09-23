import Foundation

/// Keeps lockdownd's heartbeat answered while this phone talks to itself.
///
/// The loopback VPN makes our connection look like one from the network, and
/// lockdownd drops network hosts that stop answering its heartbeat. Every
/// on-device tool built on idevice runs this loop for that reason.
///
/// It runs on its own thread with its own provider: `heartbeat_get_marco`
/// blocks for up to the interval, and idevice handles are not shared across
/// threads here. The thread owns and frees every handle it makes, so stopping
/// only raises a flag — freeing from outside while it blocks would be a
/// use-after-free.
final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    /// Connects, then keeps answering in the background. Returns once the
    /// first connection is made, or throws the error that prevented it — the
    /// clearest sign of whether lockdownd accepts this pairing record at all.
    func start(pairingRecordPath: String,
               address: sockaddr_in) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let thread = Thread { [self] in
                var address = address
                var pairing: OpaquePointer?
                if let error = idevice_pairing_file_read(pairingRecordPath, &pairing) {
                    continuation.resume(throwing: HeartbeatError(error))
                    return
                }

                var provider: OpaquePointer?
                let providerError = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        // Takes the pairing file.
                        idevice_tcp_provider_new($0, pairing, "Dissappear", &provider)
                    }
                }
                if let providerError {
                    continuation.resume(throwing: HeartbeatError(providerError))
                    return
                }
                defer { idevice_provider_free(provider) }

                var client: OpaquePointer?
                if let error = heartbeat_connect(provider, &client) {
                    continuation.resume(throwing: HeartbeatError(error))
                    return
                }
                defer { heartbeat_client_free(client) }
                continuation.resume()

                var interval: UInt64 = 15
                while !isStopped {
                    var next: UInt64 = 0
                    if let error = heartbeat_get_marco(client, interval, &next) {
                        idevice_error_free(error)
                        return
                    }
                    interval = next + 5
                    if let error = heartbeat_send_polo(client) {
                        idevice_error_free(error)
                        return
                    }
                }
            }
            thread.name = "Dissappear heartbeat"
            thread.start()
        }
    }
}

/// An idevice error carried out of the heartbeat thread.
struct HeartbeatError: Error {
    let message: String

    init(_ error: UnsafeMutablePointer<IdeviceFfiError>) {
        message = error.pointee.message.map { String(cString: $0) } ?? "unknown error"
        idevice_error_free(error)
    }
}
