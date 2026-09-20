import Foundation

/// Reports a mesh VPN address for this Mac, if one is configured.
///
/// Bonjour only reaches the same network. To steer the phone from anywhere,
/// the two devices need to share a network wherever they are — which is what a
/// mesh VPN provides, with its own device authentication and encryption. That
/// is a far better answer than forwarding a port, which would put this plain
/// HTTP server on the open internet.
struct MeshNetworkService {
    struct Address: Equatable {
        var hostName: String
        var ip: String
        var provider: String
    }

    private static let tailscalePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    ]

    private let runner = ProcessRunner.shared

    /// The address to give the phone for use away from home.
    func remoteAddress() async -> Address? {
        guard let path = Self.tailscalePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let result = try? await runner.run(path, ["status", "--json"]),
              result.succeeded,
              let data = result.standardOutput.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let this = root["Self"] as? [String: Any] else { return nil }

        let dnsName = (this["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let ip = (this["TailscaleIPs"] as? [String])?.first ?? ""
        guard !dnsName.isEmpty || !ip.isEmpty else { return nil }

        return Address(hostName: dnsName.isEmpty ? ip : dnsName,
                       ip: ip,
                       provider: "Tailscale")
    }
}
