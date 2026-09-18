import AppKit

extension DeviceWindowController {
    // Opens the emulator's own settings window: location, cellular, battery, camera and more.
    @objc func showExtendedControls(_ sender: Any?) {
        guard let window, let running = AvdCatalog.runningEmulators()[avd.id], running.grpcPort != nil else {
            return showHud("Emulator is still starting, try again in a moment")
        }
        guard running.hasUi else {
            let alert = NSAlert()
            alert.messageText = "Extended controls need the emulator window"
            alert.informativeText = "This emulator was started with -no-window, so it has no settings window. Stop it and open it again from Avdpane."
            return alert.beginSheetModal(for: window)
        }
        Task {
            do { try await emulator.showExtendedControls() }
            catch {
                let alert = NSAlert()
                alert.messageText = "Could not open extended controls"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
