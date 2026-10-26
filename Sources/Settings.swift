import Foundation

/// User choices that persist across launches.
final class Settings: ObservableObject {
    private enum Key {
        static let outputFolder = "outputFolder"
        static let format = "format"
        // Older versions' choices, read once to carry them over: the first Format menu, then
        // the Player menu (a player name, or "original" / "cd").
        static let firstFormat = "outputMode"
        static let player = "player"
        static let watchFolder = "watchFolder"
        static let watchedUntil = "watchedUntil"
        // Bookmarks find a folder again after it (or its drive) is renamed or moved; the path
        // is kept beside them for drives that aren't connected.
        static let outputBookmark = "outputFolderBookmark"
        static let watchBookmark = "watchFolderBookmark"
    }
    private let defaults: UserDefaults

    @Published var outputFolder: URL {
        didSet { store(outputFolder, Key.outputFolder, Key.outputBookmark) }
    }
    @Published var format: OutputMode {
        didSet { defaults.set(format.rawValue, forKey: Key.format) }
    }

    /// Folder whose new files convert automatically; nil = not watching.
    /// Choosing one sets `watchedUntil` to now, so its existing files are left alone.
    @Published var watchFolder: URL? {
        didSet {
            store(watchFolder, Key.watchFolder, Key.watchBookmark)
            if watchFolder != nil && !followingMove { watchedUntil = Date() }
        }
    }
    /// True while `followMovedFolders` updates a folder's path: it's the same folder, so the
    /// watch folder's history stays and nothing starts over (main thread).
    private(set) var followingMove = false
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
        let fromPlayerMenu = defaults.string(forKey: Key.player).flatMap { id in
            OutputMode(rawValue: id) ?? Player.named(id)?.format   // "original" and "cd" are format names too
        }
        format = defaults.string(forKey: Key.format).flatMap(OutputMode.init(rawValue:)) ?? fromPlayerMenu
            ?? defaults.string(forKey: Key.firstFormat).flatMap(OutputMode.init(rawValue:)) ?? .original
        watchFolder = defaults.string(forKey: Key.watchFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        watchedUntil = defaults.object(forKey: Key.watchedUntil) as? Date ?? Date()
        // Settings from before bookmarks: make them now, while the folders are where the paths say.
        if defaults.data(forKey: Key.outputBookmark) == nil { store(outputFolder, Key.outputFolder, Key.outputBookmark) }
        if defaults.data(forKey: Key.watchBookmark) == nil { store(watchFolder, Key.watchFolder, Key.watchBookmark) }
        followMovedFolders()
    }

    /// Find Save to and the watch folder again if they, or their drive, were renamed or moved,
    /// and update their paths. A folder that can't be found (a drive not connected) keeps its
    /// path. Call at launch, when drives mount, and before using the folders.
    func followMovedFolders() {
        followingMove = true
        defer { followingMove = false }
        if let url = Self.resolve(defaults.data(forKey: Key.outputBookmark)), url.path != outputFolder.path {
            outputFolder = url
        }
        if watchFolder != nil, let url = Self.resolve(defaults.data(forKey: Key.watchBookmark)), url.path != watchFolder?.path {
            watchFolder = url
        }
    }

    /// Path and bookmark of `url`. A folder that isn't there can't be bookmarked: then the old
    /// bookmark goes, as it points elsewhere.
    private func store(_ url: URL?, _ pathKey: String, _ bookmarkKey: String) {
        defaults.set(url?.path, forKey: pathKey)
        defaults.set(url.flatMap { try? $0.bookmarkData() }, forKey: bookmarkKey)
    }

    private static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
