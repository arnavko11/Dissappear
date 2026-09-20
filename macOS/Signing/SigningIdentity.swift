import Foundation

/// An Apple Development identity present in the user's keychain.
/// Only public metadata is read — no credentials are stored or transmitted.
struct SigningIdentity: Identifiable, Hashable, Sendable {
    var id: String { sha1 }
    var sha1: String
    var commonName: String
    var teamID: String

    var isDevelopment: Bool {
        commonName.hasPrefix("Apple Development") || commonName.hasPrefix("iPhone Developer")
    }

    var displayName: String {
        teamID.isEmpty ? commonName : "\(commonName)"
    }
}
