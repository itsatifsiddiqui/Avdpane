import AppKit

// One entry per phone button, shared by the toolbar, the sidebar and the Device menu.
struct DeviceControl {
    let title: String
    let symbol: String
    let action: Selector
    let keyEquivalent: String

    static let back = DeviceControl(title: "Back", symbol: "arrow.backward", action: #selector(DeviceWindowController.goBack(_:)), keyEquivalent: "b")
    static let home = DeviceControl(title: "Home", symbol: "house", action: #selector(DeviceWindowController.goHome(_:)), keyEquivalent: "H")
    static let recents = DeviceControl(title: "Recents", symbol: "square.on.square", action: #selector(DeviceWindowController.showRecents(_:)), keyEquivalent: "R")
    static let power = DeviceControl(title: "Power", symbol: "power", action: #selector(DeviceWindowController.pressPower(_:)), keyEquivalent: "p")
    static let volumeUp = DeviceControl(title: "Volume Up", symbol: "speaker.plus", action: #selector(DeviceWindowController.volumeUp(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
    static let volumeDown = DeviceControl(title: "Volume Down", symbol: "speaker.minus", action: #selector(DeviceWindowController.volumeDown(_:)), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
    static let rotate = DeviceControl(title: "Rotate", symbol: "rotate.right", action: #selector(DeviceWindowController.rotate(_:)), keyEquivalent: "r")
    static let screenshot = DeviceControl(title: "Screenshot", symbol: "camera", action: #selector(DeviceWindowController.saveScreenshot(_:)), keyEquivalent: "")
    static let extendedControls = DeviceControl(title: "Extended Controls", symbol: "slider.horizontal.3", action: #selector(DeviceWindowController.showExtendedControls(_:)), keyEquivalent: "e")
    static let sidebar = DeviceControl(title: "Sidebar", symbol: "sidebar.right", action: #selector(DeviceWindowController.toggleSidebarShown(_:)), keyEquivalent: "")

    static let toolbarControls: [DeviceControl] = [back, home, recents, power, volumeUp, volumeDown, rotate, screenshot, extendedControls]
    static let sidebarControls: [DeviceControl] = [power, volumeUp, volumeDown, rotate, screenshot, extendedControls, back, home, recents]

    // A misspelled symbol shows a question mark instead of crashing at launch.
    var image: NSImage {
        NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: title) ?? NSImage()
    }
    var identifier: NSToolbarItem.Identifier { .init(title) }

    // Target stays nil so the frontmost device window handles it.
    @MainActor func makeMenuItem() -> NSMenuItem { NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent) }
}

extension DeviceWindowController: NSToolbarDelegate {
    func installControls() {
        let toolbar = NSToolbar(identifier: "device")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unifiedCompact

        let buttons = DeviceControl.sidebarControls.map { control in
            let button = NSButton(image: control.image, target: self, action: control.action)
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.toolTip = control.title
            button.widthAnchor.constraint(equalToConstant: 40).isActive = true
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
            return button
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            stack.centerXAnchor.constraint(equalTo: sidebar.centerXAnchor),
        ])
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        DeviceControl.toolbarControls.map(\.identifier) + [.flexibleSpace, DeviceControl.sidebar.identifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let control = (DeviceControl.toolbarControls + [DeviceControl.sidebar]).first(where: { $0.identifier == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = control.title
        item.toolTip = control.title
        item.image = control.image
        item.target = self
        item.action = control.action
        return item
    }

    @objc func goBack(_ sender: Any?) { emulator.sendKey(name: "GoBack") }
    @objc func goHome(_ sender: Any?) { emulator.sendKey(name: "GoHome") }
    @objc func showRecents(_ sender: Any?) { emulator.sendKey(name: "AppSwitch") }
    @objc func pressPower(_ sender: Any?) { emulator.sendKey(name: "Power") }
    @objc func volumeUp(_ sender: Any?) { sendAdbKey("KEYCODE_VOLUME_UP") }
    @objc func volumeDown(_ sender: Any?) { sendAdbKey("KEYCODE_VOLUME_DOWN") }
    @objc func rotate(_ sender: Any?) { emulator.rotate() }

    // Not named toggleSidebar, NSWindow answers that selector first and swallows the menu action.
    @objc func toggleSidebarShown(_ sender: Any?) {
        Settings.isSidebarShown.toggle()
    }

    // The phone ignores the gRPC "AudioVolumeUp" key name, so volume goes through adb.
    private func sendAdbKey(_ keycode: String) {
        guard let serial = adbSerial else { return }
        Task {
            let result = await Task.detached { AvdCatalog.adb(["-s", serial, "shell", "input", "keyevent", keycode]) }.value
            if result.status != 0 { showHud(result.output, isError: true) }
        }
    }
}
