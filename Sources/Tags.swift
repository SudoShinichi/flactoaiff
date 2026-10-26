import AVFoundation
import Foundation

/// A cover picture taken from a FLAC PICTURE block.
struct Picture: Equatable {
    let type: UInt8      // ID3/FLAC picture type (3 = front cover)
    let mime: String
    let data: Data
}

/// Tags read from a source, as Vorbis comments (keys upper-cased, repeats kept in order) +
/// pictures. Other formats' tags are mapped onto the same keys.
struct Tags {
    var comments: [(key: String, value: String)] = []
    var pictures: [Picture] = []

    /// Add what `other` has and these tags lack: its keys missing here, its pictures if there are none.
    mutating func fill(from other: Tags) {
        let missing = Set(other.comments.map(\.key)).filter { value($0) == nil }
        comments += other.comments.filter { missing.contains($0.key) }
        if pictures.isEmpty { pictures = other.pictures }
    }

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

/// Where a WAV's audio and tags are, and what its fmt chunk declares.
struct WavLayout {
    enum Encoding { case pcm, float, compressed }
    let encoding: Encoding
    let channels: Int
    let rate: Int
    let blockAlign: Int
    let bits: Int                 // the sample container's, so 20-bit audio in 24-bit slots counts as 24
    let dataOffset: UInt64
    let dataLength: UInt64?       // nil when the writer left it 0 or 0xFFFFFFFF (streamed, length unknown)
    let id3: (offset: UInt64, length: UInt64)?
    let infoList: (offset: UInt64, length: UInt64)?
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

    // MARK: - iTunes (MP4) reading

    /// An MP4 file's top-level `mdat` payload: the encoded audio, which retagging doesn't touch.
    static func mp4MediaData(_ url: URL) -> (offset: UInt64, length: UInt64)? {
        guard let fh = try? FileHandle(forReadingFrom: url), let end = try? fh.seekToEnd() else { return nil }
        defer { try? fh.close() }
        var pos: UInt64 = 0
        while pos + 8 <= end, (try? fh.seek(toOffset: pos)) != nil {
            let h = fh.readData(ofLength: 8)
            guard h.count == 8 else { return nil }
            var size = h.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }, header: UInt64 = 8
            if size == 1 {   // 64-bit size follows
                let big = fh.readData(ofLength: 8)
                guard big.count == 8 else { return nil }
                size = big.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }; header = 16
            } else if size == 0 {   // to the end of the file
                size = end - pos
            }
            guard size >= header else { return nil }
            if h.suffix(4) == Data("mdat".utf8) { return (pos + header, min(size, end - pos) - header) }
            pos += size
        }
        return nil
    }

    /// An .m4a's iTunes tags, through AVFoundation, mapped onto the same keys as FLAC's.
    /// Free-form ----:com.apple.iTunes:NAME fields keep their name (INITIALKEY, LABEL…).
    static func readITunesTags(_ url: URL) -> Tags {
        var tags = Tags()
        let freeform = "itlk/com.apple.iTunes."
        for item in AVURLAsset(url: url).metadata(forFormat: .iTunesMetadata) {
            guard let id = item.identifier?.rawValue else { continue }
            if id.hasPrefix(freeform) {
                let name = String(id.dropFirst(freeform.count))
                // iTunSMPB, iTunNORM…: gapless and volume data for players, not tags.
                guard !name.hasPrefix("iTun"), let value = item.stringValue, !value.isEmpty else { continue }
                tags.comments.append((name.uppercased(), value))
                continue
            }
            switch id {
            case "itsk/trkn", "itsk/disk":   // two padding bytes, the number, the total (16-bit each)
                guard let d = item.dataValue, d.count >= 6 else { continue }
                let b = Array(d), number = Int(b[2]) << 8 | Int(b[3]), total = Int(b[4]) << 8 | Int(b[5])
                let (key, totalKey) = id == "itsk/trkn" ? ("TRACKNUMBER", "TRACKTOTAL") : ("DISCNUMBER", "DISCTOTAL")
                if number > 0 { tags.comments.append((key, String(number))) }
                if number > 0 && total > 0 { tags.comments.append((totalKey, String(total))) }
            case "itsk/tmpo":
                if let bpm = item.numberValue?.intValue, bpm > 0 { tags.comments.append(("BPM", String(bpm))) }
            case "itsk/gnre":   // older iTunes: a standard genre as its ID3v1 number, plus one
                guard let d = item.dataValue, d.count >= 2 else { continue }
                let n = Int(d[d.startIndex]) << 8 | Int(d[d.startIndex + 1])
                if n >= 1, n <= id3v1Genres.count { tags.comments.append(("GENRE", id3v1Genres[n - 1])) }
            case "itsk/cpil":
                if item.numberValue?.intValue == 1 { tags.comments.append(("COMPILATION", "1")) }
            case "itsk/covr":
                guard let d = item.dataValue, !d.isEmpty else { continue }
                let png = d.starts(with: [0x89, 0x50, 0x4E, 0x47])
                tags.pictures.append(Picture(type: 3, mime: png ? "image/png" : "image/jpeg", data: d))
            default:
                guard let key = iTunesKeys[id], let value = item.stringValue, !value.isEmpty else { continue }
                tags.comments.append((key, value))
            }
        }
        return tags
    }

    private static let iTunesKeys = [
        "itsk/%A9nam": "TITLE", "itsk/%A9ART": "ARTIST", "itsk/%A9alb": "ALBUM", "itsk/aART": "ALBUMARTIST",
        "itsk/%A9gen": "GENRE", "itsk/%A9wrt": "COMPOSER", "itsk/%A9day": "DATE", "itsk/%A9cmt": "COMMENT",
        "itsk/cprt": "COPYRIGHT", "itsk/%A9grp": "GROUPING",
    ]

    /// The ID3v1 genres (0–79) and Winamp's extensions (80–125), which iTunes's `gnre` numbers.
    private static let id3v1Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebob", "Latin", "Revival", "Celtic", "Bluegrass",
        "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock", "Big Band", "Chorus",
        "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony", "Booty Bass",
        "Primus", "Porn Groove", "Satire", "Slow Jam", "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad",
        "Rhythmic Soul", "Freestyle", "Duet", "Punk Rock", "Drum Solo", "A capella", "Euro-House", "Dance Hall",
    ]

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
