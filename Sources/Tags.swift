import Foundation

/// A cover picture taken from a FLAC PICTURE block.
struct Picture: Equatable {
    let type: UInt8      // ID3/FLAC picture type (3 = front cover)
    let mime: String
    let data: Data
}

/// Tags read from a FLAC: Vorbis comments (keys upper-cased, repeats kept in order) + pictures.
struct Tags {
    var comments: [(key: String, value: String)] = []
    var pictures: [Picture] = []

    var isEmpty: Bool { comments.isEmpty && pictures.isEmpty }

    /// All values for `key`, joined — e.g. several ARTIST entries → "A, B".
    func value(_ key: String) -> String? {
        let vals = comments.filter { $0.key == key }.map(\.value).filter { !$0.isEmpty }
        return vals.isEmpty ? nil : vals.joined(separator: ", ")
    }
}

/// One ID3v2.3 frame as written, kept so the output can be checked against it.
enum ID3Frame: Equatable {
    case text(id: String, value: String)
    case userText(description: String, value: String)   // TXXX
    case comment(String)                                // COMM
    case picture(Picture)                               // APIC
}

/// What a FLAC's STREAMINFO block declares.
struct StreamInfo {
    let samples: Int
    let rate: Int
    let channels: Int
    let bitsPerSample: Int
    let md5: Data?   // MD5 of the decoded samples; nil when the encoder left it all zero
}

/// What an AIFF's COMM and SSND chunks declare.
struct AIFFInfo {
    let channels: Int
    let frames: Int
    let bitsPerSample: Int
    let rate: Double
    let soundDataOffset: UInt64   // file offset of the first sample
    let soundDataLength: UInt64   // bytes of sample data
}

/// FLAC tag reading and AIFF ID3 tag writing. afconvert copies audio only, so
/// without this the AIFF has no tags and players fall back to the filename.
enum TagIO {

    // MARK: - FLAC reading

    /// Read Vorbis comments and pictures from a FLAC's metadata blocks.
    /// Returns empty tags on any parse problem — missing tags must never block a conversion.
    static func readFlacTags(_ url: URL) -> Tags {
        var tags = Tags()
        guard let fh = openFlac(url) else { return tags }
        defer { try? fh.close() }

        while true {
            let header = fh.readData(ofLength: 4)
            guard header.count == 4 else { break }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            switch type {
            case 4:  // VORBIS_COMMENT
                parseVorbisComments(fh.readData(ofLength: length), into: &tags)
            case 6:  // PICTURE
                if let pic = parsePicture(fh.readData(ofLength: length)) { tags.pictures.append(pic) }
            default: // skip without reading — PADDING blocks can be megabytes
                guard (try? fh.seek(toOffset: fh.offsetInFile + UInt64(length))) != nil else { return tags }
            }
            if isLast { break }
        }
        return tags
    }

    /// STREAMINFO (always the first block) as the encoder declared it. nil if unreadable;
    /// `samples` is 0 when the encoder didn't know the length, `md5` nil when it didn't store one.
    static func flacStreamInfo(_ url: URL) -> StreamInfo? {
        guard let fh = openFlac(url) else { return nil }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 4 + 34)   // block header + STREAMINFO
        guard head.count == 38, head[head.startIndex] & 0x7F == 0 else { return nil }
        let si = head.startIndex + 4
        // Bytes 10–17 of STREAMINFO: 20-bit rate, 3-bit channels, 5-bit depth, 36-bit total samples.
        let packed = head[(si + 10)..<(si + 18)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let rate = Int(packed >> 44), samples = Int(packed & (1 << 36 - 1))
        let channels = Int(packed >> 41 & 0x7) + 1, bits = Int(packed >> 36 & 0x1F) + 1
        let md5 = Data(head[(si + 18)..<(si + 34)])   // bytes 18–33
        return rate > 0 ? StreamInfo(samples: samples, rate: rate, channels: channels, bitsPerSample: bits,
                                     md5: md5.contains { $0 != 0 } ? md5 : nil) : nil
    }

