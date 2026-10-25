import Foundation

/// The app's single conversion pipeline. Window drops, Dock drops and Finder "Open With"
/// feed `enqueue`, the watch folder `enqueueWatched`; work runs serially off the main thread
/// and rows publish as they finish.
final class ConversionQueue: ObservableObject {
    @Published private(set) var rows: [Row] = []
    @Published private(set) var isWorking = false

    private let settings: Settings
    private let worker = DispatchQueue(label: "local.flactoaiff.conversion", qos: .userInitiated)   // serial
    private var batchesInFlight = 0   // main thread only
    /// When each watched FLAC still waiting to convert arrived (main thread only). Files that
    /// failed only because Save to was unavailable stay in here too, to be tried again.
    private var unfinishedWatched: [URL: Date] = [:]

    init(settings: Settings) { self.settings = settings }

    /// The earliest arrival among watched FLACs not converted yet: the launch catch-up has to
    /// start no later than this, or files still queued at quit would never be tried again.
    var oldestUnfinishedWatched: Date? { unfinishedWatched.values.min() }

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
    func enqueueWatched(_ files: [URL], root watchRoot: URL, quietSkips: Bool = false) {
        guard !files.isEmpty else { return }
        for file in files where unfinishedWatched[file] == nil {
            // The date catch-up tests, so watchedUntil can't fall back past what it would find.
            unfinishedWatched[file] = FolderWatcher.arrivalDate(of: file, under: watchRoot) ?? Date()
        }
        submit(quietSkips: quietSkips) { root in Jobs.watched(files, root: watchRoot, into: root) }
    }

    private func submit(quietSkips: Bool = false, _ makeItems: @escaping (URL) -> [WorkItem]) {
        let root = settings.outputFolder
        let options = ConvertOptions(mode: settings.mode)
        batchesInFlight += 1
        isWorking = true
        worker.async {
            for item in makeItems(root) {
                let row = autoreleasepool { Jobs.run(item, outputRoot: root, options: options) }   // free each file's temporaries before the next
                if case .job(let job) = item {
                    let retry = row.kind == .failed && row.detail == ConvertError.outputFolderUnavailable.description
                    DispatchQueue.main.async { if !retry { self.unfinishedWatched[job.source] = nil } }
                }
                if quietSkips && row.kind == .alreadyConverted { continue }
                DispatchQueue.main.async { self.rows.append(row) }
            }
            DispatchQueue.main.async {
                self.batchesInFlight -= 1
                if self.batchesInFlight == 0 { self.isWorking = false }
            }
        }
    }

    /// The watch folder changed or watching stopped: its files no longer hold catch-up back.
    func forgetWatched() { unfinishedWatched = [:] }

    func clear() {
        guard !isWorking else { return }
        rows = []
    }
}
