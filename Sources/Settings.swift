import Foundation

/// User choices that persist across launches.
final class Settings: ObservableObject {
    private enum Key {
        static let outputFolder = "outputFolder"
        static let mode = "outputMode"
        static let watchFolder = "watchFolder"
        static let watchedUntil = "watchedUntil"
    }
    private let defaults: UserDefaults

    @Published var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }
    @Published var mode: OutputMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }

    /// Folder whose new FLACs convert automatically; nil = not watching.
    /// Choosing one sets `watchedUntil` to now, so its existing FLACs are left alone.
    @Published var watchFolder: URL? {
        didSet {
            defaults.set(watchFolder?.path, forKey: Key.watchFolder)
            if watchFolder != nil { watchedUntil = Date() }
        }
    }
    /// Arrivals up to here have been seen; the launch catch-up starts here.
    var watchedUntil: Date {
        didSet { defaults.set(watchedUntil, forKey: Key.watchedUntil) }
    }

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outputFolder = defaults.string(forKey: Key.outputFolder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.downloads
        mode = defaults.string(forKey: Key.mode).flatMap(OutputMode.init(rawValue:)) ?? .original
        watchFolder = defaults.string(forKey: Key.watchFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        watchedUntil = defaults.object(forKey: Key.watchedUntil) as? Date ?? Date()
    }
}
