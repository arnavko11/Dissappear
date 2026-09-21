import Foundation

/// Finds a working anisette server so Apple ID sign-in can be attempted
/// without the user hunting for one.
///
/// macOS 26 and later withhold this Mac's own anisette from apps that lack
/// Apple's private entitlements, so sign-in fails with "MID is invalid" unless
/// a server is configured. The community keeps a published list; this fetches
/// it and picks the first entry that actually answers.
struct AnisetteDiscovery {
    struct Server: Equatable, Identifiable {
        var name: String
        var address: String
        var id: String { address }
    }

    /// The community-maintained list. Nothing is sent to it but the request.
    private static let directoryURL = URL(string: "https://servers.sidestore.io/servers.json")!

    /// Known-good fallbacks, used when the directory itself cannot be reached.
    private static let fallbacks = [
        Server(name: "SideStore", address: "https://ani.sidestore.io"),
        Server(name: "Nythepegasus", address: "https://sideloadly.io/anisette/irGb3Quww8zrhgqnzmrx")
    ]

    /// Downloads the directory, or returns the fallbacks if it is unreachable.
    func available() async -> [Server] {
        var request = URLRequest(url: Self.directoryURL)
        request.timeoutInterval = 8

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["servers"] as? [[String: Any]] else {
            return Self.fallbacks
        }

        let parsed = entries.compactMap { entry -> Server? in
            guard let address = entry["address"] as? String, !address.isEmpty else { return nil }
            return Server(name: entry["name"] as? String ?? address, address: address)
        }
        return parsed.isEmpty ? Self.fallbacks : parsed
    }

    /// Returns the first server that answers a real anisette request.
    func firstReachable() async -> Server? {
        for server in await available() {
            if await responds(server) { return server }
        }
        return nil
    }

    private func responds(_ server: Server) async -> Bool {
        guard let base = URL(string: server.address) else { return false }
        var request = URLRequest(url: base)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<500).contains(http.statusCode)
    }
}
