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
    private var titlebarMouseMonitor: Any?
    private var titlebarHideTimer: Timer?
    private var isFullscreenTitlebarVisible = true
    private var hasRequestedInitialFullscreen = false
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
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
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
        installFullscreenTitlebarHandling()
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
        if let monitor = titlebarMouseMonitor { NSEvent.removeMonitor(monitor) }
        titlebarMouseMonitor = nil
        titlebarHideTimer?.invalidate()
        emulatorView.stop()
        emulator.shutdown()
    }

    @objc private func applySidebarSetting() {
        sidebar.isHidden = !Settings.isSidebarShown
    }

    private func installFullscreenTitlebarHandling() {
        titlebarMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  window.styleMask.contains(.fullScreen) else { return event }
            let top = window.contentView?.bounds.maxY ?? 0
            if event.locationInWindow.y >= top - 28 {
                self.showFullscreenTitlebar()
            } else {
                self.scheduleFullscreenTitlebarHide()
            }
            return event
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        window?.styleMask.insert(.fullSizeContentView)
        showFullscreenTitlebar()
        scheduleFullscreenTitlebarHide()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        showFullscreenTitlebar()
        titlebarHideTimer?.invalidate()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.styleMask.remove(.fullSizeContentView)
        showFullscreenTitlebar()
    }

    private func showFullscreenTitlebar() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        titlebarHideTimer?.invalidate()
        titlebarHideTimer = nil
        guard !isFullscreenTitlebarVisible else { return }
        isFullscreenTitlebarVisible = true
        window.titleVisibility = .visible
        window.toolbar?.isVisible = true
        for button in [window.standardWindowButton(.closeButton),
                       window.standardWindowButton(.miniaturizeButton),
                       window.standardWindowButton(.zoomButton)] {
            button?.isHidden = false
        }
    }

    private func scheduleFullscreenTitlebarHide() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        titlebarHideTimer?.invalidate()
        titlebarHideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideFullscreenTitlebar() }
        }
    }

    private func hideFullscreenTitlebar() {
        guard let window, window.styleMask.contains(.fullScreen), isFullscreenTitlebarVisible else { return }
        let top = window.contentView?.bounds.maxY ?? 0
        let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard mouse.y < top - 28 else {
            scheduleFullscreenTitlebarHide()
            return
        }
        isFullscreenTitlebarVisible = false
        window.titleVisibility = .hidden
        window.toolbar?.isVisible = false
        for button in [window.standardWindowButton(.closeButton),
                       window.standardWindowButton(.miniaturizeButton),
                       window.standardWindowButton(.zoomButton)] {
            button?.isHidden = true
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !hasRequestedInitialFullscreen, let window, !window.styleMask.contains(.fullScreen) else { return }
        hasRequestedInitialFullscreen = true
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

}
