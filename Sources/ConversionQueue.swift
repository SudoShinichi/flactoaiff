import Foundation

/// The app's single conversion pipeline. Window drops, Dock drops and Finder "Open With"
/// all feed `enqueue`; work runs serially off the main thread and rows publish as they finish.
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
        let root = settings.outputFolder
        let options = ConvertOptions(mode: settings.mode)
        batchesInFlight += 1
        isWorking = true
        worker.async {
            for item in Jobs.expand(urls, into: root) {
                let row = Jobs.run(item, outputRoot: root, options: options)
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
