import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let enabledKey = "DarkMic.KeepLedOff"

    private var statusBar: StatusBarController?
    private var ledController: CorsairLedController?
    private var resyncTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let initialEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true

        // Prevent macOS App Nap from throttling HID callbacks while the display is asleep,
        // without blocking display sleep or idle system sleep.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Receive Corsair HS80 MAX mic mute HID notifications"
        )

        let controller = CorsairLedController(enabled: initialEnabled)
        let bar = StatusBarController(
            initialEnabled: initialEnabled,
            onToggleEnabled: { [weak controller] enabled in
                UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
                controller?.setEnabled(enabled)
            },
            onApplyNow: { [weak controller] in
                controller?.sync(force: true)
            }
        )

        controller.onStatusChange = { [weak bar, weak controller] status in
            bar?.update(status: status, isEnabled: controller?.isEnabled ?? true)
        }

        self.ledController = controller
        self.statusBar = bar

        // Lightweight 60s check (20s coalescing tolerance) to catch silent headset reconnects;
        // only writes LED frames if state changed or headset came back online.
        resyncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let controller = self?.ledController, controller.isEnabled else { return }
                controller.sync(force: false)
            }
        }
        resyncTimer?.tolerance = 20

        let wsCenter = NSWorkspace.shared.notificationCenter
        let events: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.screensDidSleepNotification
        ]
        observers = events.map { name in
            wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let controller = self?.ledController, controller.isEnabled else { return }
                    controller.sync(force: true)
                }
            }
        }

        controller.sync(force: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        resyncTimer?.invalidate()
        let wsCenter = NSWorkspace.shared.notificationCenter
        for observer in observers {
            wsCenter.removeObserver(observer)
        }
        observers.removeAll()
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        ledController?.stop()
    }
}
