import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Headless CLI mode (used by test.sh)
//   --convert [--format original|max48|cd] <file-or-folder>... <outputDir>
//   --watch   [--format original|max48|cd] [--catch-up-since <unix-time>] <watchDir> <outputDir>   (until killed)

let cliArgs = CommandLine.arguments
func cliUsage() -> Never {
    FileHandle.standardError.write("""
        usage: FlacToAiff --convert [--format original|max48|cd] <file-or-folder>... <outputDir>
               FlacToAiff --watch [--format original|max48|cd] [--catch-up-since <unix-time>] <watchDir> <outputDir>

        """.data(using: .utf8)!)
    exit(2)
}

/// `OK`/`SKIP` to stdout, `ERROR` to stderr, flushed at once. Returns false for an ERROR.
func cliPrint(_ row: Row) -> Bool {
    switch row.kind {
    case .converted:        print("OK \(row.output!.path)\t\(row.checks ?? "")")
    case .alreadyConverted: print("SKIP \(row.output!.path)")
    case .skipped, .failed:
        FileHandle.standardError.write("ERROR \(row.name): \(row.detail)\n".data(using: .utf8)!)
    }
    fflush(stdout)
    return row.kind == .converted || row.kind == .alreadyConverted
}

/// Killed (Ctrl-C, kill): end the running afconvert and delete its temp file before exiting.
var cliSignalSources: [DispatchSourceSignal] = []
func cliStopOnSignals() {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { Converter.stopAll(); exit(128 + sig) }
        source.resume()
        cliSignalSources.append(source)
    }
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
    guard watching ? args.count == 2 : args.count >= 2 else { cliUsage() }
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

// MARK: - GUI

/// Whether the watch folder could be watched (main thread).
final class WatchState: ObservableObject {
    @Published var unavailable = false
}

