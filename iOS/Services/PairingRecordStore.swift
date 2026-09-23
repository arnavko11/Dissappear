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
        refresh()
    }

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

    /// What a record has to contain before it is worth keeping.
    ///
    /// These are the keys idevice insists on. Checking them here turns a
    /// malformed export into a message at import, rather than a broken pipe
    /// three steps later when the device hangs up on the session.
    enum ImportFailure: LocalizedError {
        case notARecord
        case missingKeys([String])
        case noEscrowBag

        var errorDescription: String? {
            switch self {
            case .notARecord:
                return "That file is not a pairing record."
            case let .missingKeys(keys):
                return "That pairing record is missing \(keys.joined(separator: ", ")). Export Pairing Record again from the Mac companion."
            case .noEscrowBag:
                return "That record is a copy of the Mac's own pairing, which macOS gives out without the escrow bag — and without it the iPhone hangs up on every session. Update the Mac companion, then Export Pairing Record again with the iPhone plugged in and unlocked, and tap Trust. The new export pairs fresh and includes it."
            }
        }
    }

    private static func validate(_ data: Data) throws {
        guard let plist = try? PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportFailure.notARecord
        }

        let required = ["DeviceCertificate", "HostPrivateKey", "HostCertificate",
                        "RootPrivateKey", "RootCertificate",
                        "SystemBUID", "HostID", "WiFiMACAddress"]
        let missing = required.filter { plist[$0] == nil }
        guard missing.isEmpty else { throw ImportFailure.missingKeys(missing) }

        // Optional to idevice, but without it the device refuses a session
        // while locked — which is most of the time, and reads as a mystery.
        guard plist["EscrowBag"] != nil else { throw ImportFailure.noEscrowBag }
    }

    func removeRecord() {
        try? FileManager.default.removeItem(at: Self.url)
        refresh()
        onRecordChanged?()
    }
}
