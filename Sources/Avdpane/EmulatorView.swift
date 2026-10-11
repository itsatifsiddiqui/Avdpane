import AppKit

// Draws emulator frames into the layer and turns mouse and key events into emulator input.
@MainActor
final class EmulatorView: NSView {
    let emulator: Emulator
    private let port: Int
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let frameLayer = CALayer()
    private(set) var deviceWidth = 0
    private(set) var deviceHeight = 0
    private var frameCount = 0
    private var isTouching = false
    private var touchUsesAdb = false
    var hasActiveMouseTouch: Bool { isTouching }
    private var fpsTimer: Timer?
    private var streamTask: Task<Void, Never>?
    private var cameraMonitorTask: Task<Void, Never>?
    private var isCameraInUse = false
    private var isCameraRecording = false
    // Frames carry the attempt they came from, so a late one cannot show after that attempt ended.
    private var streamGeneration = 0
    private(set) var currentImage: CGImage?
    // Scroll wheel drag in device pixels, nil while no finger is down.
    var scrollFinger: CGPoint?
    var scrollReleaseTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    init(emulator: Emulator, port: Int) {
        self.emulator = emulator
        self.port = port
        super.init(frame: .zero)
        wantsLayer = true
        // The frame lives on its own layer sized to the fitted rect, so corners can be rounded.
        frameLayer.contentsGravity = .resize
        frameLayer.masksToBounds = true
        // No implicit animations, or every frame would crossfade and every resize would lag.
        frameLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
        layer?.addSublayer(frameLayer)
        applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(applyAppearance), name: .appearanceDidChange, object: nil)

