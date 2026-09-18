import AppKit

// The start screen: lists every AVD and opens a device window for the chosen one.
@MainActor
final class StartWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var avds: [Avd] = []
    private let table = NSTableView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let modeControl = NSSegmentedControl(labels: ["Headless", "With emulator window"], trackingMode: .selectOne, target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: #selector(stop(_:)))
    private let openButton = NSButton(title: "Open", target: nil, action: #selector(open(_:)))
    private var refreshTimer: Timer?
    // A launch, stop or restart is in flight, so the timer must not switch the buttons back on halfway.
    private var isBusy = false

    private var selectedAvd: Avd? { table.selectedRow >= 0 ? avds[table.selectedRow] : nil }
    private var isHeadlessChosen: Bool { modeControl.selectedSegment == 0 }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
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
        openButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [modeControl, NSView(), refreshButton, stopButton, openButton])
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
