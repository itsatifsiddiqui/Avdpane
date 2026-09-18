import AppKit

extension DeviceWindowController {
    private func encodeScreenshotPng() -> Data? {
        emulatorView.currentImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    @objc func saveScreenshot(_ sender: Any?) {
        guard let png = encodeScreenshotPng() else { return showHud("No frame yet") }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = URL(fileURLWithPath: Settings.screenshotFolder)
        let file = folder.appendingPathComponent("\(avd.name) \(formatter.string(from: Date())).png")
        do {
            try png.write(to: file)
            showHud("Saved to \(folder.lastPathComponent)")
        } catch { showHud(error.localizedDescription, isError: true) }
    }

    @objc func copyScreenshot(_ sender: Any?) {
        guard let png = encodeScreenshotPng() else { return showHud("No frame yet") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        showHud("Copied")
    }
}
