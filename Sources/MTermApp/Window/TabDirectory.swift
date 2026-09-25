import Foundation

/// Something that follows the app's tabs from outside any window — a second
/// head showing the same tabs, say.
package protocol TabObserver: AnyObject {
    /// The tab set changed: a tab opened, closed or moved, was renamed or
    /// selected, or its session started. On the main thread, and coalesced —
    /// a sidebar drag, which removes a tab and reinserts it, arrives as one
    /// call after both — so compare `TabDirectory.shared.tabs` against what
    /// was there last time rather than expecting one call per change.
    func tabsDidChange()
}

/// Every terminal tab in the app, and the one place to hear when that
/// changes. Main thread only.
///
/// Windows report into it rather than it asking `NSApp.windows`, whose order
/// follows focus: a list of tabs shouldn't reshuffle because a different
/// window came to the front.
package final class TabDirectory {
    package static let shared = TabDirectory()

    private struct WeakWindow { weak var controller: MainWindowController? }
    private struct WeakObserver { weak var observer: TabObserver? }

    private var windows: [WeakWindow] = []
    private var observers: [WeakObserver] = []
    private var notifyScheduled = false

    /// Every tab, in the order the windows opened and then sidebar order.
    package var tabs: [Tab] {
        windows.compactMap(\.controller).flatMap(\.tabs)
    }

    /// Whether `tab` is the one its window is showing.
    package func isActive(_ tab: Tab) -> Bool {
        windows.contains { $0.controller?.activeTabId == tab.id }
    }

    package func addObserver(_ observer: TabObserver) {
        observers.removeAll { $0.observer == nil || $0.observer === observer }
        observers.append(WeakObserver(observer: observer))
    }

    package func removeObserver(_ observer: TabObserver) {
        observers.removeAll { $0.observer == nil || $0.observer === observer }
    }

    func register(_ controller: MainWindowController) {
        windows.removeAll { $0.controller == nil }
        windows.append(WeakWindow(controller: controller))
        setNeedsNotify()
    }

    func unregister(_ controller: MainWindowController) {
        windows.removeAll { $0.controller == nil || $0.controller === controller }
        setNeedsNotify()
    }

    /// Called wherever the tab set changes. Observers hear about it once, on
    /// the next turn of the main run loop, however many changes that covers.
    func setNeedsNotify() {
        guard !notifyScheduled, !observers.isEmpty else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [self] in
            notifyScheduled = false
            observers.removeAll { $0.observer == nil }
            for entry in observers { entry.observer?.tabsDidChange() }
        }
    }
}
