# Avdpane

Avdpane shows Android emulators in native Mac windows. It talks to the emulator over its built in gRPC API. Each emulator gets its own window that you can move, resize, tile and put in Split View like any other Mac app.

## Requirements

- Apple Silicon Mac with macOS 15 or newer
- Android SDK with the emulator and platform-tools installed (Android Studio sets this up). The app uses the path from Settings, then `ANDROID_HOME` or `ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`.
- At least one AVD (virtual device) created in Android Studio


## Install

1. Download `Avdpane-vX.Y.Z.zip` from the [Releases](../../releases) page and unzip it.
2. Move `Avdpane.app` to your Applications folder.
3. The app is not notarized, so macOS will block it the first time. Either right-click the app and pick **Open** (do this twice), or run:

```sh
xattr -dr com.apple.quarantine "/Applications/Avdpane.app"
```

## Build from source

```sh
swift build -c release
./make-app.sh
```

## Run

1. Open the app.
2. Pick an AVD from the list.
3. Pick **Headless** (emulator runs with no window of its own) or **With emulator window**. The app remembers your choice.
4. Click **Open**.

The emulator starts and its screen shows up in a new window. The emulator keeps running after you quit the app, so you can open it again later without a cold boot.

## Features

- One window per emulator, open as many as you want
- Works with macOS Split View and full screen tiling
- Toolbar and side strip with Back, Home, Recents, Power, Volume Up, Volume Down, Rotate, Screenshot and Extended Controls
- Two finger scroll and the mouse wheel scroll the phone screen
- Clipboard sync in both directions (Device menu, Sync Clipboard), Cmd + V pastes long text
- Drag an APK file onto the window to install it
- Save a screenshot to a folder or copy it to the clipboard
- Settings for the SDK path, first gRPC port, extra emulator arguments, screenshot folder, sidebar, phone padding, background color, corner radius and printing frames per second to the console

## Keyboard shortcuts

| Shortcut | What it does |
| --- | --- |
| Cmd + N | New window (shows the AVD list) |
| Cmd + W | Close the window |
| Cmd + S | Save a screenshot to the screenshot folder |
| Cmd + Shift + C | Copy a screenshot to the clipboard |
| Cmd + I | Install an APK (file picker) |
| Cmd + V | Paste the Mac clipboard into the phone |
| Cmd + M | Minimize |
| Cmd + , | Settings |
| Cmd + Q | Quit |
| Cmd + Option + S | Show or hide the sidebar |
| Cmd + Option + T | Keep the window always on top |
| Cmd + 1 | Actual size |
| Cmd + 2 | Half size |
| Cmd + 3 | Fit to screen |
| Cmd + B | Back |
| Cmd + Shift + H | Home |
| Cmd + Shift + R | Recents |
| Cmd + P | Power |
| Cmd + Up Arrow | Volume up |
| Cmd + Down Arrow | Volume down |
| Cmd + R | Rotate |
| Cmd + E | Extended controls (the emulator's own settings window) |

## Menus

- **Device > Sync Clipboard**: text copied on the Mac shows up on the phone and the other way round.
- **View > Reopen Last Devices at Launch**: devices that were open when you quit come back at the next launch, if their emulator is still running.
## License

MIT, see [LICENSE](LICENSE).
