import Foundation

/// The app's single conversion pipeline. Window drops, Dock drops and Finder "Open With"
/// feed `enqueue`, the watch folder `enqueueWatched`. Batches run one after another off the main
/// thread; within a batch, a few files convert at once when Save to is on the Mac's own drive
/// (see `lanes`). Rows publish as they finish.
final class ConversionQueue: ObservableObject {
    @Published private(set) var rows: [Row] = []
    /// A watch folder can run for weeks: the window keeps the newest rows, not all of them.
    static let maxRows = 5000
    @Published private(set) var isWorking = false
    /// Conversions are queued or running (a USB check alone doesn't count): quitting loses work.
    @Published private(set) var isConverting = false

    private let settings: Settings
    private let worker = DispatchQueue(label: "local.flactoaiff.conversion", qos: .userInitiated)   // serial
    /// USB checks only read, so they run beside conversions instead of waiting behind them.
    private let checker = DispatchQueue(label: "local.flactoaiff.usb-check", qos: .userInitiated)
    private var batchesInFlight = 0, conversionBatches = 0   // main thread only
    /// Watched files still waiting to convert (main thread only): when each arrived, and how
    /// many of its jobs are queued (a file that changed after a hand-off is handed off again).
    /// Files that failed only because Save to was unavailable stay in here with their watch
    /// folder, `retryRoot`, to be tried again when Save to is back or at the next launch.
    private var unfinishedWatched: [URL: (arrived: Date, jobs: Int, retryRoot: URL?)] = [:]
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
            unfinishedWatched[f.file] = (min(entry?.arrived ?? f.arrived, f.arrived), (entry?.jobs ?? 0) + 1, entry?.retryRoot)
        }
        let urls = files.map(\.file)
        submit(quietSkips: quietSkips, watchSession: watchSession, watchRoot: watchRoot) { root in
            Jobs.watched(urls, root: watchRoot, into: root)
        }
    }

    /// Save to may be back (a drive mounted, another folder chosen): try the watched files that
    /// failed because it was missing (main thread). Nothing happens while it's still missing.
    func retryUnavailable() {
        settings.followMovedFolders()
        var isDir: ObjCBool = false
        let root = settings.outputFolder
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              FileManager.default.isWritableFile(atPath: root.path) else { return }
        let waiting = unfinishedWatched.filter { $0.value.jobs == 0 && $0.value.retryRoot != nil }
        for (watchRoot, files) in Dictionary(grouping: waiting, by: { $0.value.retryRoot! }) {
            let ready = files.map { FolderWatcher.Ready(file: $0.key, arrived: $0.value.arrived) }
            enqueueWatched(ready.sorted { $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending }, root: watchRoot)
        }
    }

    private func submit(quietSkips: Bool = false, watchSession session: Int? = nil, watchRoot: URL? = nil,
                        _ makeItems: @escaping (URL) -> [WorkItem]) {
        settings.followMovedFolders()   // Save to renamed since: save where it is now
        let root = settings.outputFolder
        let options = ConvertOptions(mode: settings.format)
        batchesInFlight += 1
        conversionBatches += 1
        isWorking = true
        isConverting = true
        worker.async {
            // Files that would get the same AIFF share a lane, so they still run in their order.
            let lanes = Self.lanes(for: root)
            var byLane = [[WorkItem]](repeating: [], count: lanes)
            for item in makeItems(root) { byLane[Self.lane(of: item, among: lanes)].append(item) }
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                for item in byLane[lane] {
                    let row = autoreleasepool { Jobs.run(item, outputRoot: root, options: options) }   // free each file's temporaries before the next
                    if let session = session, case .job(let job) = item {
                        let retryRoot = row.retryable ? watchRoot : nil
                        DispatchQueue.main.async { if session == self.watchSession { self.finishedWatched(job.source, retryRoot: retryRoot) } }
                    }
                    if quietSkips && row.kind == .alreadyConverted { continue }
                    if session != nil && row.routine { continue }   // an AAC download in the watch folder
                    DispatchQueue.main.async { self.append([row]) }
                }
            }
            DispatchQueue.main.async {
                self.conversionBatches -= 1
                if self.conversionBatches == 0 { self.isConverting = false }
                self.batchFinished()
            }
        }
    }

    /// How many files of a batch convert at once. afconvert uses one core, so a few at once on
    /// the Mac's own drive; one at a time on USB sticks, external drives and network shares,
    /// which get slower with several writers.
    static func lanes(for root: URL) -> Int {
        let volume = try? root.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
        guard volume?.volumeIsInternal == true, volume?.volumeIsLocal == true else { return 1 }
        return min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// A job's lane: from its AIFF's path, so two sources that would share a name (x.flac and
    /// x.wav) always share a lane. Notes go to the first.
    private static func lane(of item: WorkItem, among lanes: Int) -> Int {
        guard lanes > 1, case .job(let job) = item else { return 0 }
        let aiff = job.destDir.standardizedFileURL.path + "/" + job.source.deletingPathExtension().lastPathComponent.lowercased()
        return Int(UInt(bitPattern: aiff.hashValue) % UInt(lanes))
    }

    /// Check a stick (or folder) for tracks `player` won't play. Read-only; queued like a drop.
    func check(_ folder: URL, for player: Player) {
        batchesInFlight += 1
        isWorking = true
        checker.async {
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

    /// One job for a watched file is done. `retryRoot`: it failed because Save to was missing,
    /// so the file stays, to be tried again from that watch folder.
    private func finishedWatched(_ file: URL, retryRoot: URL?) {
        guard let entry = unfinishedWatched[file] else { return }
        let jobs = entry.jobs - 1
        if let retryRoot {
            unfinishedWatched[file] = (entry.arrived, jobs, retryRoot)
        } else {
            unfinishedWatched[file] = jobs > 0 ? (entry.arrived, jobs, entry.retryRoot) : nil
        }
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
