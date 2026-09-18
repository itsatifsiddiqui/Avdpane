import CoreGraphics
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Synchronization

// Thin gRPC client for the running emulator. Input calls are fire and forget.
final class Emulator: Sendable {
    private typealias Client = Android_Emulation_Control_EmulatorController.Client<HTTP2ClientTransport.Posix>
    private let port: Int
    // Connection of the running frame stream. Nil while disconnected, then input calls are dropped.
    private let grpc = Mutex<GRPCClient<HTTP2ClientTransport.Posix>?>(nil)
    // Angle set by the last rotate. The emulator reports mid animation angles for a moment after a set.
    private let rotation = Mutex<Float?>(nil)

    init(port: Int) { self.port = port }

    // A fresh connection per attempt. A failed one takes minutes to notice the emulator came back.
    private func makeTransport() throws -> HTTP2ClientTransport.Posix {
        try HTTP2ClientTransport.Posix(target: .ipv4(address: "127.0.0.1", port: port), transportSecurity: .plaintext)
    }

    // Runs until the stream ends or fails. Frames arrive as ready to draw CGImages.
    func streamFrames(_ onFrame: @Sendable @escaping (CGImage) -> Void) async throws {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgb888
        // Frames are raw RGB, a 1080x2340 screen is 7.6 MB, well over the 4 MB gRPC default.
        // The NIO transport sizes its inbound decoder from the request limit, so set both.
        var options = CallOptions.defaults
        options.maxRequestMessageBytes = 64 << 20
        options.maxResponseMessageBytes = 64 << 20
        try await withGRPCClient(transport: makeTransport()) { connection in
            grpc.withLock { $0 = connection }
            defer { grpc.withLock { $0 = nil } }
            let client = Client(wrapping: connection)
            try await client.streamScreenshot(format, options: options) { response in
                for try await frame in response.messages {
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
                    else { continue }
                    onFrame(image)
                }
            }
        }
    }

    // Input must reach the phone in the order it happened, so each send waits for the one before.
    @MainActor private var lastSend: Task<Void, Never>?
    // A burst of input while disconnected logs one line, not one per event.
    @MainActor private var isDropLogged = false

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

    // ponytail: single finger only, identifier is always 0.
    @MainActor func sendTouch(x: Int, y: Int, isDown: Bool) {
        var touch = Android_Emulation_Control_Touch()
        touch.x = Int32(x)
        touch.y = Int32(y)
        touch.pressure = isDown ? 1 : 0
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [touch]
        enqueue { [event] client in _ = try await client.sendTouch(event) }
    }

    // Pass either a w3c key name like "Enter" or plain text, never both.
    @MainActor func sendKey(name: String = "", text: String = "") {
        var event = Android_Emulation_Control_KeyboardEvent()
        event.eventType = .keypress
        event.key = name
        event.text = text
        enqueue { [event] client in _ = try await client.sendKey(event) }
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
        grpc.withLock { $0 }?.beginGracefulShutdown()
    }
}
