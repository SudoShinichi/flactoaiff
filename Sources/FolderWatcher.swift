import CoreServices
import Foundation

/// Watches a folder tree for FLACs that arrive after `start` (or after the catch-up date) and
/// reports each one once it has finished being written: non-empty, size and modification
/// time unchanged for a poll, and at least 2 s old (30 s when its header doesn't record its
/// length, so a paused writer can't be caught mid-file). A writer that stalls longer than
/// that is caught by Converter's length check, and the file is handed off again once it
/// changes. FLACs that were already there are left alone, whatever happens to them. UI-free.
final class FolderWatcher {
    /// A finished FLAC, and when it arrived (see arrivalDate).
    struct Ready {
        let file: URL
        let arrived: Date
    }

    /// The watch folder with symlinks resolved (/var → /private/var), as FSEvents reports paths.
    let root: URL
    /// Ready files, on the watcher's queue. `quiet`: found by catch-up or a rescan rather than
    /// a live event, so an "Already converted" result isn't news.
    private let onReady: (_ files: [Ready], _ quiet: Bool) -> Void
    private let queue = DispatchQueue(label: "local.flactoaiff.watcher")
    private let onQueue = DispatchSpecificKey<Void>()
    /// Set by stop() before it waits for the queue, so a long scan gives up early.
    private let cancelled = Locked(false)
    private let oldest = Locked<Date?>(nil)

    // All below: watcher queue only (after start()).
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    /// Files that arrived before this were already in the folder.
    private var cutoff = Date()
    /// Until the first scan finishes, a FLAC from before the cutoff may not be known yet.
    private var scanning = false
    /// The FLACs that were already in the folder, by file system ID: moving one into a
    /// subfolder resets its Date Added, but not its ID.
    private var preexisting = Set<FileID>()
    private var polls = 0

    private struct Snapshot: Equatable {
        let size: Int64
        let modified: TimeInterval
        static let unseen = Snapshot(size: -1, modified: 0)
    }
    private var pending: [String: (snap: Snapshot, quiet: Bool, stablePolls: Int, arrived: Date)] = [:]
    /// Arrival dates of the files handed off by the last poll: they hold `oldestUnfinished`
    /// back until the receiver has surely queued them.
    private var justHandedOff: [Date] = []
    /// Files handed off, by file system ID: a rename or move inside the volume keeps the ID,
    /// so re-sorting converted albums doesn't convert them again. `path` is where it was last
    /// seen, for forgetting files that are gone.
    private struct FileID: Hashable { let device: Int32; let inode: UInt64 }
    private var handedOff: [FileID: (snap: Snapshot, path: String)] = [:]

