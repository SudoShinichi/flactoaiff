import Foundation

/// Errors surfaced by the converter core.
enum ConvertError: Error, CustomStringConvertible {
    case notFlac
    case afconvertFailed(String)
    case saveFailed(String)
    case outputFolderUnavailable

    var description: String {
        switch self {
        case .notFlac:
            return "Skipped — not a .flac file"
        case .afconvertFailed(let message), .saveFailed(let message):
            return message
        case .outputFolderUnavailable:
            return "Output folder not available — choose another in “Save to”"
        }
    }
}

/// What a single conversion did.
enum Outcome {
    case converted(URL, note: String?)   // note: what wasn't lossless, e.g. "96 → 48 kHz"
    case alreadyConverted(URL)
}

/// Output compatibility target. Raw values are the CLI `--format` names and the stored setting.
enum OutputMode: String, CaseIterable, Identifiable {
    case original   // lossless: depth matched, rate kept
    case max48      // CDJ-2000NXS-class players: ≤24-bit, ≤48 kHz
    case cd         // audio-CD burning: 16-bit / 44.1 kHz

    var id: String { rawValue }
}

/// Per-conversion choices.
struct ConvertOptions {
    var mode: OutputMode = .original
}

/// Core FLAC → AIFF conversion logic. No UI knowledge; usable headless.
enum Converter {
    static let afconvert = "/usr/bin/afconvert"
    static let afinfo = "/usr/bin/afinfo"

    /// What `afinfo` reports about a source; nil fields mean "couldn't detect".
    struct SourceFormat {
        let depth: Int?
        let rate: Int?
    }

    /// Target PCM format. `rate == nil` means "keep the source rate" (no resampling).
    struct OutputFormat: Equatable {
        let depth: Int
        let rate: Int?
        let dither: Bool
    }

    /// Detect source bit depth and sample rate via one `afinfo -x` (XML) call.
    static func probe(_ url: URL) -> SourceFormat {
        guard let xml = runCapture(afinfo, ["-x", url.path]),
              let doc = try? XMLDocument(xmlString: xml) else { return SourceFormat(depth: nil, rate: nil) }
        func number(_ xpath: String) -> Int? {
            guard let text = (try? doc.nodes(forXPath: xpath))?.first?.stringValue,
                  let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
            return Int(value)
        }
        // Doc uses a default namespace — match by local-name() instead of registering it.
        // FLAC's real depth is <source_info><bit_depth>; the track-level <bit_depth> is 0.
        let depth = number("//*[local-name()='source_info']/*[local-name()='bit_depth']")
            .flatMap { (1...32).contains($0) ? $0 : nil }
        let rate = number("//*[local-name()='track']/*[local-name()='sample_rate']")
            .flatMap { $0 > 0 ? $0 : nil }
        return SourceFormat(depth: depth, rate: rate)
    }

    /// The output format for `mode`. Original is lossless; max48 caps at 24-bit and resamples
    /// > 48 kHz to the same-family rate (88.2/176.4 → 44.1, 96/192 → 48) so the ratio stays an
    /// integer; cd forces 16-bit / 44.1 kHz with dither when reducing bit depth.
    static func outputFormat(for source: SourceFormat, mode: OutputMode) -> OutputFormat {
        let matched: Int
        switch source.depth ?? 24 {   // on detection failure, fail toward lossless
        case ...16:    matched = 16   // 4–16-bit → BEI16 (lossless up-conversion for <16)
        case 17...24:  matched = 24   // 17–24-bit (incl. 20-bit) → BEI24
        default:       matched = 32   // 25–32-bit → BEI32
        }
        switch mode {
        case .original:
            return OutputFormat(depth: matched, rate: nil, dither: false)
        case .max48:
            let depth = min(matched, 24)
            guard let rate = source.rate, rate > 48_000 else { return OutputFormat(depth: depth, rate: nil, dither: false) }
            return OutputFormat(depth: depth, rate: rate % 44_100 == 0 ? 44_100 : 48_000, dither: false)
        case .cd:
            // Unknown rate → resample anyway: CD players accept nothing but 44.1 kHz.
            return OutputFormat(depth: 16, rate: source.rate == 44_100 ? nil : 44_100,
                                dither: (source.depth ?? 24) > 16)
        }
    }