    /// The FLAC opened just past its "fLaC" marker. Some taggers put an ID3v2 tag in front of
    /// it, which decoders skip, so skip it too rather than losing the FLAC's tags and checks.
    private static func openFlac(_ url: URL) -> FileHandle? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        var marker = fh.readData(ofLength: 4)
        if marker.prefix(3) == Data("ID3".utf8) {
            let rest = fh.readData(ofLength: 6)   // minor version, flags, syncsafe size
            guard rest.count == 6 else { try? fh.close(); return nil }
            let i = rest.startIndex
            let size = rest[(i + 2)..<(i + 6)].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
            let footer = rest[i + 1] & 0x10 != 0 ? 10 : 0
            guard (try? fh.seek(toOffset: UInt64(10 + size + footer))) != nil else { try? fh.close(); return nil }
            marker = fh.readData(ofLength: 4)
        }
        guard marker == Data("fLaC".utf8) else { try? fh.close(); return nil }
        return fh
    }

    private static func parseVorbisComments(_ d: Data, into tags: inout Tags) {
        var r = Reader(d)
        guard let vendorLen = r.u32le(), r.skip(Int(vendorLen)), let count = r.u32le() else { return }
        for _ in 0..<count {
            guard let len = r.u32le(), let bytes = r.bytes(Int(len)) else { return }
            guard let s = String(data: bytes, encoding: .utf8), let eq = s.firstIndex(of: "=") else { continue }
            // A NUL can't survive in an ID3 text frame (readers stop at it), so "A\0B" becomes
            // the repeated values A and B, like any other repeated key, and a name drops its NULs.
            let key = s[..<eq].uppercased().replacingOccurrences(of: "\0", with: "")   // same for a name
            guard !key.isEmpty else { continue }
            for part in s[s.index(after: eq)...].split(separator: "\0") { tags.comments.append((key, String(part))) }
        }
    }

    private static func parsePicture(_ d: Data) -> Picture? {
        var r = Reader(d)
        guard let type = r.u32be(),
              let mimeLen = r.u32be(), let mime = r.bytes(Int(mimeLen)),
              let descLen = r.u32be(), r.skip(Int(descLen)),
              r.skip(16),   // width, height, depth, colour count
              let dataLen = r.u32be(), let data = r.bytes(Int(dataLen)),
              !data.isEmpty else { return nil }   // an empty placeholder isn't artwork
        return Picture(type: UInt8(clamping: type),
                       mime: String(data: mime, encoding: .ascii) ?? "image/jpeg",
                       data: data)
    }

    // MARK: - ID3v2.3 building

    /// Vorbis comment key → ID3v2.3 text frame. v2.3 rather than v2.4 because
    /// it is what rekordbox, Serato and older Apple software read reliably.
    private static let textFrames: [(vorbis: String, frame: String)] = [
        ("TITLE", "TIT2"), ("ARTIST", "TPE1"), ("ALBUM", "TALB"),
        ("ALBUMARTIST", "TPE2"), ("GENRE", "TCON"), ("COMPOSER", "TCOM"),
        ("BPM", "TBPM"), ("INITIALKEY", "TKEY"), ("ISRC", "TSRC"),
        ("ORGANIZATION", "TPUB"), ("LABEL", "TPUB"), ("COPYRIGHT", "TCOP"),
        ("REMIXER", "TPE4"), ("CONDUCTOR", "TPE3"),
    ]

    /// Keys consumed by a dedicated frame; everything else goes to TXXX.
    private static let handledKeys: Set<String> = Set(textFrames.map(\.vorbis)).union([
        "DATE", "YEAR", "TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS",
        "DISCNUMBER", "DISCTOTAL", "TOTALDISCS", "COMMENT", "DESCRIPTION",
        "WAVEFORMATEXTENSIBLE_CHANNEL_MASK",   // afconvert's own bookkeeping, not a tag
    ])

    /// The ID3v2.3 frames to write for `tags`, in file order.
    static func id3Frames(_ tags: Tags) -> [ID3Frame] {
        var frames = [ID3Frame]()
        var written = Set<String>()

        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty, !written.contains(id) else { return }
            written.insert(id)
            frames.append(.text(id: id, value: value))
        }

        for (key, id) in textFrames { text(id, tags.value(key)) }
        // v2.3 TYER holds a bare 4-digit year; DATE is often "2026-03-01".
        if let date = tags.value("DATE") ?? tags.value("YEAR") {
            text("TYER", String(date.prefix(4)))
        }
        text("TRCK", numberWithTotal(tags.value("TRACKNUMBER"),
                                     tags.value("TRACKTOTAL") ?? tags.value("TOTALTRACKS")))
        text("TPOS", numberWithTotal(tags.value("DISCNUMBER"),
                                     tags.value("DISCTOTAL") ?? tags.value("TOTALDISCS")))
        if let comment = tags.value("COMMENT") ?? tags.value("DESCRIPTION") {
            frames.append(.comment(comment))
        }
        for (key, _) in tags.comments where !handledKeys.contains(key) {
            guard let value = tags.value(key), !written.contains("TXXX:" + key) else { continue }
            written.insert("TXXX:" + key)
            frames.append(.userText(description: key, value: value))
        }
        frames += tags.pictures.map { .picture($0) }
        return frames
    }

    /// Build a complete ID3v2.3 tag (header + frames), or nil if there is nothing to write.
    static func id3v23(_ tags: Tags) -> Data? { id3v23(id3Frames(tags)) }

    static func id3v23(_ frames: [ID3Frame]) -> Data? {
        var body = Data()
        for f in frames {
            switch f {
            case .text(let id, let value):
                body += frame(id, [0x01] + utf16(value))
            case .comment(let comment):
                body += frame("COMM", [0x01] + Data("eng".utf8) + utf16("") + [0, 0] + utf16(comment))
            case .userText(let description, let value):
                body += frame("TXXX", [0x01] + utf16(description) + [0, 0] + utf16(value))
            case .picture(let pic):
                // Latin-1 encoding, empty description: maximally compatible.
                body += frame("APIC", [0x00] + Data(pic.mime.utf8) + [0x00, pic.type, 0x00] + pic.data)
            }
        }
        guard !body.isEmpty else { return nil }
        return Data("ID3".utf8) + [3, 0, 0] + syncsafe(body.count) + body
    }

    /// "3" + "12" → "3/12"; leaves an existing "3/12" alone.
    private static func numberWithTotal(_ number: String?, _ total: String?) -> String? {
        guard let number else { return nil }
        guard let total, !number.contains("/") else { return number }
        return "\(number)/\(total)"
    }

    private static func frame(_ id: String, _ body: Data) -> Data {
        Data(id.utf8) + be32(body.count) + [0, 0] + body   // v2.3: plain 32-bit size, no flags
    }

    /// UTF-16 with BOM — the v2.3 way to carry non-Latin text (e.g. "蒸發").
    private static func utf16(_ s: String) -> Data {
        var d = Data([0xFF, 0xFE])
        for unit in s.utf16 { d += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        return d
    }

    private static func be32(_ n: Int) -> Data {
        Data([UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
    }

    private static func syncsafe(_ n: Int) -> Data {
        Data([UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)])
    }

    // MARK: - AIFF reading

    /// The COMM format and where SSND's samples sit, or nil if the file can't be parsed.
    static func aiffInfo(_ url: URL) -> AIFFInfo? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard fh.readData(ofLength: 12).prefix(4) == Data("FORM".utf8) else { return nil }
        func be(_ d: Data) -> UInt64 { d.reduce(0) { $0 << 8 | UInt64($1) } }
        var comm: (channels: Int, frames: Int, bits: Int, rate: Double)?
        var sound: (offset: UInt64, length: UInt64)?
        while true {
            let header = fh.readData(ofLength: 8)
            guard header.count == 8 else { break }
            let size = be(header[(header.startIndex + 4)...])
            let start = fh.offsetInFile
            if header.prefix(4) == Data("COMM".utf8) {
                let d = fh.readData(ofLength: 18)
                guard size >= 18, d.count == 18 else { return nil }
                let i = d.startIndex
                // 80-bit IEEE extended: sign + 15-bit exponent, then a 64-bit mantissa with an explicit leading 1.
                let exp = Int(be(d[(i + 8)..<(i + 10)]) & 0x7FFF)
                let mant = be(d[(i + 10)..<(i + 18)])
                comm = (Int(be(d[i..<(i + 2)])), Int(be(d[(i + 2)..<(i + 6)])), Int(be(d[(i + 6)..<(i + 8)])),
                        mant == 0 ? 0 : Double(mant) * pow(2, Double(exp - 16383 - 63)))
            } else if header.prefix(4) == Data("SSND".utf8) {
                let d = fh.readData(ofLength: 8)
                guard size >= 8, d.count == 8 else { return nil }
                sound = (start + 8 + be(d[(d.startIndex + 0)..<(d.startIndex + 4)]), size - 8)
            }
            guard (try? fh.seek(toOffset: start + size + size % 2)) != nil else { break }
        }
        guard let c = comm, let s = sound else { return nil }
        return AIFFInfo(channels: c.channels, frames: c.frames, bitsPerSample: c.bits, rate: c.rate,
                        soundDataOffset: s.offset, soundDataLength: s.length)
    }

    // MARK: - AIFF writing

    /// Append an `ID3 ` chunk to an AIFF and grow the FORM size to cover it.
    static func appendID3Chunk(_ tag: Data, to aiff: URL) throws {
        let fh = try FileHandle(forUpdating: aiff)
        defer { try? fh.close() }
        let header = fh.readData(ofLength: 12)
        guard header.count == 12, header.prefix(4) == Data("FORM".utf8) else {
            throw ConvertError.afconvertFailed("Output is not an AIFF file; could not write tags")
        }
        let formSize = header[4..<8].reduce(0) { $0 << 8 | Int($1) }

        var chunk = Data("ID3 ".utf8) + be32(tag.count) + tag
        if tag.count % 2 == 1 { chunk.append(0) }   // IFF chunks are padded to even length

        // Chunks start on even offsets, so an odd FORM end means afconvert left the last
        // chunk (an odd-length SSND, e.g. mono 24-bit) without its pad byte. Add it.
        let end = 8 + formSize
        if end % 2 == 1 { chunk.insert(0, at: 0) }
        try fh.seek(toOffset: UInt64(end))
        try fh.write(contentsOf: chunk)
        try fh.truncate(atOffset: UInt64(end + chunk.count))
        try fh.seek(toOffset: 4)
        try fh.write(contentsOf: be32(end + chunk.count - 8))
    }
}

/// Bounds-checked cursor over a Data blob.
private struct Reader {
    let d: Data
    var i: Int
    init(_ d: Data) { self.d = d; self.i = d.startIndex }

    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, i + n <= d.endIndex else { return nil }
        defer { i += n }
        return d[i..<i + n]
    }
    mutating func skip(_ n: Int) -> Bool { bytes(n) != nil }
    mutating func u32le() -> UInt32? { bytes(4).map { $0.reversed().reduce(0) { $0 << 8 | UInt32($1) } } }
    mutating func u32be() -> UInt32? { bytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } } }
}
