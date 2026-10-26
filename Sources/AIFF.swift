import Foundation

/// AIFF: reading its format and recorded source, and adding the ID3 chunk.
extension TagIO {
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
                let offset = be(d[(d.startIndex + 0)..<(d.startIndex + 4)])   // block-alignment padding, usually 0
                guard size >= 8 + offset else { return nil }
                sound = (start + 8 + offset, size - 8 - offset)
            }
            guard (try? fh.seek(toOffset: start + size + size % 2)) != nil else { break }
        }
        guard let c = comm, let s = sound else { return nil }
        return AIFFInfo(channels: c.channels, frames: c.frames, bitsPerSample: c.bits, rate: c.rate,
                        soundDataOffset: s.offset, soundDataLength: s.length)
    }

    /// The source fingerprint an AIFF's ID3 chunk records, or nil when it records none (an
    /// earlier version's or another app's AIFF). Reads the v2.3 TXXX frames this app writes.
    static func recordedSource(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard fh.readData(ofLength: 12).prefix(4) == Data("FORM".utf8) else { return nil }
        var tag: Data?
        while tag == nil {
            let header = fh.readData(ofLength: 8)
            guard header.count == 8 else { return nil }
            let size = header[(header.startIndex + 4)...].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let start = fh.offsetInFile
            if header.prefix(4) == Data("ID3 ".utf8) { tag = fh.readData(ofLength: Int(size)) }
            guard (try? fh.seek(toOffset: start + size + size % 2)) != nil else { break }
        }
        guard let tag, tag.count >= 10, tag.prefix(3) == Data("ID3".utf8), tag[tag.startIndex + 3] == 3 else { return nil }
        var r = Reader(tag)
        _ = r.skip(10)
        while let id = r.bytes(4), id.first != 0, let size = r.u32be(), r.skip(2), let body = r.bytes(Int(size)) {
            guard id == Data("TXXX".utf8), body.first == 1 else { continue }
            // UTF-16 description, a two-byte NUL, then the UTF-16 value.
            let text = body.dropFirst()
            var end = text.startIndex
            while end + 1 < text.endIndex, text[end] != 0 || text[end + 1] != 0 { end += 2 }
            guard end + 1 < text.endIndex,
                  String(data: text[text.startIndex..<end], encoding: .utf16) == sourceKey else { continue }
            return String(data: text[(end + 2)...], encoding: .utf16)
        }
        return nil
    }

    // MARK: - AIFF writing

    /// Cut an AIFF back to `size` bytes (dropping the chunks after it) and fix the FORM size.
    static func truncateAIFF(_ aiff: URL, to size: UInt64) throws {
        let fh = try FileHandle(forUpdating: aiff)
        defer { try? fh.close() }
        try fh.truncate(atOffset: size)
        try fh.seek(toOffset: 4)
        try fh.write(contentsOf: be32(Int(size) - 8))
    }

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