    /// "96 → 44.1 kHz, 24 → 16-bit" for whatever was reduced; nil when lossless.
    private static func reductionNote(_ source: SourceFormat, _ out: OutputFormat) -> String? {
        var parts: [String] = []
        if let to = out.rate, let from = source.rate { parts.append("\(khz(from)) → \(khz(to)) kHz") }
        if let from = source.depth, from > out.depth { parts.append("\(from) → \(out.depth)-bit") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func khz(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000)" : String(format: "%.1f", Double(hz) / 1000)
    }

    /// Convert a single FLAC to `destDir/<name>.aiff`. Skips if that AIFF already exists.
    /// Format follows options.mode (see outputFormat); .original is lossless.
    ///
    /// The AIFF is written to a hidden temp file and renamed into place only when
    /// complete, so an existing `<name>.aiff` is always a finished file.
    @discardableResult
    static func convert(flacURL: URL, destDir: URL, options: ConvertOptions = ConvertOptions()) throws -> Outcome {
        guard flacURL.pathExtension.lowercased() == "flac" else { throw ConvertError.notFlac }
        let base = flacURL.deletingPathExtension().lastPathComponent
        let final = destDir.appendingPathComponent(base + ".aiff")
        if FileManager.default.fileExists(atPath: final.path) { return .alreadyConverted(final) }

        let createdDirs = try createDirectories(destDir)
        do {
            removeStalePartials(in: destDir)
            let tmp = try reserveTemp(in: destDir)
            do {
                let source = probe(flacURL)
                let format = outputFormat(for: source, mode: options.mode)
                var args = ["-f", "AIFF"]
                if let rate = format.rate {
                    args += ["-d", "BEI\(format.depth)@\(rate)", "-r", "127", "--src-complexity", "bats"]
                } else {
                    args += ["-d", "BEI\(format.depth)"]   // with no dither: today's lossless command line
                }
                if format.dither { args += ["--dither", "1"] }   // TPDF
                let (code, err) = run(afconvert, args + [flacURL.path, tmp.path])
                guard code == 0 else {
                    throw ConvertError.afconvertFailed(err.isEmpty ? "afconvert exited with code \(code)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                // afconvert happily converts a truncated FLAC (a download or copy still being
                // written), so check the length against STREAMINFO. Resampled lengths are within ±1.
                if let info = TagIO.flacStreamInfo(flacURL), info.samples > 0, let got = TagIO.aiffFrameCount(tmp) {
                    let expected = Double(info.samples) * Double(format.rate ?? info.rate) / Double(info.rate)
                    guard abs(Double(got) - expected) <= 2 else {
                        throw ConvertError.afconvertFailed(
                            "FLAC is incomplete — only \(Int(Double(got) / expected * 100))% of the audio is there")
                    }
                }

                // afconvert drops all tags; carry title/artist/album/cover etc. over as an ID3 chunk.
                if let tag = TagIO.id3v23(TagIO.readFlacTags(flacURL)) {
                    try TagIO.appendID3Chunk(tag, to: tmp)
                }

                guard try publish(tmp, as: final) else {
                    try? FileManager.default.removeItem(at: tmp)
                    return .alreadyConverted(final)
                }
                return .converted(final, note: reductionNote(source, format))
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

    /// Move the finished `tmp` to `final` without ever replacing an existing file.
    /// Returns false if `final` already exists (another conversion published it meanwhile).
    ///
    /// RENAME_EXCL is atomic but only APFS/HFS+ support it; exFAT, FAT32 and many network
    /// shares return ENOTSUP/EINVAL. There, try link() (atomic, fails with EEXIST), and on
    /// volumes without hard links (exFAT) fall back to check-then-rename: a tiny race
    /// window, but `final` is still always a complete file.
    private static func publish(_ tmp: URL, as final: URL) throws -> Bool {
        func failed(_ e: Int32) -> ConvertError {
            .saveFailed("Could not save \(final.lastPathComponent): \(String(cString: strerror(e)))")
        }
        if renamex_np(tmp.path, final.path, UInt32(RENAME_EXCL)) == 0 { return true }
        var e = errno
        if e == EEXIST { return false }
        guard e == ENOTSUP || e == EINVAL else { throw failed(e) }

        if link(tmp.path, final.path) == 0 { unlink(tmp.path); return true }
        e = errno
        if e == EEXIST { return false }
        guard e == ENOTSUP || e == EPERM || e == EINVAL else { throw failed(e) }

        if FileManager.default.fileExists(atPath: final.path) { return false }
        guard rename(tmp.path, final.path) == 0 else { throw failed(errno) }
        return true
    }

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

    private static let partialPrefix = ".flactoaiff.", partialSuffix = ".partial"

    /// Create a fresh `.flactoaiff.<pid>.<n>.partial` in `dir` (O_CREAT|O_EXCL), so no two
    /// writers — in this process or another — ever share a temp file. The name doesn't
    /// contain the track's, so it fits NAME_MAX whenever the final `<name>.aiff` does.
    private static func reserveTemp(in dir: URL) throws -> URL {
        while true {
            counterLock.lock(); let n = counter; counter += 1; counterLock.unlock()
            let url = dir.appendingPathComponent("\(partialPrefix)\(getpid()).\(n)\(partialSuffix)")
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 { close(fd); return url }
            let e = errno
            guard e == EEXIST else {
                throw ConvertError.saveFailed("Could not write to \(dir.path): \(String(cString: strerror(e)))")
            }
        }
    }

    /// Delete `.flactoaiff.<pid>.<n>.partial` files whose process is gone (crash leftovers).
    private static func removeStalePartials(in dir: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(partialPrefix) && name.hasSuffix(partialSuffix) {
            let parts = name.dropFirst(partialPrefix.count).dropLast(partialSuffix.count).split(separator: ".")
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
