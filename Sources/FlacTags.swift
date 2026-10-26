import Foundation

/// FLAC: STREAMINFO, Vorbis comments, pictures, and a leading ID3 block.
extension TagIO {
    // MARK: - FLAC reading

    /// Read Vorbis comments and pictures from a FLAC's metadata blocks.
    /// Returns empty tags on any parse problem — missing tags must never block a conversion.
    /// Some taggers put the tags in an ID3 block in front: it fills in what the FLAC's own lack.
    static func readFlacTags(_ url: URL) -> Tags {
        var tags = readFlacBlocks(url)
        if let id3 = leadingID3(url) {
            var extra = Tags()
            parseID3(id3, into: &extra)
            tags.fill(from: extra)
        }
        return tags
    }

    private static func readFlacBlocks(_ url: URL) -> Tags {
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

    /// Where a FLAC's audio frames are: from the end of its metadata blocks to the end of the file.
    static func flacAudioRange(_ url: URL) -> (offset: UInt64, length: UInt64)? {
        guard let fh = openFlac(url) else { return nil }
        defer { try? fh.close() }
        while true {
            let header = fh.readData(ofLength: 4)
            guard header.count == 4 else { return nil }
            let length = UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            guard (try? fh.seek(toOffset: fh.offsetInFile + length)) != nil else { return nil }
            if header[0] & 0x80 != 0 { break }
        }
        let start = fh.offsetInFile
        guard let end = try? fh.seekToEnd(), end > start else { return nil }
        return (start, end - start)
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

    /// The ID3v2 tag in front of a FLAC's "fLaC" marker, if a tagger put one there.
    private static func leadingID3(_ url: URL) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 10)
        guard head.count == 10, head.prefix(3) == Data("ID3".utf8) else { return nil }
        let size = head[6..<10].reduce(0) { $0 << 7 | Int($1 & 0x7F) }
        guard size < 64 << 20 else { return nil }
        let body = fh.readData(ofLength: size)
        return body.count == size ? head + body : nil
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
}
