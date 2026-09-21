// Exposes idevice's C API to Swift.
//
// idevice is the Rust client for Apple's iOS services. The app uses it to open
// the developer location service on the very device it is running on, which is
// how a location is spoofed with no computer attached.
//
// The header and static library are fetched by Scripts/fetch-idevice.sh; they
// are too large to keep in the repository.
#import "idevice.h"
