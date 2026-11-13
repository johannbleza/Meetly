#if DEBUG
import Foundation

/// Steps the overlay through scripted states so the notch can be screen-recorded and tuned.
///
/// Launch a Debug build with `-MeetlyNotchDemo YES`, then post a `johann.Meetly.debug.notch`
/// distributed notification whose object is a step name (see
/// `SessionManager.debugApplyNotchDemo`). Nothing touches audio, saved meetings or the AI tools.
@MainActor
final class NotchDemoDriver {
    static let shared = NotchDemoDriver()

    private var observer: NSObjectProtocol?

    private init() {}

    func startIfRequested(sessionManager: SessionManager) {
        guard observer == nil, UserDefaults.standard.bool(forKey: "MeetlyNotchDemo") else { return }
        sessionManager.isNotchDemoActive = true
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("johann.Meetly.debug.notch"),
            object: nil,
            queue: .main
        ) { [weak sessionManager] notification in
            let step = notification.object as? String ?? ""
            MainActor.assumeIsolated {
                sessionManager?.debugApplyNotchDemo(step)
            }
        }
    }
}
#endif
