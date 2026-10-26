import AppKit

// Entry point: a command-line mode (CLI.swift) when asked for one, else the app.

let cliArgs = CommandLine.arguments

#if TEST_HOOKS
if cliArgs.count == 4 && cliArgs[1] == "--selftest" {
    exit(SelfTest.run(flac: URL(fileURLWithPath: cliArgs[2]), aac: URL(fileURLWithPath: cliArgs[3])) ? 0 : 1)
}
if cliArgs.count == 2 && cliArgs[1] == "--ideal-widths" {
    print(SelfTest.idealWidths().map { String(Int($0.rounded(.up))) }.joined(separator: " ")); exit(0)
}
#endif

if cliArgs.count >= 2 && cliArgs[1] == "--check" {
    // --check --player <name> <folder>: exit 1 when the player can't read the stick or a track.
    let args = Array(cliArgs.dropFirst(2))
    guard args.count == 3, args[0] == "--player", let player = Player.named(args[1]) else { cliUsage() }
    var failed = false
    for row in USBCheck.run(URL(fileURLWithPath: args[2], isDirectory: true), on: player) where !cliPrint(row) { failed = true }
    exit(failed ? 1 : 0)
}

if cliArgs.count >= 2 && (cliArgs[1] == "--convert" || cliArgs[1] == "--watch") {
    cliStopOnSignals()
    let watching = cliArgs[1] == "--watch"
    var args = Array(cliArgs.dropFirst(2))
    var options = ConvertOptions()
    if args.first == "--format" {
        guard args.count >= 2, let mode = OutputMode(rawValue: args[1]) else { cliUsage() }
        options.mode = mode
        args.removeFirst(2)
    }
    var catchUpSince: Date?   // --watch only; for tests of the launch catch-up
    if watching && args.first == "--catch-up-since" {
        guard args.count >= 2, let seconds = TimeInterval(args[1]) else { cliUsage() }
        catchUpSince = Date(timeIntervalSince1970: seconds)
        args.removeFirst(2)
    }
    guard watching ? args.count == 2 : args.count >= 2, !(args.first?.hasPrefix("--") ?? false) else { cliUsage() }   // an unknown option
    let outputRoot = URL(fileURLWithPath: args.removeLast(), isDirectory: true)
    try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

    if watching {
        let converter = DispatchQueue(label: "local.flactoaiff.cli-watch")   // serial, off the watcher's queue
        let watchRoot = FolderWatcher.resolve(URL(fileURLWithPath: args[0], isDirectory: true))
        let watcher = FolderWatcher(root: watchRoot) { ready, _ in
            converter.async {
                for item in Jobs.watched(ready.map(\.file), root: watchRoot, into: outputRoot) {
                    _ = autoreleasepool { cliPrint(Jobs.run(item, outputRoot: outputRoot, options: options)) }
                }
            }
        }
        guard watcher.start(catchingUpSince: catchUpSince) else {
            FileHandle.standardError.write("ERROR \(args[0]): not a folder that can be watched\n".data(using: .utf8)!)
            exit(1)
        }
        FileHandle.standardError.write("WATCHING \(watchRoot.path)\n".data(using: .utf8)!)   // ready: tests wait for this
        dispatchMain()
    }

    var failed = false
    for item in Jobs.expand(args.map { URL(fileURLWithPath: $0) }, into: outputRoot) {
        if !autoreleasepool(invoking: { cliPrint(Jobs.run(item, outputRoot: outputRoot, options: options)) }) { failed = true }
    }
    exit(failed ? 1 : 0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
