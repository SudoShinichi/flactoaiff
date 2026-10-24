import Foundation

/// Errors surfaced by the converter core.
enum ConvertError: Error, CustomStringConvertible {
    case notFlac
    case afconvertFailed(String)

    var description: String {
        switch self {
        case .notFlac:
            return "Skipped — not a .flac file"
        case .afconvertFailed(let message):
            return message
        }
    }
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

    /// Atomically claim `url` (O_CREAT|O_EXCL). True = we own this name now.
    private static func reserve(_ url: URL) -> Bool {
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// A `.aiff` URL in `destDir` that is *reserved* for the caller (zero-byte file created).
    /// `song.aiff` → `song 2.aiff` → `song 3.aiff` … The reservation closes the TOCTOU
    /// window: two concurrent callers can never claim the same name.
    static func uniqueOutputURL(for flacURL: URL, in destDir: URL) -> URL {
        let base = flacURL.deletingPathExtension().lastPathComponent
        var candidate = destDir.appendingPathComponent(base + ".aiff")
        var n = 2
        while !reserve(candidate) {
            candidate = destDir.appendingPathComponent("\(base) \(n).aiff")
            n += 1
        }
        return candidate
    }

    /// Convert a single FLAC to AIFF inside `destDir`. Returns the output URL.
    /// Preserves sample rate; matches source bit depth (16-, 24- or 32-bit,
    /// big-endian signed PCM), rounding up on detection failure — never down.
    @discardableResult
    static func convert(flacURL: URL, destDir: URL) throws -> URL {
        guard flacURL.pathExtension.lowercased() == "flac" else { throw ConvertError.notFlac }
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let detected = detectBitDepth(flacURL) ?? 24   // on detection failure, fail toward lossless
        let depth: Int
        switch detected {
        case ...16:    depth = 16   // 4–16-bit → BEI16 (lossless up-conversion for <16)
        case 17...24:  depth = 24   // 17–24-bit (incl. 20-bit) → BEI24
        default:       depth = 32   // 25–32-bit → BEI32
        }

        let output = uniqueOutputURL(for: flacURL, in: destDir)
        let (code, err) = run(afconvert, ["-f", "AIFF", "-d", "BEI\(depth)", flacURL.path, output.path])
        guard code == 0 else {
            try? FileManager.default.removeItem(at: output)   // don't leave a corpse that steals "song.aiff"
            throw ConvertError.afconvertFailed(err.isEmpty ? "afconvert exited with code \(code)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // afconvert drops all tags; carry title/artist/album/cover etc. over as an ID3 chunk.
        if let tag = TagIO.id3v23(TagIO.readFlacTags(flacURL)) {
            do {
                try TagIO.appendID3Chunk(tag, to: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
        return output
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
