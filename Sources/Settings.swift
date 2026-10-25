import Foundation

/// User choices that persist across launches.
final class Settings: ObservableObject {
    private enum Key {
        static let outputFolder = "outputFolder"
        static let mode = "outputMode"   // before the Player menu; read once to carry it over
        static let player = "player"
        static let skipPlayable = "skipPlayable"
        static let watchFolder = "watchFolder"
        static let watchedUntil = "watchedUntil"
    }
    private let defaults: UserDefaults

    @Published var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }
    @Published var player: Player {
        didSet { defaults.set(player.id, forKey: Key.player) }
    }
    /// Leave alone files the chosen player plays as they are.
    @Published var skipPlayable: Bool {
        didSet { defaults.set(skipPlayable, forKey: Key.skipPlayable) }
    }

    /// What the current choices mean for a conversion.
    var convertOptions: ConvertOptions {
        ConvertOptions(mode: player.mode, skipPlayableOn: skipPlayable && !player.plays.isEmpty ? player : nil)
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
        // The old Format setting: max48 was the "CDJ" choice, for CDJ-2000NXS-class players.
        let oldMode = ["original": Player.original, "max48": Player.named("cdj-2000nxs"), "cd": Player.cd]
        player = defaults.string(forKey: Key.player).flatMap(Player.named)
            ?? defaults.string(forKey: Key.mode).flatMap { oldMode[$0] ?? nil } ?? .original
        skipPlayable = defaults.bool(forKey: Key.skipPlayable)
        watchFolder = defaults.string(forKey: Key.watchFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        watchedUntil = defaults.object(forKey: Key.watchedUntil) as? Date ?? Date()
    }
}
