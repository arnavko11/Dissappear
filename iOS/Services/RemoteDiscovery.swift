import Foundation
import Network
import Observation

/// Finds companions on the local network so neither end has to be told an
/// address. Uses Bonjour, which the system resolves on the app's behalf — raw
/// multicast or broadcast discovery would need an entitlement Apple grants by
/// request only.
@MainActor
@Observable
final class RemoteDiscovery {
    struct Companion: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var endpoint: NWEndpoint
    }

    private(set) var companions: [Companion] = []
    private(set) var isBrowsing = false
    private(set) var failure: String?

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: ControlServiceType.name, domain: nil), using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isBrowsing = true
                    self?.failure = nil
                case let .failed(error):
                    self?.isBrowsing = false
                    self?.failure = "Could not search the local network. \(error.localizedDescription)"
                    self?.stop()
                case .cancelled:
                    self?.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.companions = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    return Companion(name: name, endpoint: result.endpoint)
                }
                .sorted { $0.name < $1.name }
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }
}

/// Shared with the companion, which advertises the same type.
enum ControlServiceType {
    static let name = "_dissappear._tcp"
}
