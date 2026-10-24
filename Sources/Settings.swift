import Foundation

/// User choices that persist across launches.
final class Settings: ObservableObject {
    private enum Key {
        static let outputFolder = "outputFolder"
        static let mode = "outputMode"
        static let watchFolder = "watchFolder"
        static let watchSince = "watchSince"
    }
    private let defaults: UserDefaults

    @Published var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }
    @Published var mode: OutputMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }

    /// Folder whose new FLACs convert automatically; nil = not watching.
    /// Choosing one restarts `watchSince`, so its existing FLACs are left alone.
    @Published var watchFolder: URL? {
        didSet {
            defaults.set(watchFolder?.path, forKey: Key.watchFolder)
            if watchFolder != nil { watchSince = Date() }
        }
    }
    /// When watching started: FLACs added after this are caught up at launch.
    private(set) var watchSince: Date {
        didSet { defaults.set(watchSince, forKey: Key.watchSince) }
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
        watchSince = defaults.object(forKey: Key.watchSince) as? Date ?? Date()
    }
}
