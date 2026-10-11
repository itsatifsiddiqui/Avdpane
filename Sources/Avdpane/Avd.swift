import Foundation

struct Avd {
    let id: String
    let name: String
    let running: RunningEmulator?
}

struct RunningEmulator {
    let pid: Int32
    let adbSerial: String
    let grpcPort: Int?
    // False when the emulator was started without -grpc, then it wants a token we do not have.
    let hasGrpcEnabled: Bool
    let isHeadless: Bool
    // False for -no-window. That build has no Qt at all and the extended controls rpc crashes it.
    let hasUi: Bool
    // True when the emulator was launched with a host image/video camera source.
    let hasDesktopCameraSource: Bool
}

enum AvdError: LocalizedError {
    case sdkNotFound(String)
    case launchTimedOut(String)
    case stopTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .sdkNotFound(let path): "Android SDK not found at \(path). Set it in Settings."
        case .launchTimedOut(let name): "\(name) did not start. Check its log in ~/Library/Logs/Avdpane."
        case .stopTimedOut(let name): "\(name) did not stop in time. Quit it from its own window, then open it again."
        }
    }
}

// Finds, starts and stops AVDs using the SDK command line tools.
enum AvdCatalog {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let runningDir = home + "/Library/Caches/TemporaryItems/avd/running"
    static let logDir = home + "/Library/Logs/Avdpane"
    // Ports handed out this session. A just launched emulator has not bound its port or written
    // its ini yet, so without this two launches in a row would get the same port.
    // ponytail: ports stay reserved for the app's lifetime, freeing one when its ini disappears is the upgrade.
    @MainActor static var reservedPorts: Set<Int> = []

