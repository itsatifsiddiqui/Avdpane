import CoreGraphics
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Synchronization

private struct DisplayStreamConnectionTimeout: Error {}

// Thin gRPC client for the running emulator. Input calls are fire and forget.
final class Emulator: Sendable {
    private typealias Client = Android_Emulation_Control_EmulatorController.Client<HTTP2ClientTransport.Posix>
    private let port: Int
    // Connection of the running frame stream. Nil while disconnected, then input calls are dropped.
    private let grpc = Mutex<GRPCClient<HTTP2ClientTransport.Posix>?>(nil)
    // Angle set by the last rotate. The emulator reports mid animation angles for a moment after a set.
    private let rotation = Mutex<Float?>(nil)
    // Logical display and last frame sizes, used to map frame pixels to ADB input coordinates.
    private let displaySize = Mutex<(width: Int, height: Int)?>(nil)
    private let frameSize = Mutex<(width: Int, height: Int)?>(nil)

    init(port: Int) { self.port = port }

    // A fresh connection per attempt. A failed one takes minutes to notice the emulator came back.
    private func makeTransport() throws -> HTTP2ClientTransport.Posix {
        try HTTP2ClientTransport.Posix(target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: .plaintext)
    }

    // Polling keeps the emulator display responsive when it is safe to read frames.
    // Android 10's Camera2 encoder must own the graphics readback path while recording,
    // so callers can pause this stream for the duration of a video capture.
    func streamFrames(
        _ onFrame: @Sendable @escaping (CGImage) -> Void,
        frameInterval: @Sendable @escaping () async -> Duration = { .milliseconds(66) },
        shouldContinue: @Sendable @escaping () async -> Bool = { true }
    ) async throws {
        let format: Android_Emulation_Control_ImageFormat = {
            var format = Android_Emulation_Control_ImageFormat()
            format.format = .rgb888
            // Smaller frames leave enough graphics bandwidth for camera video encoding.
            format.width = 640
            return format
        }()
        // Frames are raw RGB, a 1080x2340 screen is 7.6 MB, well over the 4 MB gRPC default.
        // The NIO transport sizes its inbound decoder from the request limit, so set both.
        let options: CallOptions = {
            var options = CallOptions.defaults
            // A camera can take ownership of display readback while a screenshot RPC
            // is in flight. Bound that request so the stream connection is released
            // promptly instead of holding the camera's input/encoder path open.
            options.timeout = .milliseconds(1500)
            options.maxRequestMessageBytes = 64 << 20
            options.maxResponseMessageBytes = 64 << 20
            return options
        }()
        let transport = try makeTransport()
        let streamReady = Mutex(false)
        let lastDisplayConfigurationRefresh = Mutex(Date.distantPast)
        let timeoutCount = Mutex(0)
        let stalledFrameCount = Mutex(0)
        // `withGRPCClient` starts its connection manager before invoking the handler. If the
        // emulator's gRPC endpoint is half-open after Camera2 releases the display, the handler
        // can wait indefinitely for a ready HTTP/2 connection even though port 8554 is listening.
        // Keep the reconnect loop live by racing the first frame against a short connection
        // watchdog. Once a frame has arrived, the watchdog stays alive but no longer expires.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withGRPCClient(transport: transport) { connection in
                    self.grpc.withLock { $0 = connection }
                    defer { self.grpc.withLock { $0 = nil } }
                    let client = Client(wrapping: connection)
                    if let size = await self.logicalDisplaySize() { self.displaySize.withLock { $0 = size } }
                    while !Task.isCancelled {
                        guard await shouldContinue() else { return }
                        // Camera activities can flip the logical display to portrait without a new
                        // gRPC connection, so keep the ADB input space current on this stream.
                        let refreshDisplayConfiguration = lastDisplayConfigurationRefresh.withLock { last in
                            guard Date().timeIntervalSince(last) >= 0.5 else { return false }
                            last = Date()
                            return true
                        }
                        if refreshDisplayConfiguration, let size = await self.logicalDisplaySize() {
                            self.displaySize.withLock { $0 = size }
                        }
                        do {
                            let frame = try await client.getScreenshot(format, options: options)
                            var width = Int(frame.format.width), height = Int(frame.format.height)
                            if width == 0 {
                                let display = try await client.getDisplayConfigurations(.init()).displays.first
                                width = Int(display?.width ?? 0)
                                height = Int(display?.height ?? 0)
                            }
                            guard width > 0, height > 0,
                                let provider = CGDataProvider(data: frame.image as CFData),
                                let image = CGImage(
                                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                    bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                            else {
                                try await Task.sleep(for: .milliseconds(66))
                                continue
                            }
                            timeoutCount.withLock { $0 = 0 }
                            stalledFrameCount.withLock { $0 = 0 }
                            self.frameSize.withLock { $0 = (width, height) }
                            streamReady.withLock { $0 = true }
                            onFrame(image)
                        } catch let error as RPCError where error.code == .failedPrecondition {
                            let shouldReconnect = stalledFrameCount.withLock { count in
                                count += 1
                                return count >= 30
                            }
                            if shouldReconnect {
                                connection.beginGracefulShutdown()
                                throw error
                            }
                        } catch let error as RPCError where error.code == .deadlineExceeded {
                            let shouldReconnect = timeoutCount.withLock { count in
                                count += 1
                                return count >= 4
                            }
                            if !shouldReconnect { continue }
                            connection.beginGracefulShutdown()
                            throw error
                        } catch {
                            // A screenshot timeout is recoverable, but the HTTP/2 connection that
                            // carried the timed-out RPC is not reliable afterwards. In particular,
                            // Android 10 can leave the display readback request alive while Camera2
                            // is returning to the previous Activity. Explicitly tear this connection
                            // down before propagating the error so streamForever can create a fresh
                            // transport immediately. Without this, the window can remain on the last
                            // QR frame even though Android has already handled Back.
                            connection.beginGracefulShutdown()
                            throw error
                        }
                        try await Task.sleep(for: await frameInterval())
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                guard !streamReady.withLock({ $0 }) else {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                    }
                    return
                }
                transport.beginGracefulShutdown()
                throw DisplayStreamConnectionTimeout()
            }
            defer {
                group.cancelAll()
                transport.beginGracefulShutdown()
            }
            try await group.next()
        }
    }

    // Input must reach the phone in the order it happened, so each send waits for the one before.
    @MainActor private var lastSend: Task<Void, Never>?
    @MainActor private var lastAdbInput: Task<Void, Never>?
    @MainActor private var adbTouchStart: (x: Int, y: Int)?
    @MainActor private var adbTouchMoved = false
    // A burst of input while disconnected logs one line, not one per event.
    @MainActor private var isDropLogged = false

    @MainActor private func enqueueAdb(_ arguments: [String]) {
        guard let serial = AvdCatalog.runningEmulators().values.first(where: { $0.grpcPort == port })?.adbSerial else { return }
        let previous = lastAdbInput
        lastAdbInput = Task {
            await previous?.value
            _ = await Task.detached(operation: { AvdCatalog.adb(["-s", serial] + arguments) }).value
        }
    }

    @MainActor private func enqueue(_ send: @Sendable @escaping (Client) async throws -> Void) {
        guard let connection = grpc.withLock({ $0 }) else {
            if !isDropLogged { print("input dropped on port \(port): emulator not connected") }
            isDropLogged = true
            return
        }
        isDropLogged = false
        let previous = lastSend
        lastSend = Task.detached {
            await previous?.value
            do { try await send(Client(wrapping: connection)) } catch { print("input on port \(self.port) failed: \(error)") }
        }
    }

    // ponytail: single finger only, identifier is always 0. Camera2 apps can keep the
    // gRPC input endpoint alive while dropping its touch events, so callers can request
    // the same raw touch to be delivered through adb. Android still performs the hit test;
    // Avdpane never interprets the coordinates as Back/Home/Recents.
    @MainActor func sendTouch(x: Int, y: Int, isDown: Bool, preferAdb: Bool = false) {
        if preferAdb || grpc.withLock({ $0 }) == nil {
            sendTouchViaAdb(x: x, y: y, isDown: isDown)
            return
        }
        var touch = Android_Emulation_Control_Touch()
        touch.x = Int32(x)
        touch.y = Int32(y)
        touch.pressure = isDown ? 1 : 0
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [touch]
        enqueue { [event] client in _ = try await client.sendTouch(event) }
    }

    @MainActor private func sendTouchViaAdb(x: Int, y: Int, isDown: Bool) {
        let point = adbPoint(x: x, y: y)
        if isDown {
            if let previous = adbTouchStart {
                adbTouchMoved = true
                enqueueAdb(["shell", "input", "swipe", "\(previous.x)", "\(previous.y)", "\(point.x)", "\(point.y)", "80"])
            } else {
                adbTouchStart = point
            }
        } else {
            if let start = adbTouchStart {
                if adbTouchMoved {
                    enqueueAdb(["shell", "input", "swipe", "\(start.x)", "\(start.y)", "\(point.x)", "\(point.y)", "80"])
                } else {
                    // A short same-point swipe gives Android a real press/release interval.
                    enqueueAdb(["shell", "input", "swipe", "\(point.x)", "\(point.y)", "\(point.x)", "\(point.y)", "120"])
                }
            }
            adbTouchStart = nil
            adbTouchMoved = false
        }
    }

    // Pass either a w3c key name like "Enter" or plain text, never both.
    @MainActor func sendKey(name: String = "", text: String = "") {
        guard grpc.withLock({ $0 }) != nil else {
            let keycode: String? = switch name {
            case "GoBack": "KEYCODE_BACK"
            case "GoHome": "KEYCODE_HOME"
            case "AppSwitch": "KEYCODE_APP_SWITCH"
            case "Power": "KEYCODE_POWER"
            case "Enter": "KEYCODE_ENTER"
            case "Backspace", "Delete": "KEYCODE_DEL"
            case "ArrowLeft": "KEYCODE_DPAD_LEFT"
            case "ArrowRight": "KEYCODE_DPAD_RIGHT"
            case "ArrowUp": "KEYCODE_DPAD_UP"
            case "ArrowDown": "KEYCODE_DPAD_DOWN"
            default: nil
            }
            if let keycode {
                enqueueAdb(["shell", "input", "keyevent", keycode])
            } else if !text.isEmpty {
                enqueueAdb(["shell", "input", "text", text.replacingOccurrences(of: " ", with: "%s")])
            }
            return
        }
        var event = Android_Emulation_Control_KeyboardEvent()
        event.eventType = .keypress
        event.key = name
        event.text = text
        enqueue { [event] client in _ = try await client.sendKey(event) }
    }

    // Android's system navigation bar remains usable while Camera2 owns the display
    // readback path. Close that display connection first, then send the navigation key
    // through adb so a stale screenshot RPC cannot delay Back/Home/Recents.
    @MainActor func sendSystemKey(name: String) {
        stopDisplayStream()
        sendKey(name: name)
    }

    // A quarter turn each time, like the emulator's own rotate button. Reads the current
    // angle first so a window opened on an already turned emulator keeps counting from there.
    @MainActor func rotate() {
        var model = Android_Emulation_Control_PhysicalModelValue()
        model.target = .rotation
        enqueue { [model] client in
            var angle = self.rotation.withLock { $0 }
            if angle == nil { angle = try await client.getPhysicalModel(model).value.data.last }
            var next = model
            next.value.data = [0, 0, ((angle ?? 0) + 90).truncatingRemainder(dividingBy: 360)]
            _ = try await client.setPhysicalModel(next)
            self.rotation.withLock { $0 = next.value.data[2] }
        }
    }

    // Opens the emulator's own settings window. Only works when the emulator has a Qt UI,
    // so never call it for a -no-window emulator, that crashes it.
    func showExtendedControls() async throws {
        guard let connection = grpc.withLock({ $0 }) else { return }
        var entry = Android_Emulation_Control_PaneEntry()
        entry.index = .keepCurrent
        _ = try await Android_Emulation_Control_UiController.Client(wrapping: connection).showExtendedControls(entry)
    }

    @MainActor func stopDisplayStream() {
        let connection = grpc.withLock { current in
            let connection = current
            current = nil
            return connection
        }
        connection?.beginGracefulShutdown()
    }

    @MainActor func setClipboard(_ text: String) {
        var clip = Android_Emulation_Control_ClipData()
        clip.text = text
        enqueue { [clip] client in _ = try await client.setClipboard(clip) }
    }

    // Runs until the stream ends or fails. The first message is only the current state,
    // not something the user just copied, so it is skipped.
    func streamClipboard(_ onText: @Sendable @escaping (String) -> Void) async throws {
        try await withGRPCClient(transport: makeTransport()) { connection in
            try await Client(wrapping: connection).streamClipboard(.init()) { response in
                for try await clip in response.messages.dropFirst() { onText(clip.text) }
            }
        }
    }

    // Stops queued input and closes the connection. The owners cancel the stream tasks themselves.
    @MainActor func shutdown() {
        lastSend?.cancel()
        lastAdbInput?.cancel()
        stopDisplayStream()
    }

    // ADB input uses the logical display. A landscape skin frame shown on a portrait
    // logical display (Camera activities) is turned a quarter turn to match it.
    private func adbPoint(x: Int, y: Int) -> (x: Int, y: Int) {
        guard let display = displaySize.withLock({ $0 }),
              let frame = frameSize.withLock({ $0 }),
              frame.width > 1, frame.height > 1 else { return (x, y) }
        let fractionX = Double(x) / Double(frame.width - 1)
        let fractionY = Double(y) / Double(frame.height - 1)
        let frameIsDisplayOriented = (frame.width <= frame.height) == (display.width <= display.height)
        if frameIsDisplayOriented {
            return (Int((fractionX * Double(display.width - 1)).rounded()),
                    Int((fractionY * Double(display.height - 1)).rounded()))
        }
        return (Int(((1 - fractionY) * Double(display.width - 1)).rounded()),
                Int((fractionX * Double(display.height - 1)).rounded()))
    }

    private func logicalDisplaySize() async -> (width: Int, height: Int)? {
        guard let serial = AvdCatalog.runningEmulators().values.first(where: { $0.grpcPort == port })?.adbSerial else { return nil }
        return await Task.detached { AvdCatalog.logicalDisplaySize(serial: serial) }.value
    }
}
