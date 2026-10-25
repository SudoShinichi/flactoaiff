import CoreServices
import Foundation

/// Watches a folder tree for new FLACs and reports each one once it has finished being
/// written (non-empty, size and modification time unchanged for a poll, and at least 2 s
/// old). A writer that stalls longer than that is caught by Converter's length check, and
/// the file is handed off again once it changes. UI-free.
final class FolderWatcher {
    /// The watch folder with symlinks resolved (/var → /private/var), as FSEvents reports paths.
    let root: URL
    /// Ready files, on the watcher's queue. `quiet`: found by catch-up or a rescan rather than
    /// a live event, so an "Already converted" result isn't news.
    private let onReady: (_ files: [URL], _ quiet: Bool) -> Void
    private let queue = DispatchQueue(label: "local.flactoaiff.watcher")
    private let onQueue = DispatchSpecificKey<Void>()
    /// Set by stop() before it waits for the queue, so a long catch-up scan gives up early.
    private let cancelled = LockedFlag()

    // All below: watcher queue only (after start()).
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var startedAt = Date()
    private var polls = 0

    private struct Snapshot: Equatable {
        let size: Int64
        let modified: TimeInterval
        static let unseen = Snapshot(size: -1, modified: 0)
    }
    private var pending: [String: (snap: Snapshot, quiet: Bool, stablePolls: Int)] = [:]
    /// Files handed off, by file system ID: a rename or move inside the volume keeps the ID,
    /// so re-sorting converted albums doesn't convert them again. `path` is where it was last
    /// seen, for forgetting files that are gone.
    private struct FileID: Hashable { let device: Int32; let inode: UInt64 }
    private var handedOff: [FileID: (snap: Snapshot, path: String)] = [:]

    init(root: URL, onReady: @escaping (_ files: [URL], _ quiet: Bool) -> Void) {
        self.root = Self.resolve(root)
        self.onReady = onReady
        queue.setSpecific(key: onQueue, value: ())
    }

    deinit {
        // On the queue that runs the callback, so an FSEvents callback can't outlive self.
        if DispatchQueue.getSpecific(key: onQueue) != nil { shutDown() } else { queue.sync { shutDown() } }
    }

    /// `folder` with symlinks resolved; unchanged if it doesn't exist.
    static func resolve(_ folder: URL) -> URL {
        guard let p = realpath(folder.path, nil) else { return folder }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }

    /// Start watching. With `since`, FLACs that arrived after it (while nothing was watching)
    /// are picked up too. False if the folder doesn't exist or FSEvents refused it.
    func start(catchingUpSince since: Date? = nil) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return false }

        // passUnretained is safe: stop() and deinit invalidate the stream on the queue that
        // runs the callback, so no callback can outlive self.
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

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.poll() }

        queue.sync {
            stream = s
            timer = t
            startedAt = Date()
            t.resume()
        }
        if let since = since {
            queue.async { [self] in
                for file in arrivals(under: root, since: since) where !cancelled.isSet { track(file.path, quiet: true) }
            }
        }
        return true
    }

    /// After this returns, onReady is never called again.
    func stop() {
        cancelled.set()
        queue.sync { shutDown() }
    }

    // MARK: - On the watcher's queue

    private func shutDown() {
        stopped = true
        timer?.cancel(); timer = nil
        if let s = stream {
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
    }

    private func noticed(_ eventPath: String, flags: FSEventStreamEventFlags) {
        let path = eventPath.hasSuffix("/") ? String(eventPath.dropLast()) : eventPath
        let isRoot = path == root.path
        guard isRoot || (path.hasPrefix(root.path + "/") && !isIgnored(path)) else { return }

        // Events were coalesced or dropped: rescan, keeping only what arrived since we started.
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            for file in arrivals(under: URL(fileURLWithPath: path, isDirectory: true), since: startedAt) {
                track(file.path, quiet: true)
            }
            return
        }
        guard !isRoot else { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            // A folder moved or unzipped in: its FLACs produce no events of their own.
            let arrived = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)
            guard flags & arrived != 0 else { return }
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            // A package (an .app, Safari's .download) is one item, as in folder drops.
            guard (try? dir.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true else { return }
            for rel in Jobs.flacs(in: dir) { track(dir.appendingPathComponent(rel).path, quiet: false) }
        } else if (path as NSString).pathExtension.lowercased() == "flac" {
            track(path, quiet: false)
        }
    }

    private func track(_ path: String, quiet: Bool) {
        if pending[path] == nil { pending[path] = (.unseen, quiet, 0) }
    }

    /// FLACs under `dir` that arrived at or after `since`: the file's own Finder "Date Added",
    /// or that of a folder between it and `root` (a folder moved in keeps its files' old dates).
    /// Volumes without Date Added (exFAT, FAT) fall back to the creation date.
    private func arrivals(under dir: URL, since: Date) -> [URL] {
        Jobs.flacs(in: dir).map { dir.appendingPathComponent($0) }.filter { file in
            !cancelled.isSet && (Self.arrivalDate(of: file, under: root) ?? .distantPast) >= since
        }
    }

    /// When `file` arrived in the watch folder `root`: the newest Finder "Date Added" of the
    /// file and of the folders between it and `root` (a folder moved in keeps its files' old
    /// dates), never later than now. Volumes without Date Added (exFAT, FAT) use the creation date.
    static func arrivalDate(of file: URL, under root: URL) -> Date? {
        func added(_ url: URL) -> Date? {
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            return values?.addedToDirectoryDate ?? values?.creationDate
        }
        var newest = added(file)
        var folder = file.deletingLastPathComponent()
        while folder.path.hasPrefix(root.path + "/") {
            if let date = added(folder), date > newest ?? .distantPast { newest = date }
            folder = folder.deletingLastPathComponent()
        }
        return newest.map { min($0, Date()) }
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
        guard !stopped else { return }
        polls += 1
        if polls % 600 == 0 {   // every ~10 min, forget files that are gone, so this doesn't grow forever
            handedOff = handedOff.filter { FileManager.default.fileExists(atPath: $0.value.path) }
        }
        var ready: [URL] = [], readyQuiet: [URL] = []
        let now = Date().timeIntervalSince1970
        for (path, entry) in pending {
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { pending[path] = nil; continue }
            let snap = Snapshot(size: Int64(st.st_size),
                                modified: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
            let stable = snap == entry.snap ? entry.stablePolls + 1 : 0
            // A future mtime (a wrong clock on the copy's source, a NAS running ahead) can't
            // show the file's age, so it has to stay unchanged for three polls instead.
            let settled = now - snap.modified >= 2 ? stable >= 1 : snap.modified > now && stable >= 3
            // Empty: a placeholder (Firefox creates one, then renames the download over it).
            guard snap.size > 0, settled else {
                pending[path] = (snap, entry.quiet, stable); continue
            }
            pending[path] = nil
            // Already handed off (a repeated event, or the file was renamed or moved since):
            // just note where it is now.
            let id = FileID(device: st.st_dev, inode: st.st_ino)
            if handedOff[id]?.snap == snap { handedOff[id]?.path = path; continue }
            handedOff[id] = (snap, path)
            if entry.quiet { readyQuiet.append(URL(fileURLWithPath: path)) } else { ready.append(URL(fileURLWithPath: path)) }
        }
        func sorted(_ urls: [URL]) -> [URL] { urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }
        if !readyQuiet.isEmpty { onReady(sorted(readyQuiet), true) }
        if !ready.isEmpty { onReady(sorted(ready), false) }
    }
}

/// A Bool that any thread can set and read.
private final class LockedFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
