import AppKit

extension EmulatorView {
    // Two finger scroll and the mouse wheel drag the screen the way a finger would.
    override func scrollWheel(with event: NSEvent) {
        guard deviceWidth > 0, !event.phase.contains(.mayBegin) else { return }
        scrollReleaseTask?.cancel()
        if scrollFinger == nil {
            guard event.phase.isDisjoint(with: [.ended, .cancelled]),
                  let start = devicePoint(for: convert(event.locationInWindow, from: nil)) else { return }
            scrollFinger = CGPoint(x: start.x, y: start.y)
            emulator.sendTouch(x: start.x, y: start.y, isDown: true)
        }
        // A wheel notch has no size, so count it as 20 points.
        let pixelsPerPoint = CGFloat(deviceWidth) / phoneRect.width
        let step = pixelsPerPoint * (event.hasPreciseScrollingDeltas ? 1 : 20)
        // AppKit already flips the deltas for natural scrolling, so the finger just follows them.
        var finger = scrollFinger!
        finger.x = min(max(finger.x + event.scrollingDeltaX * step, 0), CGFloat(deviceWidth - 1))
        finger.y = min(max(finger.y + event.scrollingDeltaY * step, 0), CGFloat(deviceHeight - 1))
        scrollFinger = finger
        emulator.sendTouch(x: Int(finger.x), y: Int(finger.y), isDown: true)

        if !event.momentumPhase.isDisjoint(with: [.ended, .cancelled]) { return releaseScrollFinger() }
        // ponytail: 150 ms of silence ends the drag. A mouse wheel sends no end event, and a
        // trackpad end may be followed by momentum, so both wait this long before lifting.
        scrollReleaseTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { releaseScrollFinger() }
        }
    }

    private func releaseScrollFinger() {
        guard let finger = scrollFinger else { return }
        scrollFinger = nil
        emulator.sendTouch(x: Int(finger.x), y: Int(finger.y), isDown: false)
    }
}

extension DeviceWindowController: NSMenuItemValidation {
    var isAlwaysOnTop: Bool { window?.level == .floating }

    func applyAlwaysOnTop() {
        window?.level = Settings.alwaysOnTopAvdIds.contains(avd.id) ? .floating : .normal
    }

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        var ids = Settings.alwaysOnTopAvdIds
        if isAlwaysOnTop { ids.removeAll { $0 == avd.id } } else { ids.append(avd.id) }
        Settings.alwaysOnTopAvdIds = ids
        applyAlwaysOnTop()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAlwaysOnTop(_:)) { menuItem.state = isAlwaysOnTop ? .on : .off }
        return true
    }
}
