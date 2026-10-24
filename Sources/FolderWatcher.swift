import CoreServices
import Foundation

/// Watches a folder tree for new FLACs and reports each one once it has finished being
/// written (size and modification time unchanged for a poll, and at least 2 s old), so a
/// download or unzip in progress is never converted. UI-free.
final class FolderWatcher {
    /// The watch folder with symlinks resolved (/var → /private/var), as FSEvents reports paths.
    let root: URL
    private let onReady: ([URL]) -> Void   // called on the watcher's queue
    private let queue = DispatchQueue(label: "local.flactoaiff.watcher")
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?

    private struct Snapshot: Equatable {
        let size: Int64
        let modified: TimeInterval
        static let unseen = Snapshot(size: -1, modified: 0)
    }
    private var pending: [String: Snapshot] = [:]     // queue only
    private var handedOff: [String: Snapshot] = [:]   // queue only

    init(root: URL, onReady: @escaping ([URL]) -> Void) {
        self.root = Self.resolve(root)
        self.onReady = onReady
    }

    /// `folder` with symlinks resolved; unchanged if it doesn't exist.
    static func resolve(_ folder: URL) -> URL {
        guard let p = realpath(folder.path, nil) else { return folder }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }

    deinit { stop() }

    /// False if the folder doesn't exist or FSEvents refused it.
    func start() -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return false }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            for i in 0..<min(count, list.count) { watcher.noticed(list[i], flags: flags[i]) }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        guard let s = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                          FSEventStreamCreateFlags(flags)) else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); return false }
        stream = s

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        return true
    }

    func stop() {
        timer?.cancel(); timer = nil
        if let s = stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
    }

    /// FLACs under `root` whose Finder "Date Added" is on or after `since`: what arrived
    /// while the app was quit.
    static func catchUp(root: URL, since: Date) -> [URL] {
        Jobs.flacs(in: root)
            .map { root.appendingPathComponent($0) }
            .filter { url in
                guard let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
                else { return false }
                return added >= since
            }
    }

    // MARK: - On the watcher's queue

    private func noticed(_ path: String, flags: FSEventStreamEventFlags) {
        guard path.hasPrefix(root.path + "/"), !isIgnored(path) else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            // A folder moved or unzipped in: its FLACs produce no events of their own.
            let arrived = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
            guard flags & arrived != 0 else { return }
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            for rel in Jobs.flacs(in: dir) { track(dir.appendingPathComponent(rel).path) }
        } else if (path as NSString).pathExtension.lowercased() == "flac" {
            track(path)
        }
    }

    private func track(_ path: String) {
        if pending[path] == nil { pending[path] = .unseen }
    }

    /// Hidden components, or a package (e.g. an .app) anywhere between `root` and `path`.
    private func isIgnored(_ path: String) -> Bool {
        let rel = path.dropFirst(root.path.count + 1).split(separator: "/")
        if rel.contains(where: { $0.hasPrefix(".") }) { return true }
        var dir = root
        for component in rel.dropLast() {
            dir.appendPathComponent(String(component), isDirectory: true)
            if (try? dir.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return true }
        }
        return false
    }

    private func poll() {
        var ready: [URL] = []
        let now = Date().timeIntervalSince1970
        for (path, previous) in pending {
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { pending[path] = nil; continue }
            let snap = Snapshot(size: Int64(st.st_size),
                                modified: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
            guard snap == previous, now - snap.modified >= 2 else { pending[path] = snap; continue }
            pending[path] = nil
            guard handedOff[path] != snap else { continue }   // a repeated event for a file already handed off
            handedOff[path] = snap
            ready.append(URL(fileURLWithPath: path))
        }
        if !ready.isEmpty {
            onReady(ready.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
        }
    }
}