struct DropView: View {
    @ObservedObject var queue: ConversionQueue
    @ObservedObject var settings: Settings
    @ObservedObject var watchState: WatchState
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 12) {
            dropZone
            settingsBar
            if !queue.rows.isEmpty && !queue.isWorking {
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(queue.outputs)
                    }
                    .disabled(queue.outputs.isEmpty)
                    Spacer()
                    Button("Clear") { queue.clear() }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 400)
    }

    private var settingsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Save to:").foregroundColor(.secondary)
                Button(action: chooseOutputFolder) {
                    HStack(spacing: 4) {
                        Text(settings.outputFolder.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .help(settings.outputFolder.path)
                Spacer()
            }
            HStack(spacing: 6) {
                Text("Watch:").foregroundColor(.secondary)
                Menu {
                    Button("Choose Folder…") {
                        if let url = pickFolder(startingAt: settings.watchFolder ?? Settings.downloads, prompt: "Watch") {
                            settings.watchFolder = url
                        }
                    }
                    if settings.watchFolder != nil {
                        Button("Stop Watching") { settings.watchFolder = nil }
                    }
                } label: {
                    Text(settings.watchFolder?.lastPathComponent ?? "Off")
                }
                .fixedSize()
                .help(settings.watchFolder?.path ?? "Convert new FLACs that land in a folder, while the app is open")
                if settings.watchFolder != nil && watchState.unavailable {
                    Text("Watch folder not available").font(.caption).foregroundColor(.red)
                }
                Spacer()
            }
            Picker("Format:", selection: $settings.mode) {
                ForEach(OutputMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text(settings.mode.explanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundColor(targeted ? .accentColor : Color.secondary.opacity(0.5))
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )

            if queue.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 44, weight: .light))
                    Text(queue.isWorking ? "Converting…" : "Drop .flac files or folders here")
                        .font(.headline)
                    Text("Converted .aiff files are saved to \(settings.outputFolder.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    if let watched = settings.watchFolder {
                        Text("Watching \(watched.lastPathComponent)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .foregroundColor(targeted ? .accentColor : .primary)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(queue.rows) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: row.kind.symbol)
                                    .foregroundColor(row.kind.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).font(.callout)
                                    Text(row.detail).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            handleDrop(providers)
        }
    }

    private func chooseOutputFolder() {
        if let url = pickFolder(startingAt: settings.outputFolder, prompt: "Save Here") {
            settings.outputFolder = url
        }
    }

    private func pickFolder(startingAt start: URL, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let u = url {
                    lock.lock(); urls.append(u); lock.unlock()
                }
            }
        }

        // Drops while a batch runs are queued behind it.
        group.notify(queue: .main) {
            self.queue.enqueue(urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
        return true
    }
}

/// Menu titles and explanations (wording from the spec's "Output formats" table). Player names are
/// examples whose limits come from the manufacturer's manuals, not a compatibility list.
extension OutputMode {
    var title: String {
        switch self {
        case .original: return "Original (lossless)"
        case .max48:    return "CDJ: max 24-bit / 48 kHz"
        case .cd:       return "CD: 16-bit / 44.1 kHz"
        }
    }

    var explanation: String {
        switch self {
        case .original:
            return "Same quality as the FLAC. For hi-res-capable players and software, such as the CDJ-3000, CDJ-2000NXS2 or Apple Music."
        case .max48:
            return "Lowers hi-res files to 48 kHz / 24-bit, for players limited to that, such as the CDJ-2000NXS. Check your player's manual."
        case .cd:
            return "Makes everything 16-bit / 44.1 kHz, the audio CD format, for burning CDs."
        }
    }
}

private extension Row.Kind {
    var symbol: String {
        switch self {
        case .converted:        return "checkmark.circle.fill"
        case .alreadyConverted: return "forward.end.circle.fill"
        case .skipped:          return "minus.circle.fill"
        case .failed:           return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .converted:                     return .green
        case .alreadyConverted, .skipped:    return .secondary
        case .failed:                        return .red
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let settings: Settings
    let queue: ConversionQueue
    private var watcher: FolderWatcher?
    private let watchState = WatchState()
    private var watchGeneration = 0   // batches from a replaced or stopped watcher are dropped
    private var watchSubscription: AnyCancellable?
    private var watchTimer: Timer?
    private var volumeObservers: [NSObjectProtocol] = []

    override init() {
        let settings = Settings()
        self.settings = settings
        queue = ConversionQueue(settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false   // AppDelegate holds a strong ref; avoid over-release
        window.title = "FLAC → AIFF"
        window.contentView = NSHostingView(rootView: DropView(queue: queue, settings: settings, watchState: watchState))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // At launch, also convert what landed in the watch folder while nothing was watching.
        watch(settings.watchFolder, catchingUpSince: catchUpStart)
        watchSubscription = settings.$watchFolder.dropFirst().sink { [weak self] folder in self?.watch(folder) }
        // Catch-up starts where watching stopped, so moved-away AIFFs aren't re-made every launch.
        // Recorded every minute too, in case the app doesn't quit cleanly.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.recordWatchedUntil()
            self?.followWatchFolder()
        }
        // A watch folder on a drive that mounts after launch, or is ejected and comes back.
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.followWatchFolder() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recordWatchedUntil()
        Converter.stopAll()   // don't leave afconvert writing a temp file onto the output drive
    }

    private var catchUpStart: Date { settings.watchedUntil.addingTimeInterval(-120) }

    private func recordWatchedUntil() {
        guard let watcher = watcher else { return }   // not watching: keep the date it stopped
        settings.watchedUntil = [Date(), queue.oldestUnfinishedWatched, watcher.oldestUnfinished].compactMap { $0 }.min()!
    }

    /// Start watching once the watch folder is there, stop while it's gone.
    private func followWatchFolder() {
        guard let folder = settings.watchFolder else { return }
        var isDir: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue
        if watcher == nil && there {
            watch(folder, catchingUpSince: catchUpStart)
        } else if watcher != nil && !there {
            recordWatchedUntil()   // the catch-up starts here when it's back
            watch(nil)
            watchState.unavailable = true
        }
    }

    /// (Re)start the watcher for `folder`; nil stops watching.
    private func watch(_ folder: URL?, catchingUpSince since: Date? = nil) {
        watcher?.stop()
        watcher = nil
        watchGeneration += 1
        queue.forgetWatched()
        watchState.unavailable = false
        guard let folder = folder else { return }
        let root = FolderWatcher.resolve(folder)
        let generation = watchGeneration
        let started = FolderWatcher(root: root) { [weak self] ready, quiet in
            DispatchQueue.main.async {
                guard let self = self, self.watchGeneration == generation else { return }
                self.queue.enqueueWatched(ready, root: root, quietSkips: quiet)
            }
        }
        // Not available: the settings bar says so, and followWatchFolder starts it once it is.
        if started.start(catchingUpSince: since) { watcher = started } else { watchState.unavailable = true }
    }

    /// Dock-icon drops and Finder "Open With". On a cold launch this can arrive before
    /// applicationDidFinishLaunching; the queue exists from init, so nothing is lost.
    func application(_ application: NSApplication, open urls: [URL]) {
        queue.enqueue(urls)
        // Show the rows for a Dock drop onto a minimized window (window is nil on a cold launch).
        if window?.isMiniaturized == true { window.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Quitting mid-batch leaves the remaining files unconverted, so ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard queue.isWorking else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while converting?"
        alert.informativeText = "The file being converted and those not yet converted are skipped. You can drop them again later — finished AIFFs are kept."
        alert.addButton(withTitle: "Keep Converting")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertSecondButtonReturn { return .terminateNow }
        window?.makeKeyAndOrderFront(nil)   // closing the window got us here: bring it back
        return .terminateCancel
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FLAC → AIFF",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FLAC → AIFF",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FLAC → AIFF",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Cut, copy and paste reach text fields (e.g. Go to Folder in the folder pickers) only
        // through menu key equivalents.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