    static func list() throws -> [Avd] {
        guard FileManager.default.isExecutableFile(atPath: Settings.emulatorBinary) else {
            throw AvdError.sdkNotFound(Settings.sdkPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Settings.emulatorBinary)
        process.arguments = ["-list-avds"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AvdError.sdkNotFound(Settings.sdkPath) }

        let running = runningEmulators()
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.map { id in
            let config = iniValues(atPath: home + "/.android/avd/\(id).avd/config.ini")
            return Avd(id: id, name: config["avd.ini.displayname"] ?? id, running: running[id])
        }
    }

    // Keyed by AVD id. The emulator writes one ini per running instance and deletes it on exit.
    static func runningEmulators() -> [String: RunningEmulator] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: runningDir)) ?? []
        var result: [String: RunningEmulator] = [:]
        for file in files where file.hasPrefix("pid_") && file.hasSuffix(".ini") {
            let values = iniValues(atPath: runningDir + "/" + file)
            guard let id = values["avd.id"], let serial = values["port.serial"],
                  let pid = Int32(file.dropFirst(4).dropLast(4)),
                  // A killed emulator can leave its ini behind, so trust the file only if the pid is alive.
                  kill(pid, 0) == 0 else { continue }
            let cmdline = values["cmdline"] ?? ""
            result[id] = RunningEmulator(
                pid: pid, adbSerial: "emulator-\(serial)",
                grpcPort: values["grpc.port"].flatMap(Int.init),
                hasGrpcEnabled: cmdline.contains("\"-grpc\""),
                isHeadless: cmdline.contains("\"-no-window\"") || cmdline.contains("\"-qt-hide-window\""),
                hasUi: !cmdline.contains("\"-no-window\""),
                hasDesktopCameraSource: cmdline.contains("\"-camera-back\"")
                    && cmdline.contains("imagefile:"))
        }
        return result
    }

    // Starts the AVD detached from us so it keeps running after the app quits. Returns the gRPC port.
    @MainActor static func launch(_ avd: Avd, isHeadless: Bool) throws -> Int {
        guard FileManager.default.isExecutableFile(atPath: Settings.emulatorBinary) else {
            throw AvdError.sdkNotFound(Settings.sdkPath)
        }
        let port = firstFreePort()
        var arguments = ["-avd", avd.id, "-grpc", String(port)]
        // A killed -no-window emulator leaves a crash dump, and the report dialog would block the next boot.
        if hasCrashReportMode { arguments += ["-crash-report-mode", "never"] }
        // Hidden Qt window instead of -no-window, so extended controls can still be opened.
        if isHeadless { arguments.append("-qt-hide-window") }
        arguments += Settings.extraEmulatorArgs.split(separator: " ").map(String.init)
        // A captured desktop QR is exposed as a live camera source, not as a media file.
        // The image source emits camera frames continuously; it must be present at emulator
        // startup because the emulator reads the source when the camera HAL is initialized.
        if FileManager.default.fileExists(atPath: Settings.desktopQRCodePath) {
            arguments += ["-camera-back", "imagefile:\(Settings.desktopQRCodePath)"]
        }
        // Android Emulator 37.2 on macOS can hang in the gfxstream/Metal path
        // while Camera is recording (invalid ColorBuffer followed by a
        // qemu-system-aarch64 hang). `swiftshader_indirect` still goes through
        // the indirect color-buffer path on this emulator build; use the
        // Preserve the known-working Android 10 renderer. Camera recording is
        // protected separately by stopping display readback before the shutter.
        let hasExplicitGPU = arguments.contains("-gpu") || arguments.contains { $0.hasPrefix("-gpu=") }
        if !hasExplicitGPU { arguments += ["-gpu", "swiftshader_indirect"] }
        // The emulator deliberately zeroes host microphone samples unless this
        // opt-in is present. Android still reports a healthy AudioRecord stream
        // without it, which makes Camera videos look like they have audio while
        // actually containing near-silence. Keep an explicit audio choice intact.
        let hasExplicitAudio = arguments.contains("-no-audio")
            || arguments.contains("-noaudio")
            || arguments.contains("-allow-host-audio")
            || arguments.contains("-audio")
            || arguments.contains { $0.hasPrefix("-audio=") }
        if !hasExplicitAudio { arguments.append("-allow-host-audio") }

        try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let logPath = logDir + "/\(avd.id).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Settings.emulatorBinary)
        process.arguments = arguments
        process.standardOutput = log
        process.standardError = log
        try process.run()
        reservedPorts.insert(port)
        return port
    }

    static func stop(_ running: RunningEmulator) {
        if adb(["-s", running.adbSerial, "emu", "kill"]).status != 0 { kill(running.pid, SIGTERM) }
    }

    // Runs adb and waits for it. A missing binary comes back as a failed status with the reason as output.
    static func adb(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Settings.adbBinary)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    struct CameraState: Sendable {
        let isInUse: Bool
        let isRecording: Bool
    }

    // Android 10's emulated camera cannot reliably encode video while the emulator's
    // screenshot RPC is reading display frames at full speed. The preview is kept live
    // at a reduced rate while Camera is recording.
    static func cameraState(serial: String) -> CameraState? {
        let result = adb(["-s", serial, "shell", "dumpsys", "media.camera"])
        guard result.status == 0 else { return nil }
        // CameraService lists every active Camera2 client here, including the stock
        // Camera app and WeChat. Do not key this off a package name.
        let isInUse = result.output.contains("Client package:")
            || result.output.contains("Client Package Name:")
        // A video-mode preview keeps VIDEO_RECORD as its capture intent, so only a
        // real recording stream counts. Otherwise the display stays paused in preview.
        let isRecording = result.output.contains("State: RECORD")
            || (result.output.contains("Recording stream ID:")
                && !result.output.contains("Recording stream ID: -1"))
        return CameraState(isInUse: isInUse, isRecording: isRecording)
    }

    static func isCameraInUse(serial: String) -> Bool {
        cameraState(serial: serial)?.isInUse ?? false
    }

    // The stock Android Camera app treats the emulator's landscape-native display like a
    // portrait phone and writes a 90-degree tkhd matrix into its MP4 files. The encoded
    // video is already 1280x720, so clear only that video-track rotation after recording
    // finishes. This keeps the original path and filename while making desktop players
    // display the tablet recording as landscape.
    static func normalizeLatestCameraVideo(serial: String) {
        for _ in 0..<5 {
            let listing = adb(["-s", serial, "shell", "ls", "-t", "/sdcard/DCIM/Camera"])
            guard listing.status == 0,
                  let filename = listing.output.split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .first(where: { $0.hasPrefix("VID_") && $0.hasSuffix(".mp4") }) else { return }

            let remotePath = "/sdcard/DCIM/Camera/\(filename)"
            let localPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("Avdpane-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: localPath) }

            // Wait for MediaRecorder/MediaProvider to finish closing the file and writing
            // its moov box. A stable size alone is not enough during that final transition.
            var previousSize: Int64 = -1
            for _ in 0..<8 {
                let stat = adb(["-s", serial, "shell", "stat", "-c", "%s", remotePath])
                let size = Int64(stat.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if size > 0, size == previousSize { usleep(300_000); break }
                previousSize = size
                usleep(150_000)
            }

            guard adb(["-s", serial, "pull", remotePath, localPath.path]).status == 0,
                  var data = try? Data(contentsOf: localPath) else {
                usleep(300_000)
                continue
            }
            guard clearVideoRotationMatrix(in: &data) else {
                // The file may still be missing its final moov metadata. Pull it again
                // after a short delay before giving up.
                usleep(400_000)
                continue
            }
            guard (try? data.write(to: localPath, options: .atomic)) != nil else { return }

            let remoteTemp = "/sdcard/DCIM/Camera/.Avdpane-\(UUID().uuidString).mp4"
            guard adb(["-s", serial, "push", localPath.path, remoteTemp]).status == 0 else { return }
            let replaced = adb(["-s", serial, "shell", "mv", "-f", remoteTemp, remotePath]).status == 0
            if !replaced { _ = adb(["-s", serial, "shell", "rm", "-f", remoteTemp]) }
            return
        }
    }

    private static func clearVideoRotationMatrix(in data: inout Data) -> Bool {
        let identity: [Int32] = [65536, 0, 0, 0, 65536, 0, 0, 0, 1073741824]
        var changed = false
        guard let moov = boxes(in: data, from: 0, to: data.count).first(where: { $0.type == "moov" }) else {
            return false
        }
        for trak in boxes(in: data, from: moov.payload, to: moov.end).filter({ $0.type == "trak" }) {
            let children = boxes(in: data, from: trak.payload, to: trak.end)
            guard let mdia = children.first(where: { $0.type == "mdia" }) else { continue }
            let mdiaChildren = boxes(in: data, from: mdia.payload, to: mdia.end)
            guard let handler = mdiaChildren.first(where: { $0.type == "hdlr" }),
                  handler.payload + 12 <= data.count,
                  String(decoding: data[(handler.payload + 8)..<(handler.payload + 12)], as: UTF8.self) == "vide",
                  let tkhd = children.first(where: { $0.type == "tkhd" }) else { continue }

            let version = data[tkhd.payload]
            let matrixOffset = tkhd.payload + (version == 1 ? 52 : 40)
            guard matrixOffset + 36 <= tkhd.end else { continue }
            let matrix = stride(from: matrixOffset, to: matrixOffset + 36, by: 4).map {
                Int32(bitPattern: readUInt32(data, at: $0))
            }
            // Only normalize quarter-turn metadata. Preserve identity and 180-degree
            // rotations, which can be intentional for a user-selected device rotation.
            guard matrix[0] == 0, matrix[4] == 0,
                  abs(matrix[1]) == 65536, abs(matrix[3]) == 65536 else { continue }
            for (index, value) in identity.enumerated() {
                writeUInt32(&data, at: matrixOffset + index * 4, value: UInt32(bitPattern: value))
            }
            changed = true
        }
        return changed
    }

    private struct MP4Box {
        let type: String
        let payload: Int
        let end: Int
    }

    private static func boxes(in data: Data, from start: Int, to end: Int) -> [MP4Box] {
        var result: [MP4Box] = []
        var offset = start
        while offset + 8 <= end {
            let basicSize = readUInt32(data, at: offset)
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var header = 8
            var size = UInt64(basicSize)
            if basicSize == 1 {
                guard offset + 16 <= end else { break }
                size = readUInt64(data, at: offset + 8)
                header = 16
            } else if basicSize == 0 {
                size = UInt64(end - offset)
            }
            guard size >= UInt64(header), size <= UInt64(end - offset),
                  let boxEnd = Int(exactly: UInt64(offset) + size) else { break }
            result.append(MP4Box(type: type, payload: offset + header, end: boxEnd))
            offset = boxEnd
        }
        return result
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        UInt64(readUInt32(data, at: offset)) << 32 | UInt64(readUInt32(data, at: offset + 4))
    }

    private static func writeUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 24)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    private static func iniValues(atPath path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[line[..<equals].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    // Even ports only, the emulator uses the odd one next to it for adb style pairing.
    @MainActor private static func firstFreePort() -> Int {
        let taken = reservedPorts.union(runningEmulators().values.compactMap(\.grpcPort))
        var port = Settings.basePort
        while taken.contains(port) || !canBind(port) { port += 2 }
        return port
    }

    private static func canBind(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // Emulators before 36.6 reject -crash-report-mode as unknown and exit, so ask the binary once per run.
    private static let hasCrashReportMode: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Settings.emulatorBinary)
        process.arguments = ["-help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.contains("-crash-report-mode")
    }()

    // The gRPC display list reports the panel size, but Camera activities turn the logical
    // display portrait. ADB taps use the logical size, which dumpsys reports as "real".
    static func logicalDisplaySize(serial: String) -> (width: Int, height: Int)? {
        let result = adb(["-s", serial, "shell", "dumpsys", "display"])
        guard result.status == 0 else { return nil }
        let lines = result.output.split(separator: "\n")
        guard let line = lines.last(where: { $0.contains("mOverrideDisplayInfo=") })
            ?? lines.last(where: { $0.contains("mBaseDisplayInfo=") }),
              let range = line.range(of: "real ") else { return nil }
        let parts = line[range.upperBound...].split(separator: " ")
        guard parts.count >= 3, let width = Int(parts[0]),
              let height = Int(parts[2].trimmingCharacters(in: CharacterSet(charactersIn: ","))) else { return nil }
        return (width, height)
    }
}