        errorLabel.stringValue = "Waiting for emulator on port \(port)..."
        errorLabel.textColor = .white
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])

        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.printFps() }
        }
        cameraMonitorTask = Task { await monitorCameraUse() }
        streamTask = Task { await streamForever() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() { applyAppearance() }

    // Keeps retrying so the window survives the emulator being killed and restarted.
    private func streamForever() async {
        while !Task.isCancelled {
            streamGeneration += 1
            let generation = streamGeneration
            do {
                try await emulator.streamFrames { image in
                    Task { @MainActor in
                        if generation == self.streamGeneration { self.show(image) }
                    }
                } frameInterval: { [weak self] in
                    await MainActor.run {
                        guard let self, self.isCameraRecording else { return .milliseconds(66) }
                        return .milliseconds(200)
                    }
                }
            } catch {
                print("stream on port \(port) ended: \(error)")
                // streamFrames normally shuts down the failed transport itself. This second
                // call also covers failures while creating the transport and makes the retry
                // boundary explicit: no input or screenshot RPC is allowed to reuse a dead
                // connection after a deadlineExceeded/unavailable error.
                emulator.stopDisplayStream()
            }
            streamGeneration += 1
            let isRunning = AvdCatalog.runningEmulators().values.contains { $0.grpcPort == port }
            if isRunning {
                // Back/Home intentionally closes the old display connection before sending
                // the key, and the replacement stream takes a short moment to connect. Keep
                // the last frame visible during that handoff instead of flashing the window
                // black. `show(_:)` hides this label as soon as the first fresh frame arrives.
                errorLabel.isHidden = true
            } else {
                frameLayer.contents = nil
                currentImage = nil
                errorLabel.stringValue = "Emulator stopped"
                errorLabel.isHidden = false
            }
            // A failed screenshot is transient around Camera2 Activity transitions. Keep the
            // retry fast so Back/Home does not look like it froze the emulator for two seconds.
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // Camera opens before recording starts. Polling the camera service lets the
    // display stream slow down for the encoder-sensitive RECORD state.
    private func monitorCameraUse() async {
        while !Task.isCancelled {
            let serial = AvdCatalog.runningEmulators().values.first { $0.grpcPort == port }?.adbSerial
            let state: AvdCatalog.CameraState? = await Task.detached {
                guard let serial else { return nil }
                return AvdCatalog.cameraState(serial: serial)
            }.value
            guard let state else {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            let inUse = state.isInUse
            let recording = state.isRecording
            if inUse != isCameraInUse || recording != isCameraRecording {
                if isCameraRecording && !recording, let serial {
                    Task.detached {
                        AvdCatalog.normalizeLatestCameraVideo(serial: serial)
                    }
                }
                isCameraInUse = inUse
                isCameraRecording = recording
                if recording {
                    print("camera recording: throttling live screenshots")
                } else if inUse {
                    print("camera preview: using gRPC display stream")
                } else {
                    print("camera closed: using gRPC display stream")
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func show(_ image: CGImage) {
        // Rotation changes the frame size, so take it from every frame.
        if image.width != deviceWidth || image.height != deviceHeight { needsLayout = true }
        deviceWidth = image.width
        deviceHeight = image.height
        currentImage = image
        errorLabel.isHidden = true
        frameLayer.contents = image
        frameCount += 1
    }

    private func printFps() {
        guard Settings.isFpsPrinted, frameCount > 0 else { return }
        print("fps: \(frameCount)")
        frameCount = 0
    }

    // Where the phone actually shows inside the view after aspect fit and padding, in view points.
    var phoneRect: CGRect {
        // Padding never takes more than a quarter of the shorter side, so the phone always has room.
        let padding = min(CGFloat(Settings.phonePadding), min(bounds.width, bounds.height) / 4)
        let area = bounds.insetBy(dx: padding, dy: padding)
        guard deviceWidth > 0 else { return .zero }
        let scale = min(area.width / CGFloat(deviceWidth), area.height / CGFloat(deviceHeight))
        let size = CGSize(width: CGFloat(deviceWidth) * scale, height: CGFloat(deviceHeight) * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        frameLayer.frame = phoneRect
    }

    // Pixel on the phone under a view point, nil when the point is outside the phone.
    func devicePoint(for viewPoint: NSPoint) -> (x: Int, y: Int)? {
        let rect = phoneRect
        let fractionX = (viewPoint.x - rect.minX) / rect.width
        let fractionY = (rect.maxY - viewPoint.y) / rect.height
        guard (0...1).contains(fractionX), (0...1).contains(fractionY) else { return nil }
        return (Int(fractionX * CGFloat(deviceWidth - 1)), Int(fractionY * CGFloat(deviceHeight - 1)))
    }

    private func sendTouch(_ event: NSEvent, isDown: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = phoneRect
        // Drags and the release may leave the phone rect, so clamp instead of dropping them.
        let clamped = NSPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
        guard let device = devicePoint(for: clamped) else { return }

        // Camera2/QR activities may accept the display gRPC connection while silently
        // dropping its touch stream. Send raw coordinates through adb for the whole
        // camera session. This view never classifies coordinates as navigation keys or
        // camera controls; Android itself decides which window receives the touch.
        emulator.sendTouch(x: device.x, y: device.y, isDown: isDown, preferAdb: touchUsesAdb)
    }

    override func mouseDown(with event: NSEvent) {
        guard phoneRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        isTouching = true
        touchUsesAdb = isCameraInUse
        sendTouch(event, isDown: true)
    }

    override func mouseDragged(with event: NSEvent) {
        if isTouching { sendTouch(event, isDown: true) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isTouching else { return }
        isTouching = false
        sendTouch(event, isDown: false)
        touchUsesAdb = false
    }

    override func keyDown(with event: NSEvent) {
        // Leave Cmd shortcuts to the system so they still act like normal Mac shortcuts.
        if event.modifierFlags.contains(.command) { return super.keyDown(with: event) }
        let specialKeys: [UInt16: String] = [
            36: "Enter", 76: "Enter", 51: "Backspace", 117: "Delete", 48: "Tab", 53: "GoBack",
            123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        ]
        if let name = specialKeys[event.keyCode] {
            switch name {
            case "GoBack", "GoHome", "AppSwitch": emulator.sendSystemKey(name: name)
            default: emulator.sendKey(name: name)
            }
        } else if let text = event.characters, !text.isEmpty {
            emulator.sendKey(text: text)
        }
    }

    @objc private func applyAppearance() {
        layer?.backgroundColor = Settings.backgroundColor.cgColor
        window?.backgroundColor = Settings.backgroundColor
        frameLayer.cornerRadius = CGFloat(Settings.cornerRadius)
        needsLayout = true
    }

    func stop() {
        streamTask?.cancel()
        cameraMonitorTask?.cancel()
        fpsTimer?.invalidate()
        releaseScrollFinger()
    }
}
