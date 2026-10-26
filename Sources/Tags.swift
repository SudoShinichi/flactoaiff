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

/// Reading tags from each input format (FlacTags, WavTags, MP4Tags, ID3) and writing them into
/// the AIFF (ID3, AIFF). afconvert copies audio only, so without this the AIFF has no tags and
/// players fall back to the filename.
enum TagIO {}

/// Bounds-checked cursor over a Data blob.
struct Reader {
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
