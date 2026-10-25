import Foundation

/// The app's single conversion pipeline. Window drops, Dock drops and Finder "Open With"
/// feed `enqueue`, the watch folder `enqueueWatched`; work runs serially off the main thread
/// and rows publish as they finish.
final class ConversionQueue: ObservableObject {
    @Published private(set) var rows: [Row] = []
    /// A watch folder can run for weeks: the window keeps the newest rows, not all of them.
    static let maxRows = 5000
    @Published private(set) var isWorking = false
    /// Conversions are queued or running (a USB check alone doesn't count): quitting loses work.
    @Published private(set) var isConverting = false

    private let settings: Settings
    private let worker = DispatchQueue(label: "local.flactoaiff.conversion", qos: .userInitiated)   // serial
    private var batchesInFlight = 0, conversionBatches = 0   // main thread only
    /// Watched FLACs still waiting to convert (main thread only): when each arrived, and how
    /// many of its jobs are queued (a file that changed after a hand-off is handed off again).
    /// Files that failed only because Save to was unavailable stay in here, to be tried again.
    private var unfinishedWatched: [URL: (arrived: Date, jobs: Int)] = [:]
    private var watchSession = 0   // main thread only; jobs from a forgotten session don't count

    init(settings: Settings) { self.settings = settings }

    /// The earliest arrival among watched FLACs not converted yet: the launch catch-up has to
    /// start no later than this, or files still queued at quit would never be tried again.
    var oldestUnfinishedWatched: Date? { unfinishedWatched.values.map(\.arrived).min() }

    /// AIFFs to select in Finder: converted and already-converted outputs.
    var outputs: [URL] { rows.compactMap(\.output) }

    /// Add files and/or folders (main thread). Settings are captured now, so changing
    /// them mid-batch affects the next drop, not files already queued.
    func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        submit { root in Jobs.expand(urls, into: root) }
    }

    /// FLACs from the watch folder (main thread). `quietSkips`: launch catch-up doesn't
    /// list files that were converted before.
    func enqueueWatched(_ files: [FolderWatcher.Ready], root watchRoot: URL, quietSkips: Bool = false) {
        guard !files.isEmpty else { return }
        for f in files {
            // The date catch-up tests, so watchedUntil can't move past what it would find.
            let entry = unfinishedWatched[f.file]
            unfinishedWatched[f.file] = (min(entry?.arrived ?? f.arrived, f.arrived), (entry?.jobs ?? 0) + 1)
        }
        let urls = files.map(\.file)
        submit(quietSkips: quietSkips, watchSession: watchSession) { root in Jobs.watched(urls, root: watchRoot, into: root) }
    }

    private func submit(quietSkips: Bool = false, watchSession session: Int? = nil, _ makeItems: @escaping (URL) -> [WorkItem]) {
        let root = settings.outputFolder
        let options = settings.convertOptions
        batchesInFlight += 1
        conversionBatches += 1
        isWorking = true
        isConverting = true
        worker.async {
            for item in makeItems(root) {
                let row = autoreleasepool { Jobs.run(item, outputRoot: root, options: options) }   // free each file's temporaries before the next
                if let session = session, case .job(let job) = item, !row.retryable {
                    DispatchQueue.main.async { if session == self.watchSession { self.finishedWatched(job.source) } }
                }
                if quietSkips && row.kind == .alreadyConverted { continue }
                DispatchQueue.main.async { self.append([row]) }
            }
            DispatchQueue.main.async {
                self.conversionBatches -= 1
                if self.conversionBatches == 0 { self.isConverting = false }
                self.batchFinished()
            }
        }
    }

    /// Check a stick (or folder) for tracks `player` won't play. Read-only; queued like a drop.
    func check(_ folder: URL, for player: Player) {
        batchesInFlight += 1
        isWorking = true
        worker.async {
            let rows = USBCheck.run(folder, on: player)
            DispatchQueue.main.async { self.append(rows); self.batchFinished() }
        }
    }

    private func append(_ new: [Row]) {
        rows += new
        if rows.count > Self.maxRows { rows.removeFirst(rows.count - Self.maxRows) }
    }

    private func batchFinished() {
        batchesInFlight -= 1
        if batchesInFlight == 0 { isWorking = false }
    }

    private func finishedWatched(_ file: URL) {
        guard let entry = unfinishedWatched[file] else { return }
        unfinishedWatched[file] = entry.jobs > 1 ? (entry.arrived, entry.jobs - 1) : nil
    }

    /// The watch folder changed or watching stopped: its files no longer hold catch-up back.
    func forgetWatched() {
        unfinishedWatched = [:]
        watchSession += 1
    }

    func clear() {
        guard !isWorking else { return }
        rows = []
    }
}
