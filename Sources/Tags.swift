import Foundation

/// A cover picture taken from a FLAC PICTURE block.
struct Picture {
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

/// FLAC tag reading and AIFF ID3 tag writing. afconvert copies audio only, so
/// without this the AIFF has no tags and players fall back to the filename.
enum TagIO {

    // MARK: - FLAC reading

    /// Read Vorbis comments and pictures from a FLAC's metadata blocks.
    /// Returns empty tags on any parse problem — missing tags must never block a conversion.
    static func readFlacTags(_ url: URL) -> Tags {
        var tags = Tags()
        guard let fh = try? FileHandle(forReadingFrom: url) else { return tags }
        defer { try? fh.close() }
        guard fh.readData(ofLength: 4) == Data("fLaC".utf8) else { return tags }

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

    private static func parseVorbisComments(_ d: Data, into tags: inout Tags) {
        var r = Reader(d)
        guard let vendorLen = r.u32le(), r.skip(Int(vendorLen)), let count = r.u32le() else { return }
        for _ in 0..<count {
            guard let len = r.u32le(), let bytes = r.bytes(Int(len)) else { return }
            guard let s = String(data: bytes, encoding: .utf8), let eq = s.firstIndex(of: "=") else { continue }
            tags.comments.append((s[..<eq].uppercased(), String(s[s.index(after: eq)...])))
        }
    }

    private static func parsePicture(_ d: Data) -> Picture? {
        var r = Reader(d)
        guard let type = r.u32be(),
              let mimeLen = r.u32be(), let mime = r.bytes(Int(mimeLen)),
              let descLen = r.u32be(), r.skip(Int(descLen)),
              r.skip(16),   // width, height, depth, colour count
              let dataLen = r.u32be(), let data = r.bytes(Int(dataLen)) else { return nil }
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

    /// Build a complete ID3v2.3 tag (header + frames), or nil if there is nothing to write.
    static func id3v23(_ tags: Tags) -> Data? {
        guard !tags.isEmpty else { return nil }
        var frames = Data()
        var written = Set<String>()

        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty, !written.contains(id) else { return }
            written.insert(id)
            frames += frame(id, [0x01] + utf16(value))
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
            frames += frame("COMM", [0x01] + Data("eng".utf8) + utf16("") + [0, 0] + utf16(comment))
        }
        for (key, _) in tags.comments where !handledKeys.contains(key) {
            guard let value = tags.value(key), !written.contains("TXXX:" + key) else { continue }
            written.insert("TXXX:" + key)
            frames += frame("TXXX", [0x01] + utf16(key) + [0, 0] + utf16(value))
        }
        for pic in tags.pictures {
            // Latin-1 encoding, empty description: maximally compatible.
            frames += frame("APIC", [0x00] + Data(pic.mime.utf8) + [0x00, pic.type, 0x00] + pic.data)
        }

        guard !frames.isEmpty else { return nil }
        return Data("ID3".utf8) + [3, 0, 0] + syncsafe(frames.count) + frames
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