    init(root: URL, onReady: @escaping (_ files: [Ready], _ quiet: Bool) -> Void) {
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
            cutoff = min(since ?? .distantFuture, Date())
            scanning = true
            publishOldest()
            t.resume()
        }
        // Note what was already there, and catch up on what arrived since `since`. Events
        // queue up behind this, so they see the finished list.
        queue.async { [self] in
            for rel in Jobs.flacs(in: root, isCancelled: { self.cancelled.value }) {
                let file = root.appendingPathComponent(rel)
                if let arrived = Self.arrivalDate(of: file, under: root), arrived >= cutoff {
                    track(file.path, quiet: true, arrived: arrived)
                } else if let id = Self.fileID(file.path) {
                    preexisting.insert(id)
                }
            }
            scanning = false
            publishOldest()
        }
        return true
    }

    /// After this returns, onReady is never called again.
    func stop() {
        cancelled.value = true
        queue.sync { shutDown() }
    }

    /// The earliest arrival among FLACs found but not handed off yet (still being written, or
    /// not yet found by a running catch-up): watchedUntil must not pass it. Any thread.
    var oldestUnfinished: Date? { oldest.value }

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

        // Events were coalesced or dropped: rescan, keeping only what arrived since the cutoff.
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            for (file, arrived) in arrivals(under: URL(fileURLWithPath: path, isDirectory: true)) {
                track(file.path, quiet: true, arrived: arrived)
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
            for (file, arrived) in arrivals(under: dir) { track(file.path, quiet: false, arrived: arrived) }
        } else if (path as NSString).pathExtension.lowercased() == "flac", pending[path] == nil,
                  let arrived = arrival(of: URL(fileURLWithPath: path)) {
            track(path, quiet: false, arrived: arrived)
        }
    }

    /// When `file` arrived, or nil if it was already in the folder before the cutoff: a tag,
    /// permission or name change, or a move inside the folder, doesn't make it new.
    private func arrival(of file: URL) -> Date? {
        guard let id = Self.fileID(file.path), !preexisting.contains(id),
              let arrived = Self.arrivalDate(of: file, under: root), arrived >= cutoff else { return nil }
        return arrived
    }

    private static func fileID(_ path: String) -> FileID? {
        var st = stat()
        return stat(path, &st) == 0 ? FileID(device: st.st_dev, inode: st.st_ino) : nil
    }

    private func track(_ path: String, quiet: Bool, arrived: Date) {
        if pending[path] == nil { pending[path] = (.unseen, quiet, 0, arrived) }
    }

    /// FLACs under `dir` that arrived since the cutoff, with their arrival dates.
    private func arrivals(under dir: URL) -> [(URL, Date)] {
        Jobs.flacs(in: dir, isCancelled: { self.cancelled.value }).compactMap { rel in
            let file = dir.appendingPathComponent(rel)
            return arrival(of: file).map { (file, $0) }
        }
    }

    /// When `file` arrived in the watch folder `root`: the newest of its Finder "Date Added",
    /// its last modification (a download renamed into place at the end keeps the Date Added
    /// of its start), and the Date Added of the folders between it and `root` (a folder moved
    /// in keeps its files' old dates). Never later than now. Volumes without Date Added (exFAT,
    /// FAT) use the creation date.
    static func arrivalDate(of file: URL, under root: URL) -> Date? {
        func added(_ url: URL) -> Date? {
            let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            return values?.addedToDirectoryDate ?? values?.creationDate
        }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var newest = [added(file), modified].compactMap { $0 }.max()
        var folder = file.deletingLastPathComponent()
        while folder.path.hasPrefix(root.path + "/") {
            if let date = added(folder), date > newest ?? .distantPast { newest = date }
            folder = folder.deletingLastPathComponent()
        }
        return newest.map { min($0, Date()) }
    }

    private func publishOldest() {
        oldest.value = ([scanning ? cutoff : nil] + pending.values.map(\.arrived) + justHandedOff).compactMap { $0 }.min()
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
        var ready: [Ready] = [], readyQuiet: [Ready] = []
        justHandedOff = []
        let now = Date().timeIntervalSince1970
        for (path, entry) in pending {
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { pending[path] = nil; continue }
            let snap = Snapshot(size: Int64(st.st_size),
                                modified: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
            let stable = snap == entry.snap ? entry.stablePolls + 1 : 0
            // Without a length in its header, a FLAC cut short by a paused writer passes every
            // check, so it has to sit still for longer.
            let quietTime: TimeInterval = stable >= 1 && (TagIO.flacStreamInfo(URL(fileURLWithPath: path))?.samples ?? 0) == 0
                ? Self.settleTimeWithoutLength : 2
            // A future mtime (a wrong clock on the copy's source, a NAS running ahead) can't
            // show the file's age, so it has to stay unchanged for that many polls instead.
            let settled = now - snap.modified >= quietTime ? stable >= 1 : snap.modified > now && stable > Int(quietTime)
            // Empty: a placeholder (Firefox creates one, then renames the download over it).
            guard snap.size > 0, settled else {
                pending[path] = (snap, entry.quiet, stable, entry.arrived); continue
            }
            pending[path] = nil
            // Already handed off (a repeated event, or the file was renamed or moved since):
            // just note where it is now.
            let id = FileID(device: st.st_dev, inode: st.st_ino)
            if handedOff[id]?.snap == snap { handedOff[id]?.path = path; continue }
            handedOff[id] = (snap, path)
            justHandedOff.append(entry.arrived)
            let r = Ready(file: URL(fileURLWithPath: path), arrived: entry.arrived)
            if entry.quiet { readyQuiet.append(r) } else { ready.append(r) }
        }
        publishOldest()
        func sorted(_ r: [Ready]) -> [Ready] { r.sorted { $0.file.path.localizedStandardCompare($1.file.path) == .orderedAscending } }
        if !readyQuiet.isEmpty { onReady(sorted(readyQuiet), true) }
        if !ready.isEmpty { onReady(sorted(ready), false) }
    }
}

extension FolderWatcher {
    /// How long a FLAC whose header doesn't record its length must stay unchanged.
    static let settleTimeWithoutLength: TimeInterval = 30
}

/// A value that any thread can set and read.
private final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
