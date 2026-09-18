import AppKit

// App settings stored in UserDefaults. Every value has a default so nothing needs setup.
enum Settings {
    private static var defaults: UserDefaults { .standard }
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var sdkPath: String {
        get {
            defaults.string(forKey: "sdkPath")
                ?? ProcessInfo.processInfo.environment["ANDROID_HOME"]
                ?? ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"]
                ?? home + "/Library/Android/sdk"
        }
        set { defaults.set(newValue.isEmpty ? nil : newValue, forKey: "sdkPath") }
    }

    static var isHeadlessDefault: Bool {
        get { defaults.object(forKey: "isHeadlessDefault") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "isHeadlessDefault") }
    }

    static var basePort: Int {
        get { defaults.object(forKey: "basePort") as? Int ?? 8554 }
        set { defaults.set(newValue, forKey: "basePort") }
    }

    static var extraEmulatorArgs: String {
        get { defaults.string(forKey: "extraEmulatorArgs") ?? "" }
        set { defaults.set(newValue, forKey: "extraEmulatorArgs") }
    }

    static var screenshotFolder: String {
        get { defaults.string(forKey: "screenshotFolder") ?? home + "/Desktop" }
        set { defaults.set(newValue.isEmpty ? nil : newValue, forKey: "screenshotFolder") }
    }

    static var isSidebarShown: Bool {
        get { defaults.bool(forKey: "isSidebarShown") }
        set { defaults.set(newValue, forKey: "isSidebarShown"); postAppearanceChange() }
    }

    static var isFpsPrinted: Bool {
        get { defaults.bool(forKey: "isFpsPrinted") }
        set { defaults.set(newValue, forKey: "isFpsPrinted") }
    }

    static var phonePadding: Int {
        get { defaults.object(forKey: "phonePadding") as? Int ?? 16 }
        set { defaults.set(newValue, forKey: "phonePadding"); postAppearanceChange() }
    }

    static var backgroundColorName: String {
        get { defaults.string(forKey: "backgroundColorName") ?? backgroundColorNames[0] }
        set { defaults.set(newValue, forKey: "backgroundColorName"); postAppearanceChange() }
    }

    static var cornerRadius: Int {
        get { defaults.object(forKey: "cornerRadius") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "cornerRadius"); postAppearanceChange() }
    }

    static var isClipboardSyncOn: Bool {
        get { defaults.object(forKey: "isClipboardSyncOn") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "isClipboardSyncOn") }
    }

    static var isReopenLastDevicesOn: Bool {
        get { defaults.object(forKey: "isReopenLastDevicesOn") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "isReopenLastDevicesOn") }
    }

    static var alwaysOnTopAvdIds: [String] {
        get { defaults.stringArray(forKey: "alwaysOnTopAvdIds") ?? [] }
        set { defaults.set(newValue, forKey: "alwaysOnTopAvdIds") }
    }

    static var lastOpenAvdIds: [String] {
        get { defaults.stringArray(forKey: "lastOpenAvdIds") ?? [] }
        set { defaults.set(newValue, forKey: "lastOpenAvdIds") }
    }

    static let backgroundColorNames = ["Black", "Dark Gray", "System Window"]

    static var backgroundColor: NSColor {
        switch backgroundColorName {
        case "Dark Gray": .darkGray
        case "System Window": .windowBackgroundColor
        default: .black
        }
    }

    static var emulatorBinary: String { sdkPath + "/emulator/emulator" }
    static var adbBinary: String { sdkPath + "/platform-tools/adb" }

    // Open device windows listen for this so a change in Settings shows right away.
    static func postAppearanceChange() {
        NotificationCenter.default.post(name: .appearanceDidChange, object: nil)
    }

    // Only the keys shown in the Settings window. Window frames, pinned and last open devices stay.
    static func resetToDefaults() {
        for key in ["sdkPath", "isHeadlessDefault", "basePort", "extraEmulatorArgs", "screenshotFolder",
                    "isSidebarShown", "isFpsPrinted", "phonePadding", "backgroundColorName", "cornerRadius"] {
            defaults.removeObject(forKey: key)
        }
        postAppearanceChange()
    }
}

extension Notification.Name {
    static let appearanceDidChange = Notification.Name("appearanceDidChange")
}
