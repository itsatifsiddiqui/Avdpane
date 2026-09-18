import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static let shared = AppDelegate()
    let startWindow = StartWindowController()
    var deviceWindows: [DeviceWindowController] = []
    // Where the next device window goes, so new windows step down and right instead of stacking.
    var cascadePoint = NSPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        startWindow.window?.setFrameAutosaveName("start")
        SettingsWindowController.shared.window?.setFrameAutosaveName("settings")
        showStartWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Lets scripts open a device right away: Avdpane --open <avd id>
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count,
           let avd = startWindow.avds.first(where: { $0.id == arguments[index + 1] }) {
            startWindow.open(avd: avd)
        }
        reopenLastDevices()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { confirmQuit() }

    func applicationWillTerminate(_ notification: Notification) { saveOpenDevices() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showStartWindow(nil)
        return false
    }

    @objc func showStartWindow(_ sender: Any?) {
        startWindow.showWindow(nil)
        startWindow.window?.makeKeyAndOrderFront(nil)
    }

    // Reuses the open window for this AVD, unless the emulator came back on another port.
    func openDeviceWindow(avd: Avd, port: Int) {
        if let existing = deviceWindows.first(where: { $0.avd.id == avd.id }) {
            if existing.port == port {
                existing.window?.makeKeyAndOrderFront(nil)
                return
            }
            existing.close()
        }
        let controller = DeviceWindowController(avd: avd, port: port)
        deviceWindows.append(controller)
        controller.showWindow(nil)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Avdpane", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Avdpane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(submenu: app, title: "Avdpane")

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: #selector(showStartWindow(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(.separator())
        file.addItem(withTitle: "Save Screenshot", action: #selector(DeviceWindowController.saveScreenshot(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Copy Screenshot", action: #selector(DeviceWindowController.copyScreenshot(_:)), keyEquivalent: "C")
        file.addItem(withTitle: "Install APK...", action: #selector(DeviceWindowController.installApk(_:)), keyEquivalent: "i")
        menu.addItem(submenu: file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Show Sidebar", action: #selector(DeviceWindowController.toggleSidebarShown(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Always on Top", action: #selector(DeviceWindowController.toggleAlwaysOnTop(_:)), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.command, .option]
        addWindowLayoutItems(to: view)
        menu.addItem(submenu: view, title: "View")

        let device = NSMenu(title: "Device")
        for control in [DeviceControl.back, .home, .recents] { device.addItem(control.makeMenuItem()) }
        device.addItem(.separator())
        for control in [DeviceControl.power, .volumeUp, .volumeDown, .rotate] { device.addItem(control.makeMenuItem()) }
        device.addItem(.separator())
        let extendedControls = DeviceControl.extendedControls.makeMenuItem()
        extendedControls.title = "Extended Controls..."
        device.addItem(extendedControls)
        device.addItem(.separator())
        device.addItem(withTitle: "Sync Clipboard", action: #selector(toggleClipboardSync(_:)), keyEquivalent: "")
        menu.addItem(submenu: device, title: "Device")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        menu.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window
        return menu
    }

    // Check marks come from the setting every time the menu opens, not only when toggled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleClipboardSync(_:)): menuItem.state = Settings.isClipboardSyncOn ? .on : .off
        case #selector(toggleReopenLastDevices(_:)): menuItem.state = Settings.isReopenLastDevicesOn ? .on : .off
        default: break
        }
        return true
    }
}

extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
