import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The start screen: lists every AVD and opens a device window for the chosen one.
@MainActor
final class StartWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var avds: [Avd] = []
    private let table = NSTableView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let modeControl = NSSegmentedControl(labels: ["Headless", "With emulator window"], trackingMode: .selectOne, target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: #selector(stop(_:)))
    private let openButton = NSButton(title: "Open", target: nil, action: #selector(open(_:)))
    private let desktopQRButton = NSButton(title: "Desktop QR", target: nil, action: #selector(importDesktopQRCode(_:)))
    private var refreshTimer: Timer?
    // A launch, stop or restart is in flight, so the timer must not switch the buttons back on halfway.
    private var isBusy = false

    private var selectedAvd: Avd? { table.selectedRow >= 0 ? avds[table.selectedRow] : nil }
    private var isHeadlessChosen: Bool { modeControl.selectedSegment == 0 }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Avdpane"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let column = NSTableColumn(identifier: .init("avd"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 48
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(open(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        messageLabel.alignment = .center
        messageLabel.isHidden = true

        modeControl.selectedSegment = Settings.isHeadlessDefault ? 0 : 1
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh(_:)))
        stopButton.target = self
        openButton.target = self
        desktopQRButton.target = self
        desktopQRButton.toolTip = "Capture a desktop QR code as the emulator's live camera input"
        openButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [modeControl, NSView(), refreshButton, desktopQRButton, stopButton, openButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [scroll, messageLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    // The timer only runs while the window is open, and it only re-reads the running files.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh(nil)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { self.refreshRunning() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
    }

    @objc private func refresh(_ sender: Any?) {
        let selectedId = selectedAvd?.id
        do {
            avds = try AvdCatalog.list()
            showMessage(avds.isEmpty ? "No AVDs found. Create one in Android Studio's Device Manager." : nil, isError: false)
        } catch {
            avds = []
            showMessage(error.localizedDescription, isError: true)
        }
        reloadTable(selecting: selectedId)
    }

    // Listing AVDs spawns the emulator binary, so the timer only picks up who is running.
    private func refreshRunning() {
        guard !avds.isEmpty else { return refresh(nil) }
        let running = AvdCatalog.runningEmulators()
        avds = avds.map { Avd(id: $0.id, name: $0.name, running: running[$0.id]) }
        reloadTable(selecting: selectedAvd?.id)
    }

    private func reloadTable(selecting selectedId: String?) {
        table.reloadData()
        if let row = avds.firstIndex(where: { $0.id == selectedId }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateButtons()
    }

    private func showMessage(_ text: String?, isError: Bool) {
        messageLabel.stringValue = text ?? ""
        messageLabel.isHidden = text == nil
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func updateButtons() {
        let running = selectedAvd?.running
        stopButton.isEnabled = !isBusy && running != nil
        desktopQRButton.isEnabled = !isBusy && running != nil
        openButton.isEnabled = !isBusy && selectedAvd != nil
        openButton.title = running.map { $0.hasGrpcEnabled ? "Open" : "Restart" } ?? "Open"
    }

    @objc private func modeChanged(_ sender: Any?) {
        Settings.isHeadlessDefault = isHeadlessChosen
    }

    @objc private func open(_ sender: Any?) {
        if let avd = selectedAvd { open(avd: avd) }
    }

    // Double click still lands while a launch is in flight, and a second copy of the same AVD kills both.
    func open(avd: Avd) {
        guard !isBusy else { return }
        if let running = avd.running {
            if running.hasGrpcEnabled, let port = running.grpcPort {
                AppDelegate.shared.openDeviceWindow(avd: avd, port: port)
            } else {
                restart(avd, running)
            }
        } else {
            launchAndOpen(avd, isHeadless: isHeadlessChosen)
        }
    }

    // Stops the emulator, waits for it to really exit, then starts it again with gRPC on.
    private func restart(_ avd: Avd, _ running: RunningEmulator) {
        let isHeadless = isHeadlessChosen
        Task {
            if await stopAndWait(running) {
                launchAndOpen(avd, isHeadless: isHeadless)
            } else {
                showAlert(AvdError.stopTimedOut(avd.name))
                refresh(nil)
            }
        }
    }

    @objc private func stop(_ sender: Any?) {
        guard let avd = selectedAvd, let running = avd.running else { return }
        Task {
            let isStopped = await stopAndWait(running)
            if !isStopped { showAlert(AvdError.stopTimedOut(avd.name)) }
            refresh(nil)
        }
    }

    @objc private func importDesktopQRCode(_ sender: Any?) {
        guard let running = selectedAvd?.running else {
            showMessage("Select a running emulator first.", isError: true)
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            showMessage("Allow Avdpane in Privacy & Security > Screen & System Audio Recording, then quit and reopen Avdpane.", isError: true)
            return
        }
        guard let avd = selectedAvd else { return }
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Avdpane-QR-\(UUID().uuidString).png")
        let sourceURL = URL(fileURLWithPath: Settings.desktopQRCodePath)
        // The emulator reads imagefile: once during emulator startup. Reopening the
        // Android camera is not enough after the host image changes, so every new QR
        // capture must restart the emulator to load the new frame.
        let needsRestart = true
        isBusy = true
        updateButtons()
        showMessage("Select the QR code area...", isError: false)
        Task {
            let captured = await Task.detached { Self.captureDesktopRegion(to: captureURL) }.value
            guard captured else {
                try? FileManager.default.removeItem(at: captureURL)
                isBusy = false
                showMessage("QR capture cancelled", isError: true)
                updateButtons()
                return
            }
            let prepared = await Task.detached {
                Self.prepareCameraImage(from: captureURL, to: sourceURL)
            }.value
            try? FileManager.default.removeItem(at: captureURL)
            guard prepared else {
                isBusy = false
                showMessage("Could not prepare the QR camera frame", isError: true)
                updateButtons()
                return
            }

            if needsRestart {
                showMessage("QR captured. Restarting emulator to enable live camera input...", isError: false)
                let stopped = await stopAndWait(running)
                guard stopped else {
                    isBusy = false
                    showMessage(AvdError.stopTimedOut(avd.name).localizedDescription, isError: true)
                    refresh(nil)
                    return
                }
                do {
                    let port = try AvdCatalog.launch(avd, isHeadless: running.isHeadless)
                    guard await wait(upTo: 30, until: { AvdCatalog.runningEmulators()[avd.id] != nil }) else {
                        throw AvdError.launchTimedOut(avd.name)
                    }
                    AppDelegate.shared.openDeviceWindow(avd: avd, port: port)
                    showMessage("QR is now the live back camera. Open WeChat Scan.", isError: false)
                } catch {
                    showAlert(error)
                }
            }
            isBusy = false
            refresh(nil)
        }
    }

    private nonisolated static func captureDesktopRegion(to url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-t", "png", url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    // Android 10's imagefile camera source expects an RGBA portrait image on this AVD.
    // We keep the QR itself square in the source frame. WeChat applies its own camera
    // preview transform, so pre-compressing the source makes the QR visibly rectangular.
    private nonisolated static func prepareCameraImage(from inputURL: URL, to outputURL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return false }
        let width = 800
        let height = 1280
        guard let context = CGContext(
            data: nil, width: width, height: height,
            // CoreGraphics does not create a device-RGB bitmap with 3-byte rows on
            // macOS. Keep the canvas in premultiplied RGBA; JPEG encoding below
            // removes the alpha channel when it writes the camera source.
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Keep the source QR square. The smaller canvas footprint leaves enough margin
        // for WeChat's preview crop while preserving all four quiet-zone edges.
        let maxContentWidth = 100.0
        let maxContentHeight = 100.0
        let cameraHorizontalCompensation = 1.0
        let scale = min(maxContentWidth / Double(image.width), maxContentHeight / Double(image.height))
        let drawWidth = Double(image.width) * scale * cameraHorizontalCompensation
        let drawHeight = Double(image.height) * scale
        let drawRect = CGRect(
            x: 90,
            y: 520,
            width: drawWidth, height: drawHeight)
        context.interpolationQuality = .none
        context.draw(image, in: drawRect)
        guard let result = context.makeImage() else { return false }

        let directory = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporaryURL = directory.appendingPathComponent(".DesktopQR-\(UUID().uuidString).png")
            guard let destination = CGImageDestinationCreateWithURL(
                temporaryURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(destination, result, nil)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                return false
            }
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            }
            return true
        } catch {
            return false
        }
    }

    // adb kill returns before the emulator is gone, and saving a snapshot on the way out can take 20 s.
    private func stopAndWait(_ running: RunningEmulator) async -> Bool {
        isBusy = true
        updateButtons()
        await Task.detached { AvdCatalog.stop(running) }.value
        let isStopped = await wait(upTo: 30) { kill(running.pid, 0) != 0 }
        isBusy = false
        return isStopped
    }

    private func showAlert(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { avds.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = AvdRowView()
        view.show(avds[row])
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // The emulator writes its running file a few seconds after start, so hold the list until then.
    private func launchAndOpen(_ avd: Avd, isHeadless: Bool) {
        isBusy = true
        updateButtons()
        showMessage("Starting \(avd.name)...", isError: false)
        Task {
            do {
                let port = try AvdCatalog.launch(avd, isHeadless: isHeadless)
                guard await wait(upTo: 30, until: { AvdCatalog.runningEmulators()[avd.id] != nil }) else {
                    throw AvdError.launchTimedOut(avd.name)
                }
                AppDelegate.shared.openDeviceWindow(avd: avd, port: port)
            } catch { showAlert(error) }
            isBusy = false
            refresh(nil)
        }
    }

    // Polls every 200 ms. False when the deadline passes first.
    private func wait(upTo seconds: Double, until isDone: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !isDone() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }
}

private final class AvdRowView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let idLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        idLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSStackView(views: [nameLabel, idLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let row = NSStackView(views: [text, NSView(), statusLabel])
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ avd: Avd) {
        nameLabel.stringValue = avd.name
        idLabel.stringValue = avd.id
        let running = avd.running
        statusLabel.stringValue = running.map { $0.hasGrpcEnabled ? "Running" : "Running (no gRPC)" } ?? "Stopped"
        // Greyed when we cannot connect, the emulator was started without -grpc.
        let isUsable = running?.hasGrpcEnabled ?? true
        nameLabel.textColor = isUsable ? .labelColor : .tertiaryLabelColor
        idLabel.textColor = isUsable ? .secondaryLabelColor : .tertiaryLabelColor
        statusLabel.textColor = isUsable ? .secondaryLabelColor : .tertiaryLabelColor
    }
}
