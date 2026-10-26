#if TEST_HOOKS   // test.sh's own build only; the app never contains this
import AppKit
import SwiftUI

/// `--selftest <a convertible FLAC> <an AAC .m4a>`: checks the parts the command line bypasses,
/// the settings (and their migration) and the queue's bookkeeping for the watch folder, on the
/// real types. `--ideal-widths`: the widths the window's fixed rows need.
enum SelfTest {
    static func run(flac: URL, aac: URL) -> Bool {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("flactoaiff-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            if !ok { failures += 1; FileHandle.standardError.write("FAIL selftest: \(what)\n".data(using: .utf8)!) }
        }

        // MARK: Settings: earlier versions' choices carry over; the Format setting wins over them.
        func settings(_ values: [String: Any]) -> (Settings, UserDefaults) {
            let name = "flactoaiff.selftest.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            for (key, value) in values { defaults.set(value, forKey: key) }
            return (Settings(defaults: defaults), defaults)
        }
        expect(settings([:]).0.format == .original, "no stored setting → Original")
        expect(settings(["outputMode": "max48"]).0.format == .max48, "first Format menu: max48 kept")
        expect(settings(["outputMode": "cd"]).0.format == .cd, "first Format menu: cd kept")
        expect(settings(["outputMode": "bogus"]).0.format == .original, "unknown old value → Original")
        expect(settings(["player": "cdj-3000"]).0.format == .max96, "Player menu: CDJ-3000 → up to 96 kHz")
        expect(settings(["player": "xdj-rx3"]).0.format == .max48, "Player menu: XDJ-RX3 → up to 48 kHz")
        expect(settings(["player": "cd", "outputMode": "original"]).0.format == .cd, "Player menu wins over the first menu")
        expect(settings(["format": "max96", "player": "cd"]).0.format == .max96, "the Format setting wins")
        let (stored, defaults) = settings(["player": "cdj-3000"])
        stored.format = .max48
        expect(Settings(defaults: defaults).format == .max48, "the Format setting persists")

        let arrivedForFolders = Date(timeIntervalSince1970: 1_500_000)
        // MARK: Folders: found again after they're renamed or moved
        let folders = temp.appendingPathComponent("folders", isDirectory: true)
        let saveA = folders.appendingPathComponent("Save A", isDirectory: true)
        let watchA = folders.appendingPathComponent("Watch A", isDirectory: true)
        for dir in [saveA, watchA] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let (moving, movingDefaults) = settings([:])
        moving.outputFolder = saveA
        moving.watchFolder = watchA
        moving.watchedUntil = arrivedForFolders
        let saveB = folders.appendingPathComponent("Save B", isDirectory: true)
        let watchB = folders.appendingPathComponent("Sub/Watch B", isDirectory: true)
        try? FileManager.default.createDirectory(at: watchB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: saveA, to: saveB)
        try? FileManager.default.moveItem(at: watchA, to: watchB)
        moving.followMovedFolders()
        expect(moving.outputFolder.standardizedFileURL.path == saveB.standardizedFileURL.path, "a renamed Save to is found again")
        expect(moving.watchFolder?.standardizedFileURL.path == watchB.standardizedFileURL.path, "a moved watch folder is found again")
        expect(moving.watchedUntil == arrivedForFolders, "following a moved watch folder keeps its history")
        let saveC = folders.appendingPathComponent("Save C", isDirectory: true)
        try? FileManager.default.moveItem(at: saveB, to: saveC)
        expect(Settings(defaults: movingDefaults).outputFolder.standardizedFileURL.path == saveC.standardizedFileURL.path,
               "a Save to renamed while the app was closed is found at launch")
        try? FileManager.default.removeItem(at: saveC)
        moving.followMovedFolders()
        expect(moving.outputFolder.lastPathComponent == "Save B", "a Save to that's gone keeps its last path")
        let (fresh, _) = settings(["outputFolder": saveA.path])   // saved before bookmarks existed
        expect(fresh.outputFolder.path == saveA.path, "a path saved by an older version still loads")

        // MARK: The queue
        let (s, _) = settings([:])
        let out = temp.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        s.outputFolder = out
        let queue = ConversionQueue(settings: s)
        func idle() -> Bool {
            let deadline = Date().addingTimeInterval(60)
            while queue.isWorking && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))   // let the last main-queue updates land
            return !queue.isWorking
        }

        // Save to renamed while the app runs: the next batch saves where it is now.
        let renamedOut = temp.appendingPathComponent("out renamed", isDirectory: true)
        let outBefore = temp.appendingPathComponent("out before", isDirectory: true)
        try? FileManager.default.createDirectory(at: outBefore, withIntermediateDirectories: true)
        s.outputFolder = outBefore
        try? FileManager.default.moveItem(at: outBefore, to: renamedOut)
        queue.enqueue([flac])
        expect(idle() && queue.rows.last?.kind == .converted
               && queue.rows.last?.output?.deletingLastPathComponent().standardizedFileURL.path == renamedOut.standardizedFileURL.path,
               "a renamed Save to is followed by the next batch")
        s.outputFolder = out
        queue.clear()

        // A watched file holds catch-up back until it's converted.
        let watchRoot = flac.deletingLastPathComponent()
        let arrived = Date(timeIntervalSince1970: 1_000_000)
        queue.enqueueWatched([FolderWatcher.Ready(file: flac, arrived: arrived)], root: watchRoot)
        expect(queue.oldestUnfinishedWatched == arrived, "a queued watched file holds catch-up back")
        expect(queue.isConverting && queue.isWorking, "converting is reported while converting")
        expect(idle(), "the queue finishes")
        expect(queue.oldestUnfinishedWatched == nil, "a converted watched file no longer holds catch-up back")
        expect(queue.rows.last?.kind == .converted, "the watched file converted")

        // Launch catch-up: an already converted file adds no row, and still counts as done.
        let rowsBefore = queue.rows.count
        queue.enqueueWatched([FolderWatcher.Ready(file: flac, arrived: arrived)], root: watchRoot, quietSkips: true)
        expect(idle() && queue.rows.count == rowsBefore, "catch-up doesn't list already converted files")
        expect(queue.oldestUnfinishedWatched == nil, "an already converted file counts as done")

        // Save to missing: the file is kept for the next launch.
        s.outputFolder = temp.appendingPathComponent("unplugged", isDirectory: true)
        let later = Date(timeIntervalSince1970: 2_000_000)
        queue.enqueueWatched([FolderWatcher.Ready(file: flac, arrived: later)], root: watchRoot)
        expect(idle(), "the queue finishes without Save to")
        expect(queue.rows.last?.retryable == true, "a missing Save to is marked for retry")
        expect(queue.oldestUnfinishedWatched == later, "a file that failed for a missing Save to is tried again")
        queue.retryUnavailable()
        expect(!queue.isWorking, "no retry while Save to is still missing")
        s.outputFolder = temp.appendingPathComponent("plugged-in", isDirectory: true)
        try? FileManager.default.createDirectory(at: s.outputFolder, withIntermediateDirectories: true)
        queue.retryUnavailable()
        expect(idle() && queue.rows.last?.kind == .converted, "a file kept for retry converts once Save to is back")
        expect(queue.oldestUnfinishedWatched == nil, "a retried file no longer holds catch-up back")
        s.outputFolder = temp.appendingPathComponent("unplugged", isDirectory: true)
        queue.enqueueWatched([FolderWatcher.Ready(file: flac, arrived: later)], root: watchRoot)
        expect(idle() && queue.oldestUnfinishedWatched == later, "a file kept for retry again")
        queue.forgetWatched()
        expect(queue.oldestUnfinishedWatched == nil, "a forgotten watch folder holds nothing back")

        // A job from a forgotten watch session can't finish a file of the new session.
        s.outputFolder = temp.appendingPathComponent("out2", isDirectory: true)
        try? FileManager.default.createDirectory(at: s.outputFolder, withIntermediateDirectories: true)
        queue.enqueueWatched([FolderWatcher.Ready(file: flac, arrived: arrived)], root: watchRoot)   // converts
        queue.forgetWatched()
        s.outputFolder = temp.appendingPathComponent("unplugged", isDirectory: true)
        queue.enqueueWatched([FolderWatcher.Ready(file: flac, arrived: later)], root: watchRoot)     // kept for retry
        expect(idle(), "the queue finishes both sessions")
        expect(queue.oldestUnfinishedWatched == later, "the old session's job left the new session's file alone")
        queue.forgetWatched()

        // An AAC download in the watch folder is skipped without a row; dropped, it gets one.
        s.outputFolder = out
        let rowsBeforeAAC = queue.rows.count
        queue.enqueueWatched([FolderWatcher.Ready(file: aac, arrived: arrived)], root: aac.deletingLastPathComponent())
        expect(idle() && queue.rows.count == rowsBeforeAAC, "an AAC file in the watch folder adds no row")
        expect(queue.oldestUnfinishedWatched == nil, "a skipped AAC file counts as done")
        queue.enqueue([aac])
        expect(idle() && queue.rows.last?.kind == .skipped, "an AAC file dropped on the window gets its row")

        // A USB check runs beside conversions instead of waiting for them.
        let batch = temp.appendingPathComponent("batch", isDirectory: true), empty = temp.appendingPathComponent("empty")
        try? FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        for i in 0..<30 { try? FileManager.default.copyItem(at: flac, to: batch.appendingPathComponent("b\(i).flac")) }
        s.outputFolder = temp.appendingPathComponent("batch-out", isDirectory: true)
        try? FileManager.default.createDirectory(at: s.outputFolder, withIntermediateDirectories: true)
        queue.enqueue([batch])
        queue.check(empty, for: Player.named("cdj-3000")!)
        let deadline = Date().addingTimeInterval(30)
        while !queue.rows.contains(where: { $0.kind == .info && $0.name == "empty" }) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        expect(queue.isConverting, "a USB check finishes while a conversion batch still runs")
        expect(idle(), "the batch finishes")
        let batchRows = queue.rows.filter { $0.name.hasPrefix("b") && $0.name.hasSuffix(".flac") }
        expect(batchRows.count == 30 && batchRows.allSatisfy { $0.kind == .converted }, "every file of the batch converts")
        expect(ConversionQueue.lanes(for: temp) == min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)),
               "several files convert at once on the Mac's own drive")
        expect(ConversionQueue.lanes(for: URL(fileURLWithPath: "/nonexistent")) == 1, "one at a time where the drive is unknown")

        // Two sources for the same AIFF still run in their order, however many lanes.
        let pair = temp.appendingPathComponent("pair", isDirectory: true)
        try? FileManager.default.createDirectory(at: pair, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: flac, to: pair.appendingPathComponent("same.flac"))
        let afconvert = Process()
        afconvert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        afconvert.arguments = ["-f", "WAVE", "-d", "LEI16", flac.path, pair.appendingPathComponent("same.wav").path]
        try? afconvert.run(); afconvert.waitUntilExit()
        for round in 0..<3 {
            s.outputFolder = temp.appendingPathComponent("pair-out-\(round)", isDirectory: true)
            try? FileManager.default.createDirectory(at: s.outputFolder, withIntermediateDirectories: true)
            queue.enqueue([pair])
            expect(idle(), "the pair finishes")
            let flacRow = queue.rows.last { $0.name == "same.flac" }, wavRow = queue.rows.last { $0.name == "same.wav" }
            expect(flacRow?.kind == .converted && wavRow?.kind == .failed && wavRow?.detail.contains("made from a different file") == true,
                   "same.flac (listed first) converts and same.wav is refused, round \(round)")
        }

        // A USB check is work, but not conversion: quitting during it loses nothing.
        queue.check(temp, for: Player.named("cdj-3000")!)
        expect(queue.isWorking && !queue.isConverting, "a USB check isn't reported as converting")
        expect(idle() && queue.rows.last?.kind == .info, "the USB check ends with its summary")

        // Clear does nothing while work runs; the window keeps the newest rows only.
        s.outputFolder = out
        queue.enqueue((0...ConversionQueue.maxRows).map { temp.appendingPathComponent("x\($0).txt") })
        queue.clear()
        expect(!queue.rows.isEmpty, "Clear waits until the queue is idle")
        expect(idle(), "the queue finishes the big batch")
        expect(queue.rows.count == ConversionQueue.maxRows, "the window keeps at most \(ConversionQueue.maxRows) rows")
        // Rows come in the order files finish, which with several lanes isn't quite the listed one.
        expect(queue.rows.contains { $0.name == "x\(ConversionQueue.maxRows).txt" }, "the newest row is kept")
        queue.clear()
        expect(queue.rows.isEmpty, "Clear empties an idle window")

        print(failures == 0 ? "SELFTEST passed" : "SELFTEST failed: \(failures)")
        return failures == 0
    }

    /// The widths the window's two fixed rows need: the Format menu with its longest title, and
    /// the bottom bar. At the window's minimum of 400 pt less 2 × 16 pt padding, 368 pt fit.
    static func idealWidths() -> [CGFloat] {
        [NSHostingView(rootView: FormatPicker(format: .constant(.max96)).fixedSize()).fittingSize.width,
         NSHostingView(rootView: ActionBar(canReveal: true, canClear: true, checkStick: { _ in }, reveal: {}, clear: {})
            .fixedSize()).fittingSize.width]
    }
}
#endif
