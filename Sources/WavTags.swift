import Foundation

/// WAV: the RIFF chunks, and tags from an ID3 chunk and LIST/INFO.
extension TagIO {
    // MARK: - WAV reading

    /// The chunks of a RIFF/WAVE file, or nil when it isn't one (an RF64 file, say: afinfo and
    /// afconvert take over). Chunks after a data chunk of unknown length can't be found.
    static func wavLayout(_ url: URL) -> WavLayout? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let riff = fh.readData(ofLength: 12)
        guard riff.count == 12, riff.prefix(4) == Data("RIFF".utf8), riff.suffix(4) == Data("WAVE".utf8),
              let fileSize = try? fh.seekToEnd() else { return nil }
        func le(_ d: Data) -> UInt64 { d.reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        var fmt: Data?, data: (offset: UInt64, length: UInt64?)?
        var id3: (offset: UInt64, length: UInt64)?, infoList: (offset: UInt64, length: UInt64)?
        var pos: UInt64 = 12
        while pos + 8 <= fileSize, (try? fh.seek(toOffset: pos)) != nil {
            let h = fh.readData(ofLength: 8)
            guard h.count == 8 else { break }
            let id = String(decoding: h.prefix(4), as: UTF8.self), size = le(h.suffix(4)), body = pos + 8
            switch id {
            case "fmt ": fmt = fh.readData(ofLength: Int(min(size, 64)))
            case "data":
                let known = size != 0 && size != 0xFFFF_FFFF
                data = (body, known ? size : nil)
                if !known { pos = fileSize; continue }   // the rest of the file is audio
            case "id3 ", "ID3 ": id3 = (body, size)
            case "LIST":
                if fh.readData(ofLength: 4) == Data("INFO".utf8), size >= 4 { infoList = (body + 4, size - 4) }
            default: break
            }
            pos = body + size + size % 2   // chunks are padded to even length
        }
        guard let fmt, fmt.count >= 16, let data else { return nil }
        let f = fmt.startIndex
        var tag = le(fmt[f..<(f + 2)])
        if tag == 0xFFFE, fmt.count >= 26 { tag = le(fmt[(f + 24)..<(f + 26)]) }   // EXTENSIBLE: the sub-format GUID's first two bytes
        let channels = Int(le(fmt[(f + 2)..<(f + 4)])), rate = Int(le(fmt[(f + 4)..<(f + 8)]))
        let blockAlign = Int(le(fmt[(f + 12)..<(f + 14)]))
        guard channels > 0, rate > 0, blockAlign > 0, blockAlign % channels == 0 else { return nil }
        return WavLayout(encoding: tag == 1 ? .pcm : tag == 3 ? .float : .compressed,
                         channels: channels, rate: rate, blockAlign: blockAlign, bits: blockAlign / channels * 8,
                         dataOffset: data.offset, dataLength: data.length, id3: id3, infoList: infoList)
    }

    /// A WAV's tags: its ID3 chunk (as store downloads carry), and LIST/INFO for keys the ID3 lacks.
    static func readWavTags(_ url: URL, _ layout: WavLayout) -> Tags {
        var tags = Tags()
        guard let fh = try? FileHandle(forReadingFrom: url) else { return tags }
        defer { try? fh.close() }
        func chunk(_ c: (offset: UInt64, length: UInt64)) -> Data? {
            guard c.length < 64 << 20, (try? fh.seek(toOffset: c.offset)) != nil else { return nil }
            return fh.readData(ofLength: Int(c.length))
        }
        if let id3 = layout.id3, let d = chunk(id3) { parseID3(d, into: &tags) }
        if let list = layout.infoList, let d = chunk(list) {
            var r = Reader(d)
            while let id = r.bytes(4), let size = r.u32le(), let body = r.bytes(Int(size)) {
                if size % 2 == 1 { _ = r.skip(1) }
                guard let key = infoKeys[String(decoding: id, as: UTF8.self)], tags.value(key) == nil else { continue }
                let bytes = body.prefix { $0 != 0 }
                // INFO is nominally Latin-1; most writers today put UTF-8 there.
                guard let value = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1),
                      !value.isEmpty else { continue }
                tags.comments.append((key, value))
            }
        }
        return tags
    }

    private static let infoKeys = [
        "INAM": "TITLE", "IART": "ARTIST", "IPRD": "ALBUM", "IGNR": "GENRE", "ICRD": "DATE",
        "ITRK": "TRACKNUMBER", "IPRT": "TRACKNUMBER", "ICMT": "COMMENT", "ICOP": "COPYRIGHT",
    ]
}
