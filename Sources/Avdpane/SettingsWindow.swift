import AppKit

extension AppDelegate {
    @objc func showSettings() {
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }
}

// Every control saves to Settings as soon as it changes, so there is no Save button.
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    private let sdkField = NSTextField()
    private let sdkStatusLabel = NSTextField(labelWithString: "")
    private let portField = NSTextField()
    private let argsField = NSTextField()
    private let screenshotField = NSTextField()
    private let sidebarCheckbox = NSButton(checkboxWithTitle: "Show sidebar in device windows", target: nil, action: #selector(sidebarChanged(_:)))
    private let fpsCheckbox = NSButton(checkboxWithTitle: "Print frames per second to the console", target: nil, action: #selector(fpsChanged(_:)))
    private let paddingSlider = NSSlider()
    private let paddingField = NSTextField()
    private let backgroundPopup = NSPopUpButton()
    private let radiusSlider = NSSlider()
    private let radiusField = NSTextField()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Settings"
        window.isReleasedWhenClosed = false

        for field in [sdkField, portField, argsField, screenshotField] { field.delegate = self }
        sdkStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let portFormatter = NumberFormatter()
        portFormatter.minimum = 1024
        portFormatter.maximum = 65535
        portFormatter.allowsFloats = false
        portField.formatter = portFormatter
        portField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let portHint = NSTextField(labelWithString: "Each emulator uses the next free even port")
        portHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        portHint.textColor = .secondaryLabelColor
        argsField.placeholderString = "-gpu host -no-snapshot"
        sidebarCheckbox.target = self
        fpsCheckbox.target = self
        let appearanceHeader = makeLabel("Appearance")
        appearanceHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        backgroundPopup.addItems(withTitles: Settings.backgroundColorNames)
        backgroundPopup.target = self
        backgroundPopup.action = #selector(backgroundChanged(_:))
        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults(_:)))

        let grid = NSGridView(views: [
            [makeLabel("Android SDK path:"), makePathRow(sdkField, action: #selector(chooseSdk(_:)))],
            [NSGridCell.emptyContentView, sdkStatusLabel],
            [makeLabel("First gRPC port:"), portField],
            [NSGridCell.emptyContentView, portHint],
            [makeLabel("Extra emulator arguments:"), argsField],
            [makeLabel("Screenshot folder:"), makePathRow(screenshotField, action: #selector(chooseScreenshotFolder(_:)))],
            [NSGridCell.emptyContentView, sidebarCheckbox],
            [NSGridCell.emptyContentView, fpsCheckbox],
            [NSGridCell.emptyContentView, appearanceHeader],
            [makeLabel("Phone padding:"), makeSliderRow(paddingSlider, paddingField, max: 256)],
            [makeLabel("Background:"), backgroundPopup],
            [makeLabel("Corner radius:"), makeSliderRow(radiusSlider, radiusField, max: 64)],
            [NSGridCell.emptyContentView, resetButton],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.cell(for: portField)!.xPlacement = .leading
        grid.cell(for: backgroundPopup)!.xPlacement = .leading
        grid.cell(for: resetButton)!.xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        window.contentView = content
        window.setContentSize(NSSize(width: 480, height: grid.fittingSize.height + 40))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeLabel(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func makePathRow(_ field: NSTextField, action: Selector) -> NSStackView {
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [field, NSButton(title: "Choose...", target: self, action: action)])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // Slider and number field share one action, so whichever one moves, the other follows.
    private func makeSliderRow(_ slider: NSSlider, _ field: NSTextField, max: Int) -> NSStackView {
        slider.maxValue = Double(max)
        slider.target = self
        slider.action = #selector(appearanceChanged(_:))
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximum = max as NSNumber
        formatter.allowsFloats = false
        field.formatter = formatter
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let row = NSStackView(views: [slider, field])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func load() {
        sdkField.stringValue = Settings.sdkPath
        portField.integerValue = Settings.basePort
        argsField.stringValue = Settings.extraEmulatorArgs
        screenshotField.stringValue = Settings.screenshotFolder
        sidebarCheckbox.state = Settings.isSidebarShown ? .on : .off
        fpsCheckbox.state = Settings.isFpsPrinted ? .on : .off
        backgroundPopup.selectItem(withTitle: Settings.backgroundColorName)
        showAppearanceValues()
        updateSdkStatus()
    }

    private func showAppearanceValues() {
        paddingSlider.integerValue = Settings.phonePadding
        paddingField.integerValue = Settings.phonePadding
        radiusSlider.integerValue = Settings.cornerRadius
        radiusField.integerValue = Settings.cornerRadius
    }

    private func updateSdkStatus() {
        let files = FileManager.default
        let isFound = files.fileExists(atPath: Settings.emulatorBinary) && files.fileExists(atPath: Settings.adbBinary)
        sdkStatusLabel.stringValue = isFound ? "Found emulator and adb" : "emulator not found at \(Settings.sdkPath)"
        sdkStatusLabel.textColor = isFound ? .systemGreen : .systemRed
    }

    private func chooseFolder(into field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: field.stringValue)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        field.stringValue = url.path
        save(field)
    }

    private func save(_ field: NSTextField) {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.stringValue = text
        switch field {
        case sdkField:
            Settings.sdkPath = text
            field.stringValue = Settings.sdkPath
            updateSdkStatus()
        case argsField: Settings.extraEmulatorArgs = text
        case screenshotField:
            Settings.screenshotFolder = text
            field.stringValue = Settings.screenshotFolder
        case portField:
            if let port = (field.objectValue as? NSNumber)?.intValue { Settings.basePort = port }
            field.integerValue = Settings.basePort
        case paddingField, radiusField: appearanceChanged(field)
        default: break
        }
    }

    @objc private func chooseSdk(_ sender: Any?) { chooseFolder(into: sdkField) }

    @objc private func chooseScreenshotFolder(_ sender: Any?) { chooseFolder(into: screenshotField) }

    @objc private func sidebarChanged(_ sender: Any?) {
        Settings.isSidebarShown = sidebarCheckbox.state == .on
    }

    @objc private func fpsChanged(_ sender: Any?) {
        Settings.isFpsPrinted = fpsCheckbox.state == .on
    }

    @objc private func resetToDefaults(_ sender: Any?) {
        Settings.resetToDefaults()
        load()
    }

    @objc private func backgroundChanged(_ sender: Any?) {
        Settings.backgroundColorName = backgroundPopup.titleOfSelectedItem ?? Settings.backgroundColorNames[0]
    }

    // A failed format leaves objectValue empty, then the stored value goes back into the controls.
    @objc private func appearanceChanged(_ sender: NSControl) {
        if let value = (sender.objectValue as? NSNumber)?.intValue {
            if sender === paddingSlider || sender === paddingField { Settings.phonePadding = value } else { Settings.cornerRadius = value }
        }
        showAppearanceValues()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    // A device window may have toggled the sidebar since the last time, so read everything again.
    override func showWindow(_ sender: Any?) {
        load()
        super.showWindow(sender)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { save(field) }
    }

    // Lets editing end on a bad port instead of beeping; save() then puts the stored port back.
    func control(_ control: NSControl, didFailToFormatString string: String, errorDescription error: String?) -> Bool { true }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        close()
        return true
    }
}
