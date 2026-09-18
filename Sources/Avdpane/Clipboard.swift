import AppKit

extension EmulatorView {
    // Long text goes through the clipboard, the key buffer overruns past 1 kb.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        emulator.setClipboard(text)
        emulator.sendKey(name: "Paste")
    }
}

extension AppDelegate {
    @objc func toggleClipboardSync(_ sender: Any?) {
        Settings.isClipboardSyncOn.toggle()
        for device in deviceWindows {
            Settings.isClipboardSyncOn ? device.startClipboardSync() : device.stopClipboardSync()
        }
    }
}

extension DeviceWindowController {
    func startClipboardSync() {
        guard Settings.isClipboardSyncOn else { return }
        clipboardStream?.cancel()
        clipboardStream = Task { [emulator] in
            while !Task.isCancelled {
                do {
                    try await emulator.streamClipboard { text in
                        Task { @MainActor in self.receive(text) }
                    }
                } catch { print("clipboard stream ended: \(error)") }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if window?.isKeyWindow == true { startPasteboardWatch() }
    }

    func stopClipboardSync() {
        clipboardStream?.cancel()
        clipboardStream = nil
        pasteboardTimer?.invalidate()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard Settings.isClipboardSyncOn else { return }
        startPasteboardWatch()
    }

    func windowDidResignKey(_ notification: Notification) {
        pasteboardTimer?.invalidate()
    }

    private func startPasteboardWatch() {
        pushPasteboard()
        pasteboardTimer?.invalidate()
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NSPasteboard.general.changeCount != self.pasteboardChangeCount else { return }
                self.pushPasteboard()
            }
        }
    }

    private func pushPasteboard() {
        pasteboardChangeCount = NSPasteboard.general.changeCount
        guard let text = NSPasteboard.general.string(forType: .string), text != lastSyncedText else { return }
        lastSyncedText = text
        emulator.setClipboard(text)
    }

    private func receive(_ text: String) {
        guard !text.isEmpty, text != lastSyncedText else { return }
        lastSyncedText = text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pasteboardChangeCount = NSPasteboard.general.changeCount
    }
}
