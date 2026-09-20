import Foundation

struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var name: String
    var version: String
    var installationURL: String?
}
