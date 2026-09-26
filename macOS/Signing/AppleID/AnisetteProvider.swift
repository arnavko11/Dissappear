import Foundation

/// Supplies the per-device "anisette" data Apple's authentication requires.
///
/// macOS 26 and later gate anisette behind private entitlements: the AOSKit and
/// AuthKit calls return empty data to any app that does not hold them, and on
/// macOS 27 the underlying call fails outright. Apple's sign-in service then
/// rejects the request with "MID is invalid" (-80009).
///
/// So this provider tries the local path first and falls back to an anisette
/// server the user configures. That is the same public v3 protocol the
/// sideloading ecosystem moved to for exactly this reason.
struct AnisetteProvider {
    static let xcodeSessionIdentifier = "com.apple.gs.xcode.auth"

    /// Keys that must be present for Apple to accept the request.
    private static let requiredKeys = ["X-Apple-I-MD", "X-Apple-I-MD-M"]

    var serverURL: URL? = Preferences.anisetteServerURL

    func headers() async throws -> [String: String] {
        if let serverURL {
            return Self.canonical(try await RemoteAnisette(server: serverURL).headers())
        }

        let local = try localHeaders()
        guard Self.requiredKeys.allSatisfy({ (local[$0]?.isEmpty == false) }) else {
            throw AppleIDError.anisetteUnavailable(Self.gatedExplanation)
        }
        return local
    }

    static let gatedExplanation = """
    macOS did not provide anisette data. Since macOS 26, Apple gates it behind \
    private entitlements, so apps outside Apple's own tooling receive nothing \
    and sign-in fails with "MID is invalid".
    """

    // MARK: - Local

    /// AuthKit's own headers. Still tried first: it costs nothing, and it works
    /// on older systems without involving any third party.
    private func localHeaders() throws -> [String: String] {
        guard dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_LAZY) != nil else {
            throw AppleIDError.anisetteUnavailable("AuthKit could not be loaded on this Mac.")
        }
        guard let sessionClass = NSClassFromString("AKAppleIDSession") as? NSObject.Type else {
            throw AppleIDError.anisetteUnavailable("AKAppleIDSession is not available on this version of macOS.")
        }

        // Swift does not expose +alloc, so allocation also goes through the runtime.
        let initSelector = NSSelectorFromString("initWithIdentifier:")
        guard let allocated = sessionClass.perform(NSSelectorFromString("alloc"))?
                  .takeRetainedValue() as? NSObject,
              allocated.responds(to: initSelector),
              let session = allocated.perform(initSelector, with: Self.xcodeSessionIdentifier)?
                  .takeUnretainedValue() as? NSObject else {
            throw AppleIDError.anisetteUnavailable("AKAppleIDSession could not be created.")
        }

        let headerSelector = NSSelectorFromString("appleIDHeadersForRequest:")
        let request = NSMutableURLRequest(url: AppleIDEndpoint.grandSlam)
        guard session.responds(to: headerSelector),
              let result = session.perform(headerSelector, with: request)?.takeUnretainedValue(),
              let headers = result as? [String: String] else {
            throw AppleIDError.anisetteUnavailable(Self.gatedExplanation)
        }
        return headers
    }

    // MARK: - Remote

    /// Servers spell one header two ways (`X-MMe-Client-Info` from v1,
    /// `X-Mme-Client-Info` elsewhere). Lookups are case-sensitive, so the
    /// client info silently went missing; one spelling from here on.
    static func canonical(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            result[key.lowercased() == "x-mme-client-info" ? "X-Mme-Client-Info" : key] = value
        }
        return result
    }

    /// Accepts both the flat header dictionary and the v3 envelope.
    static func parse(_ data: Data) -> [String: String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let source = (json["headers"] as? [String: Any]) ?? json

        var headers: [String: String] = [:]
        for (key, value) in source {
            if let string = value as? String { headers[key] = string }
        }
        guard requiredKeys.allSatisfy({ headers[$0]?.isEmpty == false }) else { return nil }
        return headers
    }

    // MARK: - Client data

    /// The client-provided dictionary Apple expects alongside every request.
    ///
    /// Anisette values are a matched set: the one-time password in
    /// `X-Apple-I-MD` is only valid with the machine identifier in
    /// `X-Apple-I-MD-M` generated with it, so callers obtain one set per
    /// sign-in and pass it here rather than minting a second.
    func clientProvidedData(from headers: [String: String]) -> [String: Any] {
        var data: [String: Any] = headers
        data["bootstrap"] = true
        data["icscrec"] = true
        data["pbe"] = false
        data["prkgen"] = true
        data["svct"] = "iCloud"
        data["loc"] = Locale.current.identifier
        data["X-Apple-Locale"] = Locale.current.identifier
        data["X-Apple-I-Client-Time"] = ISO8601DateFormatter().string(from: Date())
        data["X-Apple-I-TimeZone"] = TimeZone.current.abbreviation() ?? "UTC"
        return data
    }
}

enum AppleIDEndpoint {
    static let grandSlam = URL(string: "https://gsa.apple.com/grandslam/GsService2")!
    static let validate = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!
    static let trustedDevice = URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!
    static let trustedDeviceCode = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!
    static let developerServices = URL(string: "https://developerservices2.apple.com/services/QH65B2/")!
}

enum AppleIDError: LocalizedError, Equatable {
    case anisetteUnavailable(String)
    case protocolFailure(String)
    case authenticationFailed(code: Int, message: String)
    case twoFactorRequired
    case notSignedIn
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .anisetteUnavailable(detail): return detail
        case let .protocolFailure(detail): return detail
        case let .authenticationFailed(code, message):
            if code == -80009 {
                return "Apple rejected this Mac's device identifier. \(AnisetteProvider.gatedExplanation)"
            }
            return "\(message) (error \(code))"
        case .twoFactorRequired: return "A verification code is required."
        case .notSignedIn: return "Sign in with your Apple ID first."
        case .cancelled: return "Sign in was cancelled."
        }
    }

    /// What the user can actually do about it.
    var recoverySuggestion: String? {
        switch self {
        case .anisetteUnavailable:
            return "Set an anisette server in Settings, or use Install Without Building with a provisioning profile, which needs no Apple ID sign-in."
        case let .authenticationFailed(code, _) where code == -80009:
            return "Set an anisette server in Settings, or use Install Without Building with a provisioning profile."
        case .authenticationFailed:
            return "Check the Apple ID and password, then try again. Repeated failures can lock the account temporarily."
        case .twoFactorRequired:
            return "Enter the six-digit code shown on your trusted device."
        case .protocolFailure:
            return "Apple's authentication service may have changed. Use a provisioning profile instead."
        case .notSignedIn, .cancelled:
            return nil
        }
    }
}
