import Foundation

/// Apple's authentication requires per-device "anisette" headers. macOS can
/// produce them itself through AuthKit — the same path Xcode uses to sign in on
/// this machine — so nothing proprietary is reimplemented here.
///
/// AuthKit is a private framework, reached through the Objective-C runtime so
/// that a missing or renamed symbol degrades into a clear error rather than a
/// crash on a future macOS release.
struct AnisetteProvider {
    static let xcodeSessionIdentifier = "com.apple.gs.xcode.auth"

    func headers() throws -> [String: String] {
        guard dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_LAZY) != nil else {
            throw AppleIDError.anisetteUnavailable("AuthKit could not be loaded on this Mac.")
        }

        guard let sessionClass = NSClassFromString("AKAppleIDSession") as? NSObject.Type else {
            throw AppleIDError.anisetteUnavailable("AKAppleIDSession is not available on this version of macOS.")
        }

        // Swift does not expose +alloc, so the allocation goes through the
        // Objective-C runtime as well.
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
              let headers = result as? [String: String],
              !headers.isEmpty else {
            throw AppleIDError.anisetteUnavailable("AuthKit returned no anisette headers.")
        }
        return headers
    }

    /// The client-provided dictionary Apple expects alongside every request.
    ///
    /// Anisette values are a matched set: the one-time password in
    /// `X-Apple-I-MD` is only valid with the machine identifier in
    /// `X-Apple-I-MD-M` that was generated with it. Callers therefore generate
    /// one set per sign-in and pass it here, rather than letting this method
    /// mint a second, mismatched set.
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
        case let .authenticationFailed(code, message): return "\(message) (error \(code))"
        case .twoFactorRequired: return "A verification code is required."
        case .notSignedIn: return "Sign in with your Apple ID first."
        case .cancelled: return "Sign in was cancelled."
        }
    }

    /// What the user can actually do about it.
    var recoverySuggestion: String? {
        switch self {
        case .anisetteUnavailable:
            return "This needs macOS's own AuthKit framework. Signing in through Xcode instead will also produce a certificate this app can use."
        case .authenticationFailed:
            return "Check the Apple ID and password, then try again. Repeated failures can lock the account temporarily."
        case .twoFactorRequired:
            return "Enter the six-digit code shown on your trusted device."
        case .protocolFailure:
            return "Apple's authentication service may have changed. Use the Xcode signing path instead."
        case .notSignedIn, .cancelled:
            return nil
        }
    }
}
