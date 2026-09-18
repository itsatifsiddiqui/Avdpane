import AppKit

extension DeviceWindowController {
    // Room the content area needs around the phone: padding on every side plus the sidebar when shown.
    private var extraSize: NSSize {
        let padding = CGFloat(Settings.phonePadding) * 2
        return NSSize(width: padding + (sidebar.isHidden ? 0 : sidebar.fittingSize.width), height: padding)
    }

    // Sizes the content so the phone shows at this scale, keeping the top left corner in place.
    private func resize(scale: CGFloat) {
        guard let window, emulatorView.deviceWidth > 0 else { return showHud("No frame yet") }
        let content = NSSize(width: CGFloat(emulatorView.deviceWidth) * scale + extraSize.width,
                             height: CGFloat(emulatorView.deviceHeight) * scale + extraSize.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        // Slide back onto the screen. If it still does not fit, the left edge and title bar win.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = max(min(frame.minX, visible.maxX - frame.width), visible.minX)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: true)
    }

    @objc func actualSize(_ sender: Any?) {
        resize(scale: 1 / (window?.backingScaleFactor ?? 1))
    }

    @objc func halfSize(_ sender: Any?) {
        resize(scale: 0.5 / (window?.backingScaleFactor ?? 1))
    }

    @objc func fitToScreen(_ sender: Any?) {
        guard let window, let screen = window.screen ?? NSScreen.main, emulatorView.deviceWidth > 0 else { return }
        let room = window.contentRect(forFrameRect: screen.visibleFrame).size
        resize(scale: min((room.width - extraSize.width) / CGFloat(emulatorView.deviceWidth),
                          (room.height - extraSize.height) / CGFloat(emulatorView.deviceHeight)))
    }
}

extension AppDelegate {
    func addWindowLayoutItems(to view: NSMenu) {
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(DeviceWindowController.actualSize(_:)), keyEquivalent: "1")
        view.addItem(withTitle: "Half Size", action: #selector(DeviceWindowController.halfSize(_:)), keyEquivalent: "2")
        view.addItem(withTitle: "Fit to Screen", action: #selector(DeviceWindowController.fitToScreen(_:)), keyEquivalent: "3")
        view.addItem(.separator())
        view.addItem(withTitle: "Reopen Last Devices at Launch", action: #selector(toggleReopenLastDevices(_:)), keyEquivalent: "")
    }

    @objc func toggleReopenLastDevices(_ sender: Any?) {
        Settings.isReopenLastDevicesOn.toggle()
    }

    // Only devices that are already running with gRPC come back. Stopped ones stay stopped.
    func reopenLastDevices() {
        guard Settings.isReopenLastDevicesOn else { return }
        for avd in startWindow.avds where Settings.lastOpenAvdIds.contains(avd.id) {
            guard let running = avd.running, running.hasGrpcEnabled, let port = running.grpcPort else { continue }
            openDeviceWindow(avd: avd, port: port)
        }
    }

    func saveOpenDevices() {
        Settings.lastOpenAvdIds = deviceWindows.map(\.avd.id)
    }

    // Only headless emulators shown in this app are offered. Windowed ones and other apps' emulators stay.
    func confirmQuit() -> NSApplication.TerminateReply {
        let ids = deviceWindows.map(\.avd.id)
        let headless = AvdCatalog.runningEmulators().filter { ids.contains($0.key) && $0.value.isHeadless }.values
        guard !headless.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Emulators are still running in the background."
        alert.addButton(withTitle: "Quit and Keep Running")
        alert.addButton(withTitle: "Stop Emulators and Quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .terminateNow
        case .alertSecondButtonReturn:
            for running in headless { AvdCatalog.stop(running) }
            return .terminateNow
        default: return .terminateCancel
        }
    }
}
