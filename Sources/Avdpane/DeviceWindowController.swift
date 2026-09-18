import AppKit

// One window per emulator. Shows the screen and, when enabled, a sidebar for controls.
@MainActor
final class DeviceWindowController: NSWindowController, NSWindowDelegate {
    let avd: Avd
    let port: Int
    let emulator: Emulator
    let emulatorView: EmulatorView
    let sidebar = NSView()
    let dropOverlay = ApkDropOverlay()
    var clipboardStream: Task<Void, Never>?
    var pasteboardTimer: Timer?
    var pasteboardChangeCount = 0
    // Last text that crossed in either direction, so it does not bounce back.
    var lastSyncedText: String?
    var adbSerial: String? { AvdCatalog.runningEmulators()[avd.id]?.adbSerial }

    init(avd: Avd, port: Int) {
        self.avd = avd
        self.port = port
        emulator = Emulator(port: port)
        emulatorView = EmulatorView(emulator: emulator, port: port)
        // 600 keeps all toolbar items next to the title. The view letterboxes, so the phone stays centered.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.title = avd.name
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        // No aspect lock on the window, the view letterboxes, so Split View can make it any shape.
        window.minSize = NSSize(width: 200, height: 300)
        window.backgroundColor = .black
        window.delegate = self

        sidebar.widthAnchor.constraint(equalToConstant: 56).isActive = true
        sidebar.isHidden = !Settings.isSidebarShown
        NotificationCenter.default.addObserver(self, selector: #selector(applySidebarSetting), name: .appearanceDidChange, object: nil)
        let stack = NSStackView(views: [emulatorView, sidebar])
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.detachesHiddenViews = true
        window.contentView = stack
        window.center()
        AppDelegate.shared.cascadePoint = window.cascadeTopLeft(from: AppDelegate.shared.cascadePoint)
        window.makeFirstResponder(emulatorView)

        installControls()
        installApkDrop()
        applyAlwaysOnTop()
        startClipboardSync()
        window.setFrameAutosaveName("device-\(avd.id)")
    }

    required init?(coder: NSCoder) { fatalError() }

    // A headless emulator has no other window, so ask before leaving it running unseen.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let running = AvdCatalog.runningEmulators()[avd.id], running.isHeadless else { return true }
        let alert = NSAlert()
        alert.messageText = "Stop \(avd.name)?"
        alert.informativeText = "The emulator runs without its own window. You can keep it running and open it again later."
        alert.addButton(withTitle: "Stop Emulator")
        alert.addButton(withTitle: "Keep Running in Background")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { response in
            switch response {
            case .alertFirstButtonReturn:
                Task.detached { AvdCatalog.stop(running) }
                sender.close()
            case .alertSecondButtonReturn:
                sender.close()
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared.deviceWindows.removeAll { $0 === self }
        stopClipboardSync()
        emulatorView.stop()
        emulator.shutdown()
    }

    @objc private func applySidebarSetting() {
        sidebar.isHidden = !Settings.isSidebarShown
    }
}
