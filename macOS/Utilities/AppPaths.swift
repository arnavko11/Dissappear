import Foundation

/// Directories the companion writes to.
///
/// The system lookup returns an array that is empty in odd states, and
/// force-unwrapping it turned that into a crash on launch for something the
/// app can trivially work around.
enum AppPaths {
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
