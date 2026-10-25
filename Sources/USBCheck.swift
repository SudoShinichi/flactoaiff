import Foundation

/// Read-only check of a USB stick: which tracks the chosen player won't play, and whether it
/// can read the stick at all. Never changes a file: replacing tracks on a stick breaks its
/// rekordbox export, so the fix is to convert the originals and export them again.
enum USBCheck {
    /// Audio files the check looks at. Anything else (artwork, rekordbox's .DAT files) is ignored.
    private static let audioExtensions: Set<String> = ["flac", "wav", "wave", "m4a", "aif", "aiff", "mp3", "aac",
                                                       "ogg", "opus", "wma", "dsf", "dff", "ape", "m4p"]

    /// Rows for `folder` (a stick, or a folder on one): a note about its file system if needed,
    /// one red row per track that won't play, and a summary.
    static func run(_ folder: URL, on player: Player, isCancelled: () -> Bool = { false }) -> [Row] {
        var rows: [Row] = []
        let name = folder.lastPathComponent
        if let row = fileSystemProblem(folder, name: name) { rows.append(row) }

        var tracks = 0, unplayable = 0
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        let rootDepth = folder.standardizedFileURL.pathComponents.count
        while let file = walker?.nextObject() as? URL, !isCancelled() {
            guard audioExtensions.contains(file.pathExtension.lowercased()),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            tracks += 1
            guard let reason = problem(file, on: player) else { continue }
            unplayable += 1
            let path = file.standardizedFileURL.pathComponents.dropFirst(rootDepth).joined(separator: "/")
            rows.append(Row(name: path, kind: .failed, detail: reason, output: file, checks: nil))
        }

        let summary: String
        if tracks == 0 {
            summary = "No audio files found"
        } else if unplayable == 0 {
            summary = tracks == 1 ? "The track plays on the \(player.name)" : "All \(tracks) tracks play on the \(player.name)"
        } else {
            summary = "\(tracks - unplayable) of \(tracks) \(tracks == 1 ? "track plays" : "tracks play") on the \(player.name). For the others, convert "
                + "the original files with this player chosen, then put them on the stick again with rekordbox."
        }
        rows.append(Row(name: name, kind: .info, detail: summary, output: nil, checks: nil))
        return rows
    }

    /// Why `player` won't play `file`, or nil when it will.
    static func problem(_ file: URL, on player: Player) -> String? {
        let ext = file.pathExtension.lowercased()
        func rateAndDepth(rate: Int, bits: Int) -> String? {
            if !player.rates.contains(rate) {
                return "\(khz(rate)) kHz — the \(player.name) plays \(list(player.rates.sorted().map { "\(khz($0)) kHz" }))"
            }
            if !player.depths.contains(bits) {
                return "\(bits)-bit — the \(player.name) plays \(list(player.depths.sorted().map { "\($0)-bit" }))"
            }
            return nil
        }
        switch ext {
        case "mp3":
            return nil   // every listed player plays MP3 (the manuals' MP3 rows)
        case "aif", "aiff":
            guard let info = TagIO.aiffInfo(file) else { return "Can't read this AIFF — it may be damaged" }
            return rateAndDepth(rate: Int(info.rate), bits: info.bitsPerSample)
        case "m4p":
            return "Copy-protected (DRM) — no DJ player plays it"
        default:
            break
        }
        guard let source = AudioSources.open(file) else {
            return "\(ext.uppercased()) — the \(player.name) doesn't play this format"
        }
        let format = type(of: source).name
        if source is AlacSource, source.skipReason != nil {
            return nil   // AAC: every listed player plays it (up to 48 kHz, 16-bit, per the manuals)
        }
        if source is WavSource, source.skipReason != nil {
            return "Floating-point or compressed WAV — the \(player.name) plays 16 and 24-bit PCM WAV"
        }
        guard player.plays.contains(format) else { return "\(format) — the \(player.name) doesn't play \(format)" }
        guard let info = source.info else { return "Can't read this \(format) file — it may be damaged" }
        return rateAndDepth(rate: info.rate, bits: info.bitsPerSample)
    }

    /// APFS and NTFS sticks can't be read by any listed player; exFAT only by some.
    private static func fileSystemProblem(_ folder: URL, name: String) -> Row? {
        var fs = statfs()
        guard statfs(folder.path, &fs) == 0 else { return nil }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        switch type {
        case "apfs", "ntfs":
            return Row(name: name, kind: .failed,
                       detail: "Formatted as \(type == "apfs" ? "APFS" : "NTFS"), which DJ players can't read. "
                        + "Format the stick as FAT32 (MS-DOS) or Mac OS Extended in Disk Utility.",
                       output: nil, checks: nil)
        case "exfat":
            return Row(name: name, kind: .info,
                       detail: "Formatted as exFAT. The CDJ-3000X reads it; many other players read only FAT32 "
                        + "and Mac OS Extended. Check your player's manual.",
                       output: nil, checks: nil)
        default:
            return nil
        }
    }

    private static func khz(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000)" : String(format: "%.1f", Double(hz) / 1000)
    }

    private static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
