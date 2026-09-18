import AppKit

// Launched from Finder there is no terminal, so prints go to the log folder instead of nowhere.
if isatty(STDOUT_FILENO) == 0 {
    try? FileManager.default.createDirectory(atPath: AvdCatalog.logDir, withIntermediateDirectories: true)
    freopen(AvdCatalog.logDir + "/Avdpane.log", "a", stdout)
    dup2(STDOUT_FILENO, STDERR_FILENO)
}
// So log lines show up right away when stdout goes to a file.
setlinebuf(stdout)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = AppDelegate.shared
app.run()
