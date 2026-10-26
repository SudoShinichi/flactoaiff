import Foundation

/// ID3v2: reading v2.3/v2.4 tags (WAV, FLAC), and building the v2.3 tag written into each AIFF.
extension TagIO {
    // MARK: - ID3v2 reading

    /// ID3 text frame → tag key: the reverse of `textFrames`, plus the frames written apart from it.
    private static let id3Keys: [String: String] = {
        var keys = ["TYER": "DATE", "TDRC": "DATE", "TRCK": "TRACKNUMBER", "TPOS": "DISCNUMBER"]
        for (vorbis, frame) in textFrames where keys[frame] == nil { keys[frame] = vorbis }
        return keys
    }()

    /// Read an ID3v2.3 or v2.4 tag into `tags`: known text frames, TXXX, COMM and APIC.
    /// Anything it can't read safely (v2.2, compressed or encrypted frames) is left out.
    static func parseID3(_ tag: Data, into tags: inout Tags) {
        var r = Reader(tag)
        guard let head = r.bytes(10), head.prefix(3) == Data("ID3".utf8) else { return }
        let h = head.startIndex, version = head[h + 3], flags = head[h + 5]
        guard version == 3 || version == 4 else { return }
        func syncsafe(_ d: Data) -> Int { d.reduce(0) { $0 << 7 | Int($1 & 0x7F) } }
        let end = min(tag.startIndex + 10 + syncsafe(head[(h + 6)..<(h + 10)]), tag.endIndex)
        // v2.3 unsynchronises the whole tag; v2.4 marks each frame (and may mark the tag too).
        var frameData = Data(tag[(tag.startIndex + 10)..<end])
        if version == 3 && flags & 0x80 != 0 { frameData = resynchronised(frameData) }
        var frames = Reader(frameData)
        if flags & 0x40 != 0 {   // extended header: v2.3 counts its size without itself, v2.4 with
            guard let size = frames.bytes(4) else { return }
            _ = frames.skip(version == 3 ? Int(size.reduce(0) { $0 << 8 | UInt32($1) }) : syncsafe(size) - 4)
        }
        while let idBytes = frames.bytes(4), idBytes.first != 0, let sizeBytes = frames.bytes(4),
              let frameFlags = frames.bytes(2) {
            let size = version == 4 ? syncsafe(sizeBytes) : Int(sizeBytes.reduce(0) { $0 << 8 | UInt32($1) })
            guard var body = frames.bytes(size) else { return }
            let format = frameFlags[frameFlags.startIndex + 1]
            if version == 3 ? format & 0xC0 != 0 : format & 0x0C != 0 { continue }   // compressed, encrypted
            if version == 4 && format & 0x02 != 0 { body = resynchronised(body) }
            if version == 4 && format & 0x01 != 0 { body = body.dropFirst(4) }       // data length indicator
            guard let encoding = body.first else { continue }
            let id = String(decoding: idBytes, as: UTF8.self), text = body.dropFirst()
            switch id {
            case "TXXX":
                guard let (description, value) = terminated(text, encoding),
                      let key = id3String(description, encoding)?.uppercased(), !key.isEmpty else { continue }
                for v in id3Strings(value, encoding) { tags.comments.append((key, v)) }
            case "COMM":
                // Language, short description, text. A described one (iTunNORM…) is player data.
                guard text.count > 3, let (description, value) = terminated(text.dropFirst(3), encoding),
                      id3String(description, encoding)?.isEmpty ?? true else { continue }
                for v in id3Strings(value, encoding) { tags.comments.append(("COMMENT", v)) }
            case "APIC":
                guard let mimeEnd = text.firstIndex(of: 0), mimeEnd + 1 < text.endIndex else { continue }
                let mime = String(decoding: text[text.startIndex..<mimeEnd], as: UTF8.self)
                let type = text[mimeEnd + 1]
                guard let (_, data) = terminated(text[(mimeEnd + 2)...], encoding), !data.isEmpty else { continue }
                tags.pictures.append(Picture(type: type, mime: mime.isEmpty ? "image/jpeg" : mime, data: Data(data)))
            default:
                guard let key = id3Keys[id] else { continue }
                for v in id3Strings(text, encoding) { tags.comments.append((key, v)) }
            }
        }
    }

    /// Undo ID3 unsynchronisation: every FF 00 back to FF.
    private static func resynchronised(_ d: Data) -> Data {
        var out = Data(capacity: d.count)
        var previous: UInt8 = 0
        for b in d {
            if !(previous == 0xFF && b == 0x00) { out.append(b) }
            previous = b
        }
        return out
    }

    /// Split at the first terminator of `encoding` (one NUL, or two aligned NULs for UTF-16).
    private static func terminated(_ d: Data, _ encoding: UInt8) -> (Data, Data)? {
        if encoding == 1 || encoding == 2 {
            var i = d.startIndex
            while i + 1 < d.endIndex { if d[i] == 0 && d[i + 1] == 0 { return (d[d.startIndex..<i], d[(i + 2)...]) }; i += 2 }
            return nil
        }
        guard let i = d.firstIndex(of: 0) else { return nil }
        return (d[d.startIndex..<i], d[(i + 1)...])
    }

