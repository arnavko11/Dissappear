import Foundation

/// Holds the pairing record the phone needs to open its own developer
/// services.
///
/// The record is a credential: anything holding it can reach this device's
/// developer surface. It is kept in Application Support rather than Documents
/// so it is not exposed over file sharing, and excluded from backups so it
/// does not travel to other devices with a restore.
@MainActor
@Observable
final class PairingRecordStore {
    private(set) var importedAt: Date?

    /// Where the record lives, if one has been imported.
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory
        return base.appendingPathComponent("pairing-record.plist")
    }

    var hasRecord: Bool { FileManager.default.fileExists(atPath: Self.url.path) }

    init() {
        // A record kept from an older version lacks the remote pairing and
        // would be refused on every spoof, always with the same message.
        // Dropping it makes the app say "set up" instead of failing forever.
        if let data = try? Data(contentsOf: Self.url), (try? Self.validate(data)) == nil {
            try? FileManager.default.removeItem(at: Self.url)
        }
        refresh()
    }

    /// Where the Mac companion drops a record over USB (house_arrest writes
    /// into the app's container, as iloader does for StikDebug).
    static var placedURL: URL {
        URL.documentsDirectory.appendingPathComponent("pairing-record.plist")
    }

    /// Takes a record the Mac placed, if there is one. Called at launch and
    /// whenever the app comes forward. The placed copy is removed either way:
    /// it is a credential, and Documents is visible to file sharing.
    @discardableResult
    func pickUpPlacedRecord() -> Bool {
        let placed = Self.placedURL
        guard FileManager.default.fileExists(atPath: placed.path) else { return false }
        defer { try? FileManager.default.removeItem(at: placed) }
        do {
            try importRecord(from: placed)
            return true
        } catch {
            lastPickUpFailure = error.localizedDescription
            return false
        }
    }

    /// The stored record's key names — never the values, which are secrets —
    /// so diagnostics can say what the record carries.
    var recordKeys: [String] {
        guard let data = try? Data(contentsOf: Self.url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return plist.keys.sorted()
    }

    /// Why a record the Mac placed could not be used.
    var lastPickUpFailure: String?

    func refresh() {
        importedAt = try? FileManager.default
            .attributesOfItem(atPath: Self.url.path)[.creationDate] as? Date
    }

    /// Copies a record chosen in the file picker into place.
    ///
    /// The picked file lives outside the app's sandbox, so it is opened as a
    /// security-scoped resource; without that the read fails for a file the
    /// user plainly just chose.
    func importRecord(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: source)
        guard data.count > 32, data.count < 1_000_000 else {
            throw ImportFailure.notARecord
        }
        try Self.validate(data)

        let destination = Self.url
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination, options: .completeFileProtection)

        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutable = destination
        try? mutable.setResourceValues(excluded)

        refresh()
        onRecordChanged?()
    }

    /// Called when the record changes, so anything holding a connection made
    /// with the old one can let it go.
    var onRecordChanged: (() -> Void)?

    enum ImportFailure: LocalizedError {
        case notARecord
        case noRemotePairing

        var errorDescription: String? {
            switch self {
            case .notARecord:
                return "That file is not a pairing record."
            case .noRemotePairing:
                return "That record was made by an older Mac companion and lacks the remote pairing this iPhone checks. Update the companion, plug the iPhone in, click Set Up iPhone Spoofing (Devices), and tap Trust — the new record arrives in this app by itself."
            }
        }
    }

    /// The phone reaches itself through RemotePairing, so the record must
    /// carry an Ed25519 key pair and the identifier it was paired under —
    /// the keys idevice's `RpPairingFile` reads. The lockdown half that
    /// travels in the same file is not needed here.
    private static func validate(_ data: Data) throws {
        guard let plist = try? PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportFailure.notARecord
        }
        guard (plist["public_key"] as? Data)?.count == 32,
              (plist["private_key"] as? Data)?.count == 32,
              plist["identifier"] is String else {
            throw ImportFailure.noRemotePairing
        }
    }

    func removeRecord() {
        try? FileManager.default.removeItem(at: Self.url)
        refresh()
        onRecordChanged?()
    }
}
