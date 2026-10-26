import Foundation

/// Errors surfaced by the converter core.
enum ConvertError: Error, CustomStringConvertible {
    case afconvertFailed(String)
    case saveFailed(String)
    case outputFolderUnavailable
    case verificationFailed(String)
    case nameTaken(String)   // the AIFF's name, held by an AIFF made from another file

    var description: String {
        switch self {
        case .afconvertFailed(let message), .saveFailed(let message), .verificationFailed(let message):
            return message
        case .outputFolderUnavailable:
            return "Output folder not available — choose another in “Save to”"
        case .nameTaken(let name):
            return "\(name) already exists, made from a different file — rename one of them and add it again"
        }
    }
}

/// What a single conversion did.
enum Outcome {
    case converted(URL, note: String?, checks: Checks)   // note: what wasn't lossless, e.g. "96 → 48 kHz"
    case alreadyConverted(URL)
}

/// How files are converted. Raw values are the CLI `--format` names; the Player menu picks one.
enum OutputMode: String, CaseIterable, Identifiable {
    case original   // lossless: depth matched, rate kept
    case max96      // CDJ-3000-class players: ≤24-bit, ≤96 kHz
    case max48      // CDJ-2000NXS-class players: ≤24-bit, ≤48 kHz
    case cd         // audio-CD burning: 16-bit / 44.1 kHz

    var id: String { rawValue }
}

/// Per-conversion choices.
struct ConvertOptions {
    var mode: OutputMode = .original
}

