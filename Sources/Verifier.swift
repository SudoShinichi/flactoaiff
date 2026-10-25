import AVFoundation
import CryptoKit
import Foundation

/// What verification covered, shown next to each converted file.
struct Checks {
    var audio = false   // decoded samples match the FLAC's own MD5
    var tags = false    // the written tags read back as intended

    var label: String { audio ? "verified" : tags ? "tags verified" : "format checked" }
}

/// Checks a finished AIFF before it is published. A failure throws, so the caller discards it.
enum Verifier {
    static func verify(aiff: URL, source: StreamInfo?, expected: Converter.OutputFormat,
                       writtenFrames: [ID3Frame]) throws -> Checks {
        #if TEST_HOOKS   // only test.sh's own build has these; the app never reads the variable
        let damage = ProcessInfo.processInfo.environment["FLACTOAIFF_TEST_DAMAGE"]
        if damage == "format" { damageSampleSize(aiff) }
        if damage == "tags" { dropPictures(aiff, writtenFrames) }
        #endif
        guard let info = TagIO.aiffInfo(aiff) else {
            throw ConvertError.verificationFailed("Output format is wrong (the AIFF can't be read back)")
        }

        func wrong(_ what: String, _ got: Any, _ want: Any) -> ConvertError {
            .verificationFailed("Output format is wrong (\(what): got \(got), expected \(want))")
        }
        guard info.bitsPerSample == expected.depth else { throw wrong("bit depth", info.bitsPerSample, expected.depth) }
        if let rate = expected.rate ?? source?.rate, info.rate != Double(rate) {
            throw wrong("sample rate", info.rate, rate)
        }
        if let source {
            guard info.channels == source.channels else { throw wrong("channels", info.channels, source.channels) }
            // afconvert happily converts a truncated FLAC (a download or copy still being
            // written), so check the length against STREAMINFO. Resampled lengths are within ±2.
            if source.samples > 0 {
                let want = Double(source.samples) * Double(expected.rate ?? source.rate) / Double(source.rate)
                guard abs(Double(info.frames) - want) <= 2 else {
                    throw ConvertError.verificationFailed(
                        "FLAC is incomplete — only \(Int(Double(info.frames) / want * 100))% of the audio is there")
                }
            }
        }

        var checks = Checks()
        // Lossless: no resampling, no dither, and nothing cut off the source's bit depth.
        if let source, let md5 = source.md5, expected.rate == nil, !expected.dither,
           source.bitsPerSample <= expected.depth {
            guard try audioMD5(aiff, info, sourceBits: source.bitsPerSample) == md5 else {
                throw audioMismatch
            }
            checks.audio = true
        }
        if !writtenFrames.isEmpty {
            try verifyTags(aiff, writtenFrames)
            checks.tags = true
        }
        return checks
    }

