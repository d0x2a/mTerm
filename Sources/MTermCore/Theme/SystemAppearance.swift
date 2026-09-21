#if canImport(AppKit)
import AppKit
#endif
import Foundation

/// Which appearance the host is currently showing, for auto light/dark themes.
///
/// AppKit can answer for itself from `NSApp`. UIKit cannot — appearance there
/// is a per-view trait rather than an application-wide one — so a UIKit host
/// installs `isDarkProvider` instead and answers from its own trait collection.
///
/// The AppKit read is optional-chained deliberately: `NSApp` is nil in a
/// process that never made an application, which is exactly the case in
/// `scripts/statecheck.sh`.
package enum SystemAppearance {
    /// Set by the host when it can answer better than the default below.
    package static var isDarkProvider: (() -> Bool)?

    package static var isDark: Bool {
        if let provider = isDarkProvider { return provider() }
        #if canImport(AppKit)
        return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
        return false
        #endif
    }
}
