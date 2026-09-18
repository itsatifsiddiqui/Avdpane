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
                hasUi: !cmdline.contains("\"-no-window\""))
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
}