    /// Read the ID3 tag back the way Apple Music does (AVFoundation) and compare every written frame.
    private static func verifyTags(_ url: URL, _ frames: [ID3Frame]) throws {
        // AVFoundation picks the container from the file extension and the temp file has none,
        // so read it through a symlink named .aiff.
        let link = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url) } catch {
            throw ConvertError.verificationFailed("Tag check failed: couldn't read tags back")
        }
        defer { try? FileManager.default.removeItem(at: link) }
        var items = AVURLAsset(url: link).metadata(forFormat: .id3Metadata)
        func take(_ matches: (AVMetadataItem) -> Bool) -> Bool {
            guard let i = items.firstIndex(where: matches) else { return false }
            items.remove(at: i)   // each frame needs its own item
            return true
        }
        for frame in frames {
            let field: String, found: Bool
            switch frame {
            case .text(let id, let value):
                field = fieldNames[id] ?? id
                found = take { $0.key as? String == id && $0.stringValue == value }
            case .userText(let description, let value):
                field = description
                found = take { $0.key as? String == "TXXX" && $0.extraAttributes?[.info] as? String == description
                    && $0.stringValue == value }
            case .comment(let value):
                field = "comment"
                found = take { $0.key as? String == "COMM" && $0.stringValue == value }
            case .picture(let pic):
                field = "artwork"
                found = take { $0.key as? String == "APIC" && $0.dataValue == pic.data }
            }
            guard found else { throw ConvertError.verificationFailed("Tag check failed: \(field)") }
        }
    }

    private static let fieldNames = [
        "TIT2": "title", "TPE1": "artist", "TALB": "album", "TPE2": "album artist", "TCON": "genre",
        "TBPM": "BPM", "TKEY": "key", "TYER": "year", "TRCK": "track number", "TPOS": "disc number",
    ]

    private static let audioMismatch = ConvertError.verificationFailed("Audio doesn't match the FLAC's checksum — the FLAC may be damaged")

    /// MD5 of the AIFF's samples in FLAC's own form: signed little-endian, ceil(bits/8) bytes
    /// each. A lossless up-conversion only appended zero bits, so shifting them off restores
    /// the source samples (and any non-zero bit there means the audio isn't the FLAC's).
    /// Streams through two reused buffers, so memory stays flat however long the file is —
    /// keep it that way: the GUI converts a whole batch in one go.
    private static func audioMD5(_ url: URL, _ info: AIFFInfo, sourceBits: Int) throws -> Data {
        let mismatch = audioMismatch
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(fd) }
        let outBytes = info.bitsPerSample / 8, srcBytes = (sourceBits + 7) / 8
        let frameBytes = outBytes * info.channels
        let chunk = frameBytes * max(1, (1 << 20) / frameBytes)   // ≈1 MiB of whole frames
        let input = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk / outBytes * srcBytes)
        defer { input.deallocate(); output.deallocate() }
        let shift = UInt32(32 - sourceBits), lowMask = UInt32.max >> UInt32(sourceBits)
        var md5 = Insecure.MD5()
        var offset = off_t(info.soundDataOffset)
        var remaining = Int(info.soundDataLength)
        while remaining > 0 {
            let want = min(chunk, remaining)
            var got = 0
            while got < want {   // pread may return less than asked
                let n = pread(fd, input + got, want - got, offset + off_t(got))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw mismatch }   // SSND shorter than it claims
                got += n
            }
            offset += off_t(got)
            remaining -= got
            let samples = got / outBytes
            let src = input.assumingMemoryBound(to: UInt8.self)
            var o = 0
            if sourceBits == info.bitsPerSample {   // no padding: just flip big-endian to little-endian
                if outBytes == 3 {
                    for i in 0..<samples { output[i * 3] = src[i * 3 + 2]; output[i * 3 + 1] = src[i * 3 + 1]; output[i * 3 + 2] = src[i * 3] }
                } else if outBytes == 2 {
                    for i in 0..<samples { output[i * 2] = src[i * 2 + 1]; output[i * 2 + 1] = src[i * 2] }
                } else {
                    for i in 0..<samples { for k in 0..<outBytes { output[i * outBytes + k] = src[i * outBytes + outBytes - 1 - k] } }
                }
                o = samples * outBytes
            } else {
                for i in 0..<samples {
                    // Left-align the big-endian sample in 32 bits; its top `sourceBits` bits are the source value.
                    let p = src + i * outBytes
                    var u = UInt32(p[0]) << 24
                    if outBytes > 1 { u |= UInt32(p[1]) << 16 }
                    if outBytes > 2 { u |= UInt32(p[2]) << 8 }
                    if outBytes > 3 { u |= UInt32(p[3]) }
                    guard u & lowMask == 0 else { throw mismatch }   // the padding bits must be zero
                    let v = Int32(bitPattern: u) >> Int32(shift)
                    for k in 0..<srcBytes { output[o + k] = UInt8(truncatingIfNeeded: v >> Int32(8 * k)) }
                    o += srcBytes
                }
            }
            md5.update(bufferPointer: UnsafeRawBufferPointer(start: output, count: o))
        }
        return Data(md5.finalize())
    }

    #if TEST_HOOKS
    /// Test hook: change COMM's sample size (afconvert writes COMM first, at file offset 26).
    private static func damageSampleSize(_ url: URL) {
        guard let fh = try? FileHandle(forUpdating: url) else { return }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: 12)) != nil, fh.readData(ofLength: 4) == Data("COMM".utf8),
              (try? fh.seek(toOffset: 26)) != nil, let old = fh.readData(ofLength: 2).last else { return }
        _ = try? fh.seek(toOffset: 26)
        try? fh.write(contentsOf: Data([0, old == 8 ? 16 : 8]))
    }

    /// Test hook: cut the ID3 chunk (always last) and write it again without its pictures.
    private static func dropPictures(_ url: URL, _ frames: [ID3Frame]) {
        guard let fh = try? FileHandle(forUpdating: url) else { return }
        var start: UInt64?
        var pos: UInt64 = 12
        while (try? fh.seek(toOffset: pos)) != nil {
            let h = fh.readData(ofLength: 8)
            guard h.count == 8 else { break }
            if h.prefix(4) == Data("ID3 ".utf8) { start = pos; break }
            let size = h[4..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            pos += 8 + size + size % 2
        }
        guard let start else { try? fh.close(); return }
        try? fh.truncate(atOffset: start)
        _ = try? fh.seek(toOffset: 4)
        try? fh.write(contentsOf: Data([UInt8(truncatingIfNeeded: (start - 8) >> 24), UInt8(truncatingIfNeeded: (start - 8) >> 16),
                                        UInt8(truncatingIfNeeded: (start - 8) >> 8), UInt8(truncatingIfNeeded: start - 8)]))
        try? fh.close()
        if let tag = TagIO.id3v23(frames.filter { if case .picture = $0 { return false } else { return true } }) {
            try? TagIO.appendID3Chunk(tag, to: url)
        }
    }
    #endif
}