/// Core audio → AIFF conversion logic. No UI knowledge; usable headless.
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

    /// The output format for `mode`. Original is lossless; max96 and max48 cap at 24-bit and
    /// resample rates above the cap to the same family (max48: 88.2/176.4 → 44.1, 96/192 → 48;
    /// max96: 176.4 → 88.2, 192 → 96) so the ratio stays an integer; cd forces 16-bit / 44.1 kHz.
    /// All dither when reducing bit depth.
    static func outputFormat(for source: SourceFormat, mode: OutputMode) -> OutputFormat {
        let matched: Int
        switch source.depth ?? 24 {   // on detection failure, fail toward lossless
        case ...16:    matched = 16   // 16-bit (macOS decodes no FLAC below it) → BEI16
        case 17...24:  matched = 24   // 17–24-bit (incl. 20-bit) → BEI24
        default:       matched = 32   // 25–32-bit → BEI32 (should macOS decode them one day)
        }
        switch mode {
        case .original:
            return OutputFormat(depth: matched, rate: nil, dither: false)
        case .max96, .max48:
            let cap = mode == .max96 ? 96_000 : 48_000
            let depth = min(matched, 24), dither = matched > depth
            guard let rate = source.rate, rate > cap else { return OutputFormat(depth: depth, rate: nil, dither: dither) }
            return OutputFormat(depth: depth, rate: rate % 44_100 == 0 ? cap / 48_000 * 44_100 : cap, dither: dither)
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

    /// Convert one source to `destDir/<name>.aiff`. Skips if this source's AIFF already exists;
    /// fails if an AIFF of that name was made from another file. Format follows options.mode
    /// (see outputFormat); .original is lossless.
    ///
    /// The AIFF is written to a hidden temp file and renamed into place only when
    /// complete, so an existing `<name>.aiff` is always a finished file.
    @discardableResult
    static func convert(_ input: AudioSource, destDir: URL, options: ConvertOptions = ConvertOptions()) throws -> Outcome {
        let base = input.url.deletingPathExtension().lastPathComponent
        let final = destDir.appendingPathComponent(base + ".aiff")
        if FileManager.default.fileExists(atPath: final.path) { return try existing(final, for: input) }

        // The file's own header is exact; afinfo is the fallback, as it guesses 24-bit when unsure.
        let streamInfo = input.info
        let source = streamInfo.map { SourceFormat(depth: $0.bitsPerSample, rate: $0.rate) } ?? probe(input.url)
        let format = outputFormat(for: source, mode: options.mode)
        // AIFF stores its size in 32 bits: say so now rather than after most of the work.
        if let info = streamInfo, info.samples > 0 {
            let frames = Double(info.samples) * Double(format.rate ?? info.rate) / Double(info.rate)
            let bytes = frames * Double(info.channels * format.depth / 8)
            if bytes > Double(UInt32.max) - 1_000_000 {
                throw ConvertError.saveFailed(String(format: "Too long for an AIFF file: it would be %.1f GB, and AIFF files can't be larger than 4 GB", bytes / 1e9))
            }
        }

        let createdDirs = try createDirectories(destDir)
        do {
            removeStalePartialsOnce(in: destDir)
            let tmp = try reserveTemp(in: destDir)
            do {
                var args = ["-f", "AIFF"]
                if let rate = format.rate {
                    args += ["-d", "BEI\(format.depth)@\(rate)", "-r", "127", "--src-complexity", "bats"]
                } else {
                    args += ["-d", "BEI\(format.depth)"]   // with no dither: today's lossless command line
                }
                if format.dither { args += ["--dither", "1"] }   // TPDF
                let (code, err) = run(afconvert, args + [input.url.path, tmp.path])
                guard code == 0 else {
                    // A full drive makes afconvert say "ExtAudioFileWrite failed (-40)".
                    let free = (try? destDir.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
                    if let free, free < 4 << 20 {
                        throw ConvertError.saveFailed("The drive is full — there's no room for \(final.lastPathComponent). Free some space or choose another “Save to” folder")
                    }
                    if let reason = input.decodeFailureReason(afconvertError: err) { throw ConvertError.afconvertFailed(reason) }
                    throw ConvertError.afconvertFailed(err.isEmpty ? "afconvert exited with code \(code)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                // afconvert drops all tags; carry title/artist/album/cover etc. over as an ID3 chunk,
                // with a record of the source for telling same-named files apart later.
                let frames = TagIO.id3Frames(input.tags()) + [.userText(description: TagIO.sourceKey, value: input.fingerprint)]
                if let tag = TagIO.id3v23(frames) {
                    try TagIO.appendID3Chunk(tag, to: tmp)
                }

                let checks = try Verifier.verify(aiff: tmp, input: input, expected: format, writtenFrames: frames)

                guard try publish(tmp, as: final) else {
                    try? FileManager.default.removeItem(at: tmp)
                    inFlight.remove(temp: tmp)
                    return try existing(final, for: input)
                }
                inFlight.remove(temp: tmp)
                return .converted(final, note: reductionNote(source, format), checks: checks)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                inFlight.remove(temp: tmp)
                throw error
            }
        } catch {
            for dir in createdDirs.reversed() { rmdir(dir.path) }   // only removes still-empty dirs
            throw error
        }
    }

    // MARK: - Output file helpers

    /// `final` exists already: this source's earlier conversion, or another file's that shares
    /// its name. An AIFF that records no source (an earlier version's) counts as this one's.
    private static func existing(_ final: URL, for input: AudioSource) throws -> Outcome {
        if let recorded = TagIO.recordedSource(final), !input.isSource(of: recorded) {
            throw ConvertError.nameTaken(final.lastPathComponent)
        }
        return .alreadyConverted(final)
    }

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
            if fd >= 0 { close(fd); inFlight.add(temp: url); return url }
            let e = errno
            guard e == EEXIST else {
                throw ConvertError.saveFailed("Could not write to \(dir.path): \(String(cString: strerror(e)))")
            }
        }
    }

    private static var cleanedDirs = Set<String>()   // under counterLock

    /// Crash leftovers only appear between runs, so listing a folder once per process is
    /// enough: a 500-file drop into a big folder would otherwise list it 500 times.
    private static func removeStalePartialsOnce(in dir: URL) {
        counterLock.lock(); let first = cleanedDirs.insert(dir.standardizedFileURL.path).inserted; counterLock.unlock()
        if first { removeStalePartials(in: dir) }
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

    // MARK: - Stopping on quit

    /// Temp files and afconvert runs of conversions in progress, so quitting can end them.
    private final class InFlight {
        private let lock = NSLock()
        private var temps = Set<URL>()
        private var processes: [ObjectIdentifier: Process] = [:]
        private var stopping = false

        func add(temp: URL) { lock.lock(); temps.insert(temp); lock.unlock() }
        func remove(temp: URL) { lock.lock(); temps.remove(temp); lock.unlock() }
        /// False once stopAll has run: the process must not start.
        func add(_ p: Process) -> Bool { lock.lock(); defer { lock.unlock() }; if !stopping { processes[ObjectIdentifier(p)] = p }; return !stopping }
        func remove(_ p: Process) { lock.lock(); processes[ObjectIdentifier(p)] = nil; lock.unlock() }
        var isStopping: Bool { lock.lock(); defer { lock.unlock() }; return stopping }

        func stopAll() {
            lock.lock(); stopping = true; let (running, files) = (Array(processes.values), temps); lock.unlock()
            for p in running where p.isRunning { kill(p.processIdentifier, SIGKILL) }
            let deadline = Date().addingTimeInterval(2)
            for p in running { while p.isRunning && Date() < deadline { usleep(10_000) } }   // before the file it writes goes
            for f in files { unlink(f.path) }
        }
    }
    private static let inFlight = InFlight()

    /// Quitting: end any running afconvert and delete unfinished temp files, so neither is
    /// left behind on the output drive. Conversions in progress fail; nothing more starts.
    static func stopAll() { inFlight.stopAll() }

    // MARK: - Process helpers

    /// Run a tool, returning (exit code, captured stderr).
    private static func run(_ launchPath: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        guard inFlight.add(p) else { return (-1, "Quitting") }
        defer { inFlight.remove(p) }
        do { try p.run() } catch { return (-1, "\(error)") }
        if inFlight.isStopping { kill(p.processIdentifier, SIGKILL) }   // stopAll ran while it launched
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
