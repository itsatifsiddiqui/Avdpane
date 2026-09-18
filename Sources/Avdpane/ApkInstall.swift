import AppKit
import UniformTypeIdentifiers

// Sits over the emulator view. Catches APK drags and hosts the HUD; mouse events fall through to the phone.
@MainActor
final class ApkDropOverlay: NSView {
    let hint = NSTextField(labelWithString: "Drop APK to install")
    let hudLabel = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    let hud: NSStackView
    var hideTask: Task<Void, Never>?
    var isInstalling = false
    var onDrop: (URL) -> Void = { _ in }

    init() {
        hud = NSStackView(views: [spinner, hudLabel])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        hint.textColor = .white
        hint.font = .systemFont(ofSize: 20, weight: .semibold)
        hint.isHidden = true
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .darkAqua)
        hudLabel.textColor = .white
        hudLabel.maximumNumberOfLines = 6
        hudLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hud.setClippingResistancePriority(.defaultLow, for: .horizontal)
        hud.orientation = .horizontal
        hud.spacing = 8
        hud.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        hud.wantsLayer = true
        hud.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        hud.layer?.cornerRadius = 8
        hud.isHidden = true
        hud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hud)

        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            hud.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // A long adb error must wrap inside the window instead of pushing the HUD wider than it.
    override func layout() {
        hudLabel.preferredMaxLayoutWidth = bounds.width - 80
        super.layout()
    }

    // Only the HUD is clickable, so an error can be dismissed. Everything else reaches the phone.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !hud.isHidden && hud.frame.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if !isInstalling { hud.isHidden = true }
    }

    private func apkUrl(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first { $0.pathExtension.lowercased() == "apk" }
    }

    private func hideHint() {
        layer?.backgroundColor = nil
        hint.isHidden = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !isInstalling, apkUrl(sender) != nil else { return [] }
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hint.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hideHint() }

    override func draggingEnded(_ sender: NSDraggingInfo) { hideHint() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = apkUrl(sender) else { return false }
        onDrop(url)
        return true
    }
}

extension DeviceWindowController {
    func installApkDrop() {
        dropOverlay.onDrop = { [unowned self] url in installApk(at: url) }
        emulatorView.addSubview(dropOverlay)
        NSLayoutConstraint.activate([
            dropOverlay.leadingAnchor.constraint(equalTo: emulatorView.leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: emulatorView.trailingAnchor),
            dropOverlay.topAnchor.constraint(equalTo: emulatorView.topAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: emulatorView.bottomAnchor),
        ])
    }

    // Busy stays until replaced, an error stays until clicked, anything else goes away after 2 seconds.
    func showHud(_ text: String, isBusy: Bool = false, isError: Bool = false) {
        let overlay = dropOverlay
        overlay.hideTask?.cancel()
        overlay.hudLabel.stringValue = text
        overlay.hudLabel.textColor = isError ? .systemRed : .white
        overlay.spinner.isHidden = !isBusy
        isBusy ? overlay.spinner.startAnimation(nil) : overlay.spinner.stopAnimation(nil)
        overlay.hud.isHidden = false
        guard !isBusy, !isError else { return }
        overlay.hideTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { overlay.hud.isHidden = true }
        }
    }

    func installApk(at url: URL) {
        guard !dropOverlay.isInstalling else { return }
        guard let serial = adbSerial else {
            return showHud("Emulator is still starting, try again in a moment")
        }
        dropOverlay.isInstalling = true
        showHud("Installing \(url.lastPathComponent)...", isBusy: true)
        Task {
            let result = await Task.detached { AvdCatalog.adb(["-s", serial, "install", "-r", url.path]) }.value
            dropOverlay.isInstalling = false
            let lastLine = result.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "adb gave no output"
            result.status == 0 ? showHud("Installed") : showHud(lastLine, isError: true)
        }
    }

    @objc func installApk(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.installApk(at: url)
        }
    }
}
