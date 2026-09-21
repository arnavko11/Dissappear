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
            throw CocoaError(.fileReadCorruptFile)
        }

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
    }

    func removeRecord() {
        try? FileManager.default.removeItem(at: Self.url)
        refresh()
    }
}