    private static func id3String(_ d: Data, _ encoding: UInt8) -> String? {
        switch encoding {
        case 0: return String(data: d, encoding: .isoLatin1)
        case 1: return d.isEmpty ? "" : String(data: d, encoding: .utf16)
        case 2: return String(data: d, encoding: .utf16BigEndian)
        case 3: return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    /// A text frame's values: v2.4 separates several with NULs, each UTF-16 one with its own BOM.
    private static func id3Strings(_ d: Data, _ encoding: UInt8) -> [String] {
        guard let s = id3String(d, encoding) else { return [] }
        return s.split(separator: "\0").map { $0.replacingOccurrences(of: "\u{FEFF}", with: "") }.filter { !$0.isEmpty }
    }

    // MARK: - ID3v2.3 building

    /// Vorbis comment key → ID3v2.3 text frame. v2.3 rather than v2.4 because
    /// it is what rekordbox, Serato and older Apple software read reliably.
    private static let textFrames: [(vorbis: String, frame: String)] = [
        ("TITLE", "TIT2"), ("ARTIST", "TPE1"), ("ALBUM", "TALB"),
        ("ALBUMARTIST", "TPE2"), ("GENRE", "TCON"), ("COMPOSER", "TCOM"),
        ("BPM", "TBPM"), ("INITIALKEY", "TKEY"), ("ISRC", "TSRC"),
        ("ORGANIZATION", "TPUB"), ("LABEL", "TPUB"), ("COPYRIGHT", "TCOP"),
        ("REMIXER", "TPE4"), ("CONDUCTOR", "TPE3"), ("GROUPING", "TIT1"),
    ]

    /// Keys consumed by a dedicated frame; everything else goes to TXXX.
    private static let handledKeys: Set<String> = Set(textFrames.map(\.vorbis)).union([
        "DATE", "YEAR", "TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS",
        "DISCNUMBER", "DISCTOTAL", "TOTALDISCS", "COMMENT", "DESCRIPTION",
        "WAVEFORMATEXTENSIBLE_CHANNEL_MASK",   // afconvert's own bookkeeping, not a tag
        sourceKey,   // written by the converter itself, once
    ])

    /// TXXX description recording which file an AIFF was made from (`AudioSource.fingerprint`).
    static let sourceKey = "FLACTOAIFF_SOURCE"

    /// The ID3v2.3 frames to write for `tags`, in file order.
    static func id3Frames(_ tags: Tags) -> [ID3Frame] {
        var frames = [ID3Frame]()
        var written = Set<String>()

        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty, !written.contains(id) else { return }
            written.insert(id)
            frames.append(.text(id: id, value: value))
        }

        // Two keys can share a frame (ORGANIZATION and LABEL → TPUB): the second keeps its own TXXX.
        var displaced: [String] = []
        for (key, id) in textFrames {
            guard let value = tags.value(key) else { continue }
            if written.contains(id) { displaced.append(key) } else { text(id, value) }
        }
        // v2.3 TYER holds a bare 4-digit year; DATE is often "2026-03-01", or "03.05.2026".
        if let date = tags.value("DATE") ?? tags.value("YEAR"),
           let year = date.range(of: "[0-9]{4}", options: .regularExpression) {
            text("TYER", String(date[year]))
        }
        text("TRCK", numberWithTotal(tags.value("TRACKNUMBER"),
                                     tags.value("TRACKTOTAL") ?? tags.value("TOTALTRACKS")))
        text("TPOS", numberWithTotal(tags.value("DISCNUMBER"),
                                     tags.value("DISCTOTAL") ?? tags.value("TOTALDISCS")))
        if let comment = tags.value("COMMENT") ?? tags.value("DESCRIPTION") {
            frames.append(.comment(comment))
        }
        for key in displaced {
            guard let value = tags.value(key), written.insert("TXXX:" + key).inserted else { continue }
            frames.append(.userText(description: key, value: value))
        }
        for (key, _) in tags.comments where !handledKeys.contains(key) {
            guard let value = tags.value(key), !written.contains("TXXX:" + key) else { continue }
            written.insert("TXXX:" + key)
            frames.append(.userText(description: key, value: value))
        }
        // Players that show one picture take the first, so the front cover leads and file icons
        // trail. A URL picture (MIME "-->") holds a link, not an image: no player shows it.
        func rank(_ p: Picture) -> Int { p.type == 3 ? 0 : p.type == 1 || p.type == 2 ? 2 : 1 }
        let pictures = tags.pictures.enumerated().filter { $0.element.mime != "-->" }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
        frames += pictures.map { .picture($0.element) }
        return frames
    }

    /// Build a complete ID3v2.3 tag (header + frames), or nil if there is nothing to write.
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

    static func be32(_ n: Int) -> Data {
        Data([UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
    }

    private static func syncsafe(_ n: Int) -> Data {
        Data([UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)])
    }
}
