import Foundation

/// Errors surfaced by the converter core.
enum ConvertError: Error, CustomStringConvertible {
    case notFlac
    case afconvertFailed(String)
    case saveFailed(String)

    var description: String {
        switch self {
        case .notFlac:
            return "Skipped — not a .flac file"
        case .afconvertFailed(let message), .saveFailed(let message):
            return message
        }
    }
}

/// What a single conversion did.
enum Outcome {
    case converted(URL, note: String?)   // note: what wasn't lossless, e.g. "96 → 48 kHz"
    case alreadyConverted(URL)
}

/// Core FLAC → AIFF conversion logic. No UI knowledge; usable headless.
enum Converter {
    static let afconvert = "/usr/bin/afconvert"
    static let afinfo = "/usr/bin/afinfo"

    /// Detect the source PCM bit depth of a FLAC via `afinfo -x` (XML).
    /// Returns nil when detection is impossible; callers must fail toward lossless.
    static func detectBitDepth(_ url: URL) -> Int? {
        guard let xml = runCapture(afinfo, ["-x", url.path]),
              let doc = try? XMLDocument(xmlString: xml) else { return nil }
        // Doc uses a default namespace — match by local-name() instead of registering it.
        // FLAC's real depth is <source_info><bit_depth>; the track-level <bit_depth> is 0.
        let nodes = (try? doc.nodes(forXPath:
            "//*[local-name()='source_info']/*[local-name()='bit_depth']")) ?? []
        guard let text = nodes.first?.stringValue,
              let depth = Int(text.trimmingCharacters(in: .whitespaces)),
              (1...32).contains(depth) else { return nil }
        return depth
    }

    /// Convert a single FLAC to `destDir/<name>.aiff`. Skips if that AIFF already exists.
    /// Preserves sample rate; matches source bit depth (16-, 24- or 32-bit,
    /// big-endian signed PCM), rounding up on detection failure — never down.
    ///
    /// The AIFF is written to a hidden temp file and renamed into place only when
    /// complete, so an existing `<name>.aiff` is always a finished file.
    @discardableResult
    static func convert(flacURL: URL, destDir: URL) throws -> Outcome {
        guard flacURL.pathExtension.lowercased() == "flac" else { throw ConvertError.notFlac }
        let base = flacURL.deletingPathExtension().lastPathComponent
        let final = destDir.appendingPathComponent(base + ".aiff")
        if FileManager.default.fileExists(atPath: final.path) { return .alreadyConverted(final) }

        let createdDirs = try createDirectories(destDir)
        do {
            removeStalePartials(base: base, in: destDir)
            let tmp = try reserveTemp(base: base, in: destDir)
            do {
                let detected = detectBitDepth(flacURL) ?? 24   // on detection failure, fail toward lossless
                let depth: Int
                switch detected {
                case ...16:    depth = 16   // 4–16-bit → BEI16 (lossless up-conversion for <16)
                case 17...24:  depth = 24   // 17–24-bit (incl. 20-bit) → BEI24
                default:       depth = 32   // 25–32-bit → BEI32
                }
                let (code, err) = run(afconvert, ["-f", "AIFF", "-d", "BEI\(depth)", flacURL.path, tmp.path])
                guard code == 0 else {
                    throw ConvertError.afconvertFailed(err.isEmpty ? "afconvert exited with code \(code)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                // afconvert drops all tags; carry title/artist/album/cover etc. over as an ID3 chunk.
                if let tag = TagIO.id3v23(TagIO.readFlacTags(flacURL)) {
                    try TagIO.appendID3Chunk(tag, to: tmp)
                }

                // RENAME_EXCL: never replace an AIFF another conversion published meanwhile.
                guard renamex_np(tmp.path, final.path, UInt32(RENAME_EXCL)) == 0 else {
                    let e = errno
                    if e == EEXIST {
                        try? FileManager.default.removeItem(at: tmp)
                        return .alreadyConverted(final)
                    }
                    throw ConvertError.saveFailed("Could not save \(final.lastPathComponent): \(String(cString: strerror(e)))")
                }
                return .converted(final, note: nil)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw error
            }
        } catch {
            for dir in createdDirs.reversed() { rmdir(dir.path) }   // only removes still-empty dirs
            throw error
        }
    }

    // MARK: - Output file helpers

    /// Create `dir` and any missing parents. Returns the ones created, outermost first.
    private static func createDirectories(_ dir: URL) throws -> [URL] {
        var missing: [URL] = []
        var d = dir.standardizedFileURL
        while !FileManager.default.fileExists(atPath: d.path) {
            missing.insert(d, at: 0)
            let parent = d.deletingLastPathComponent()
            if parent.path == d.path { break }
            d = parent
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return missing
    }

    private static let counterLock = NSLock()
    private static var counter = 0

    /// Create a fresh `.<base>.<pid>.<n>.aiff.partial` in `dir` (O_CREAT|O_EXCL), so no two
    /// writers — in this process or another — ever share a temp file.
    private static func reserveTemp(base: String, in dir: URL) throws -> URL {
        while true {
            counterLock.lock(); let n = counter; counter += 1; counterLock.unlock()
            let url = dir.appendingPathComponent(".\(base).\(getpid()).\(n).aiff.partial")
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 { close(fd); return url }
            let e = errno
            guard e == EEXIST else {
                throw ConvertError.saveFailed("Could not write to \(dir.path): \(String(cString: strerror(e)))")
            }
        }
    }

    /// Delete `.<base>.<pid>.<n>.aiff.partial` files whose process is gone (crash leftovers).
    private static func removeStalePartials(base: String, in dir: URL) {
        let prefix = "." + base + ".", suffix = ".aiff.partial"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let parts = name.dropFirst(prefix.count).dropLast(suffix.count).split(separator: ".")
            guard parts.count == 2, let pid = pid_t(parts[0]), Int(parts[1]) != nil else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    // MARK: - Process helpers

    /// Run a tool, returning (exit code, captured stderr).
    private static func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)") }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
    }

    /// Run a tool, returning captured stdout (or nil on launch failure).
    private static func runCapture(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
