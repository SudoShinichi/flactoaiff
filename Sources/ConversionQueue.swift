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

    init(settings: Settings) { self.settings = settings }

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
                if quietSkips && row.kind == .alreadyConverted { continue }
                DispatchQueue.main.async { self.rows.append(row) }
            }
            DispatchQueue.main.async {
                self.batchesInFlight -= 1
                if self.batchesInFlight == 0 { self.isWorking = false }
            }
        }
    }

    func clear() {
        guard !isWorking else { return }
        rows = []
    }
}
