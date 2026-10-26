import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let settings: Settings
    let queue: ConversionQueue
    private var watcher: FolderWatcher?
    private let watchState = WatchState()
    private var watchGeneration = 0   // batches from a replaced or stopped watcher are dropped
    private var watchSubscription: AnyCancellable?
    private var outputSubscription: AnyCancellable?
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
        // A folder chosen anew starts fresh; one found again after a rename is followed by followWatchFolder.
        watchSubscription = settings.$watchFolder.dropFirst().sink { [weak self] folder in
            guard let self, !self.settings.followingMove else { return }
            self.watch(folder)
        }
        // Catch-up starts where watching stopped, so moved-away AIFFs aren't re-made every launch.
        // Recorded every minute too, in case the app doesn't quit cleanly.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.recordWatchedUntil()
            self?.settings.followMovedFolders()
            self?.followWatchFolder()
            self?.queue.retryUnavailable()
        }
        // A watch folder on a drive that mounts after launch, or is ejected and comes back.
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                self?.settings.followMovedFolders()   // a stick that came back under a new name
                self?.followWatchFolder()
                self?.queue.retryUnavailable()   // Save to's drive may be the one that came back
            }
        }
        outputSubscription = settings.$outputFolder.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.queue.retryUnavailable()
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
        if let watcher, there, watcher.root.path != FolderWatcher.resolve(folder).path {
            recordWatchedUntil()   // renamed or moved: start again where it is, catching up from here
            watch(nil)
        }
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
        guard queue.isConverting else { return .terminateNow }   // a USB check only reads: nothing to lose
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
