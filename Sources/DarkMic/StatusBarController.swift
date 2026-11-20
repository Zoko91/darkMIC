import AppKit

final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let onToggleEnabled: (Bool) -> Void
    private let onApplyNow: () -> Void

    private var status: HeadsetStatus = .receiverDisconnected
    private var isEnabled: Bool

    private let iconOff: NSImage?
    private let iconOn: NSImage?

    private static let launchAgentLabel = "com.darkmic.app"
    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    init(
        initialEnabled: Bool,
        onToggleEnabled: @escaping (Bool) -> Void,
        onApplyNow: @escaping () -> Void
    ) {
        self.isEnabled = initialEnabled
        self.onToggleEnabled = onToggleEnabled
        self.onApplyNow = onApplyNow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        let offImg = NSImage(systemSymbolName: "mic.slash", accessibilityDescription: "DarkMic Active")?
            .withSymbolConfiguration(config)
        offImg?.isTemplate = true
        self.iconOff = offImg

        let onImg = NSImage(systemSymbolName: "mic", accessibilityDescription: "DarkMic Paused")?
            .withSymbolConfiguration(config)
        onImg?.isTemplate = true
        self.iconOn = onImg

        super.init()

        self.menu.delegate = self
        self.statusItem.menu = menu
        renderIcon()
    }

    func update(status: HeadsetStatus, isEnabled: Bool) {
        self.status = status
        self.isEnabled = isEnabled
        renderIcon()
    }

    private func renderIcon() {
        let isOnline = status == .liveLedOff || status == .mutedRedLed || status == .hardwareMode
        statusItem.isVisible = isOnline
        guard isOnline, let button = statusItem.button else { return }
        button.image = isEnabled ? iconOff : iconOn
        button.alphaValue = 1.0
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusText: String = switch status {
        case .receiverDisconnected: "HS80 MAX — Receiver Not Found"
        case .headsetOffline: "HS80 MAX — Offline"
        case .liveLedOff: "HS80 MAX — Live (LED Off)"
        case .mutedRedLed: "HS80 MAX — Muted (Red LED)"
        case .hardwareMode: "HS80 MAX — Hardware Mode"
        }

        let statusLine = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: "Block Live Mic LED",
            action: #selector(handleToggleEnabled),
            keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.state = isEnabled ? .on : .off
        menu.addItem(toggleItem)

        let applyItem = NSMenuItem(
            title: "Sync Now",
            action: #selector(handleApplyNow),
            keyEquivalent: "r"
        )
        applyItem.target = self
        menu.addItem(applyItem)

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit DarkMic",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private var isLaunchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: Self.launchAgentURL.path)
    }

    @objc private func handleToggleEnabled() {
        isEnabled.toggle()
        onToggleEnabled(isEnabled)
        renderIcon()
    }

    @objc private func handleApplyNow() {
        onApplyNow()
    }

    @objc private func toggleLaunchAtLogin() {
        let fm = FileManager.default
        let url = Self.launchAgentURL

        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        } else {
            let executablePath = Bundle.main.executablePath
                ?? "/Applications/DarkMic.app/Contents/MacOS/DarkMic"
            let plist: [String: Any] = [
                "Label": Self.launchAgentLabel,
                "ProgramArguments": [executablePath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "LimitLoadToSessionType": "Aqua"
            ]
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}
