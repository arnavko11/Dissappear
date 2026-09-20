import Foundation

/// Lifecycle of the development signing period for the installed test build.
/// Apple limits free and development provisioning; this type only reports that
/// state so the user can rebuild through supported tooling before it lapses.
struct DevelopmentSigningState: Equatable {
    var isSigned: Bool
    var isInstalled: Bool
    var teamID: String?
    var profileName: String?
    var expirationDate: Date?

    static let empty = DevelopmentSigningState(isSigned: false, isInstalled: false, teamID: nil, profileName: nil, expirationDate: nil)

    var daysRemaining: Int? {
        guard let expirationDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
        return max(0, days)
    }

    var needsRefresh: Bool {
        guard isInstalled else { return false }
        guard let days = daysRemaining else { return !isSigned }
        return days <= 2
    }

    var headline: String {
        if !isSigned { return "Not signed" }
        if let days = daysRemaining {
            if days == 0 { return "Expires today" }
            return "\(days) day\(days == 1 ? "" : "s") remaining"
        }
        return "Signed"
    }
}
