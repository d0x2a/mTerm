import AppKit
import UserNotifications

/// Thin wrapper over UserNotifications for posting "your terminal wants you"
/// banners and routing a click back to the tab that fired it.
///
/// UNUserNotificationCenter.current() raises if the process has no bundle
/// identifier — which is the case for `swift run` dev builds. Every entry point
/// guards on `isAvailable` so development runs simply no-op instead of crashing;
/// the signed .app bundle gets real notifications.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// userInfo key carrying the originating tab's UUID string.
    private static let tabIdKey = "mTerm.tabId"

    /// Notifications only work from a real app bundle (needs a bundle id).
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private var didRequestAuthorization = false

    private override init() { super.init() }

    /// Installs the delegate and asks for permission once. Call on launch.
    /// Safe to call when notifications are disabled in settings — we still want
    /// the delegate wired so a later enable doesn't need a relaunch, but we hold
    /// off on the system prompt until notifications are actually on.
    func configure() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        if ThemeStore.shared.settings.notificationsEnabled {
            requestAuthorizationIfNeeded()
        }
    }

    func requestAuthorizationIfNeeded() {
        guard isAvailable, !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a banner. `tabId` lets a click reselect the originating tab.
    func post(title: String, body: String, tabId: UUID) {
        guard isAvailable else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [Self.tabIdKey: tabId.uuidString]

        // nil trigger → deliver immediately. Fresh id each time so banners
        // stack rather than replace one another.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show the banner even when mTerm is the frontmost app (the user may be
    /// looking at a different tab/window than the one that fired it — the
    /// frontmost-tab suppression already happened upstream in
    /// MainWindowController).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// On click: activate mTerm and bring the originating tab forward.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let idString = response.notification.request.content.userInfo[Self.tabIdKey] as? String
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if let idString, let id = UUID(uuidString: idString) {
                for window in NSApp.windows {
                    guard let controller = window.windowController as? MainWindowController,
                          controller.tabs.contains(where: { $0.id == id }) else { continue }
                    window.makeKeyAndOrderFront(nil)
                    controller.selectTab(id)
                    break
                }
            }
            completionHandler()
        }
    }
}
