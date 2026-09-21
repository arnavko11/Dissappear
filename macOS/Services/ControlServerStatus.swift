import Foundation

/// What the remote-control listener is actually doing, as opposed to what
/// `start()` was asked to do.
enum ControlServerStatus: Equatable {
    case off
    case starting
    case running
    case failed(String)

    var label: String {
        switch self {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .running: return "Listening"
        case .failed: return "Failed"
        }
    }

    var message: String? {
        if case let .failed(reason) = self { return reason }
        return nil
    }
}
