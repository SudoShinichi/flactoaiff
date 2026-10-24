import Foundation

/// User choices that persist across launches.
final class Settings: ObservableObject {
    private enum Key {
        static let outputFolder = "outputFolder"
        static let mode = "outputMode"
    }
    private let defaults: UserDefaults

    @Published var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }
    @Published var mode: OutputMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
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
    }
}
