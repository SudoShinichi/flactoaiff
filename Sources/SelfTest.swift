#if TEST_HOOKS   // test.sh's own build only; the app never contains this
import Foundation

/// `--selftest <a convertible FLAC>`: checks the parts the command line bypasses, the settings
/// (and their migration) and the queue's bookkeeping for the watch folder, on the real types.
enum SelfTest {
    static func run(flac: URL) -> Bool {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("flactoaiff-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            if !ok { failures += 1; FileHandle.standardError.write("FAIL selftest: \(what)\n".data(using: .utf8)!) }
        }

        // MARK: Settings: the old Format setting carries over; the Player setting wins over it.
        func settings(_ values: [String: Any]) -> (Settings, UserDefaults) {
            let name = "flactoaiff.selftest.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            for (key, value) in values { defaults.set(value, forKey: key) }
            return (Settings(defaults: defaults), defaults)
        }
        expect(settings([:]).0.player.id == "original", "no stored setting → Original")
        expect(settings(["outputMode": "max48"]).0.player.id == "cdj-2000nxs", "old max48 → CDJ-2000NXS class")
        expect(settings(["outputMode": "cd"]).0.player.id == "cd", "old cd → Audio CD")
        expect(settings(["outputMode": "bogus"]).0.player.id == "original", "unknown old mode → Original")
        expect(settings(["outputMode": "cd", "player": "cdj-3000"]).0.player.id == "cdj-3000", "the Player setting wins")
        let (stored, defaults) = settings([:])
        stored.player = Player.named("xdj-rx3")!
        stored.skipPlayable = true
        let reread = Settings(defaults: defaults)
        expect(reread.player.id == "xdj-rx3" && reread.skipPlayable, "Player and skip setting persist")
        expect(reread.convertOptions.skipPlayableOn?.id == "xdj-rx3" && reread.convertOptions.mode == .max48,
               "convert options follow the player")
        reread.player = .cd
        expect(reread.convertOptions.skipPlayableOn == nil, "no skipping for a choice without a player list")

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
        expect(queue.rows.last?.name == "x\(ConversionQueue.maxRows).txt", "the newest row is kept")
        queue.clear()
        expect(queue.rows.isEmpty, "Clear empties an idle window")

        print(failures == 0 ? "SELFTEST passed" : "SELFTEST failed: \(failures)")
        return failures == 0
    }
}
#endif
