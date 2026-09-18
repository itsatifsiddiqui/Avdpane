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
    private var fpsTimer: Timer?
    private var streamTask: Task<Void, Never>?
    // Frames carry the attempt they came from, so a late one cannot show after that attempt ended.
    private var streamGeneration = 0
    private(set) var currentImage: CGImage?
    // Scroll wheel drag in device pixels, nil while no finger is down.
    var scrollFinger: CGPoint?
    var scrollReleaseTask: Task<Void, Never>?

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
                    Task { @MainActor in if generation == self.streamGeneration { self.show(image) } }
                }
            } catch { print("stream on port \(port) ended: \(error)") }
            streamGeneration += 1
            // Drop the stale frame so the message shows on black, not over the last screen.
            frameLayer.contents = nil
            currentImage = nil
            let isRunning = AvdCatalog.runningEmulators().values.contains { $0.grpcPort == port }
            errorLabel.stringValue = isRunning ? "Waiting for emulator on port \(port)..." : "Emulator stopped"
            errorLabel.isHidden = false
            try? await Task.sleep(for: .seconds(2))
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
        emulator.sendTouch(x: device.x, y: device.y, isDown: isDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard phoneRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        isTouching = true
        sendTouch(event, isDown: true)
    }

    override func mouseDragged(with event: NSEvent) {
        if isTouching { sendTouch(event, isDown: true) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isTouching else { return }
        isTouching = false
        sendTouch(event, isDown: false)
    }

    override func keyDown(with event: NSEvent) {
        // Leave Cmd shortcuts to the system so they still act like normal Mac shortcuts.
        if event.modifierFlags.contains(.command) { return super.keyDown(with: event) }
        let specialKeys: [UInt16: String] = [
            36: "Enter", 76: "Enter", 51: "Backspace", 117: "Delete", 48: "Tab", 53: "GoBack",
            123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        ]
        if let name = specialKeys[event.keyCode] {
            emulator.sendKey(name: name)
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
        fpsTimer?.invalidate()
    }
}
