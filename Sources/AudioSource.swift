import AudioToolbox
import CryptoKit
import Foundation

/// One input file the converter can read. Each input format is one type, listed in
/// `AudioSources.formats`; the converter, the folder walk and the watch folder go through it.
protocol AudioSource {
    /// The format's name in messages: "FLAC", "WAV".
    static var name: String { get }
    /// Lowercased file extensions of this format.
    static var extensions: [String] { get }
    /// nil when `url` isn't this format.
    init?(url: URL)

    var url: URL { get }
    /// The format and length the file declares, or nil when it can't be read (afinfo is the fallback).
    var info: StreamInfo? { get }
    func tags() -> Tags
    /// MD5 of the samples in FLAC's form (signed little-endian, ceil(bits/8) bytes each), or
    /// nil when there is none. A lossless AIFF must hash to the same.
    func audioChecksum() -> Data?
    /// Where the encoded audio sits in the file (not the tags), or nil when unknown.
    var audioRange: (offset: UInt64, length: UInt64)? { get }
    /// Why this file is left alone without trying, or nil to convert it.
    var skipReason: String? { get }
    /// A plain reason for a failed decode, given afconvert's error, when the format can explain
    /// it better than afconvert.
    func decodeFailureReason(afconvertError: String) -> String?
}

extension AudioSource {
    func audioChecksum() -> Data? { info?.md5 }
    var audioRange: (offset: UInt64, length: UInt64)? { nil }
    var skipReason: String? { nil }
    func decodeFailureReason(afconvertError: String) -> String? { nil }

    /// Identifies the source among files with the same name, so an AIFF made from another
    /// file isn't mistaken for this one's; recorded in the AIFF it becomes. Retagging must not
    /// change it, and it must be cheap: "Already converted" checks it for every file added again.
    /// A FLAC's own MD5 when it has one; else the length and format with a hash of the audio's
    /// first and last 64 KiB; the file size only when neither can be read.
    var fingerprint: String {
        if let md5 = info?.md5 { return "md5:" + hex(md5) }
        if let i = info, let range = audioRange, let edges = edgeHash(range) {
            return "audio:\(i.samples):\(i.rate):\(i.channels):\(i.bitsPerSample):\(edges)"
        }
        return "size:\(fileSize)"
    }

    /// Whether `recorded`, the fingerprint an existing AIFF holds, is this file's. AIFFs made
    /// before 2026-10-26 recorded a WAV's full MD5, or an ALAC file's size: those still match.
    func isSource(of recorded: String) -> Bool {
        if recorded == fingerprint { return true }
        if recorded.hasPrefix("md5:"), info?.md5 == nil, let md5 = audioChecksum() { return recorded == "md5:" + hex(md5) }
        if recorded.hasPrefix("size:") { return recorded == "size:\(fileSize)" }
        return false
    }

    private var fileSize: Int { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// MD5 of the first and last 64 KiB of `range` (all of it when shorter).
    private func edgeHash(_ range: (offset: UInt64, length: UInt64)) -> String? {
        guard range.length > 0, let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let edge: UInt64 = 64 << 10
        var md5 = Insecure.MD5()
        for start in range.length > 2 * edge ? [range.offset, range.offset + range.length - edge] : [range.offset] {
            guard (try? fh.seek(toOffset: start)) != nil else { return nil }
            let d = fh.readData(ofLength: Int(min(range.length, range.length > 2 * edge ? edge : range.length)))
            guard !d.isEmpty else { return nil }
            md5.update(data: d)
        }
        return hex(Data(md5.finalize()))
    }
}

/// The input formats, and lookups across them.
enum AudioSources {
    static let formats: [AudioSource.Type] = [FlacSource.self, WavSource.self, AlacSource.self]

    /// "FLAC, WAV or ALAC", for messages about what the app takes.
    static let names: String = {
        let all = formats.map { $0.name }
        return all.dropLast().joined(separator: ", ") + (all.count > 1 ? " or " : "") + all.last!
    }()

    /// Whether `url`'s extension is one of the formats'.
    static func handles(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return formats.contains { $0.extensions.contains(ext) }
    }

    static func open(_ url: URL) -> AudioSource? {
        for format in formats { if let source = format.init(url: url) { return source } }
        return nil
    }
}

struct FlacSource: AudioSource {
    static let name = "FLAC"
    static let extensions = ["flac"]
    let url: URL
    let info: StreamInfo?

    init?(url: URL) {
        guard url.pathExtension.lowercased() == "flac" else { return nil }
        self.url = url
        info = TagIO.flacStreamInfo(url)
    }

    func tags() -> Tags { TagIO.readFlacTags(url) }

    var audioRange: (offset: UInt64, length: UInt64)? { TagIO.flacAudioRange(url) }

    func decodeFailureReason(afconvertError: String) -> String? {
        // Apple's FLAC decoder only takes 16, 20 and 24-bit (macOS 26 still); say so plainly.
        guard let depth = info?.bitsPerSample, ![16, 20, 24].contains(depth) else { return nil }
        return "macOS can't decode \(depth)-bit FLAC — save it as 16 or 24-bit in an audio editor first"
    }
}

/// A WAV file. Its PCM samples are stored signed little-endian (unsigned at 8-bit), the form
/// FLAC's MD5 covers, so hashing the data chunk gives a checksum that doesn't depend on Apple's
/// decoder: lossless conversions verify as fully as FLAC's.
final class WavSource: AudioSource {
    static let name = "WAV"
    static let extensions = ["wav", "wave"]
    let url: URL
    let info: StreamInfo?   // md5 stays nil: audioChecksum hashes the samples on first use
    let skipReason: String?
    private let layout: WavLayout?
    private var checksum: Data??

    init?(url: URL) {
        guard Self.extensions.contains(url.pathExtension.lowercased()) else { return nil }
        self.url = url
        layout = TagIO.wavLayout(url)
        switch layout?.encoding {
        case .float?:
            skipReason = "Skipped — floating-point WAV can't become a lossless AIFF; export it as 24-bit WAV"
        case .compressed?:
            skipReason = "Skipped — this WAV holds compressed audio, not PCM"
        default:
            skipReason = nil
        }
        info = layout.flatMap { l in
            l.encoding == .pcm ? StreamInfo(samples: Int((l.dataLength ?? 0) / UInt64(l.blockAlign)), rate: l.rate,
                                            channels: l.channels, bitsPerSample: l.bits, md5: nil) : nil
        }
    }

    func tags() -> Tags { layout.map { TagIO.readWavTags(url, $0) } ?? Tags() }

    var audioRange: (offset: UInt64, length: UInt64)? {
        guard let l = layout else { return nil }
        let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return (l.dataOffset, min(l.dataLength ?? size, size > l.dataOffset ? size - l.dataOffset : 0))
    }

    func audioChecksum() -> Data? {
        if let checksum { return checksum }
        let md5 = layout.flatMap { $0.encoding == .pcm ? hashSamples($0) : nil }
        checksum = .some(md5)
        return md5
    }

    /// MD5 of the data chunk's whole frames (to the end of the file when the header doesn't
    /// give its length), 8-bit samples made signed. Streams, so memory stays flat.
    private func hashSamples(_ l: WavLayout) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let available = (try? fh.seekToEnd()).map { $0 > l.dataOffset ? $0 - l.dataOffset : 0 } ?? 0
        var remaining = min(l.dataLength ?? available, available)
        remaining -= remaining % UInt64(l.blockAlign)
        guard (try? fh.seek(toOffset: l.dataOffset)) != nil else { return nil }
        var md5 = Insecure.MD5()
        while remaining > 0 {
            var chunk = fh.readData(ofLength: Int(min(remaining, 1 << 20)))
            guard !chunk.isEmpty else { return nil }
            remaining -= UInt64(chunk.count)
            if l.bits == 8 { chunk.withUnsafeMutableBytes { for i in $0.indices { $0[i] ^= 0x80 } } }
            md5.update(data: chunk)
        }
        return Data(md5.finalize())
    }
}

/// An Apple Lossless file (.m4a). ALAC stores no checksum, and the only decoder is Apple's, the
/// one afconvert uses, so the audio can't be proven identical: length, format and tags are checked.
/// An .m4a holding AAC is skipped: as AIFF it would only be larger.
struct AlacSource: AudioSource {
    static let name = "ALAC"
    static let extensions = ["m4a"]
    let url: URL
    let info: StreamInfo?
    let skipReason: String?

    init?(url: URL) {
        guard url.pathExtension.lowercased() == "m4a" else { return nil }
        self.url = url
        var file: ExtAudioFileRef?
        var format = AudioStreamBasicDescription(), frames: Int64 = 0
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size), framesSize = UInt32(MemoryLayout<Int64>.size)
        defer { if let file { ExtAudioFileDispose(file) } }
        // Unreadable (a download whose index isn't there yet): afconvert gets to say why.
        guard ExtAudioFileOpenURL(url as CFURL, &file) == noErr, let file,
              ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &formatSize, &format) == noErr else {
            info = nil; skipReason = nil; return
        }
        guard format.mFormatID == kAudioFormatAppleLossless else {
            info = nil
            skipReason = "Skipped — this .m4a is AAC, which is lossy: as AIFF it would be 5–10 times larger and sound no better"
            return
        }
        _ = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &framesSize, &frames)
        // ALAC's format flags name the source depth: 1 = 16, 2 = 20, 3 = 24, 4 = 32-bit.
        info = [1: 16, 2: 20, 3: 24, 4: 32][Int(format.mFormatFlags)].map {
            StreamInfo(samples: Int(max(frames, 0)), rate: Int(format.mSampleRate),
                       channels: Int(format.mChannelsPerFrame), bitsPerSample: $0, md5: nil)
        }
        skipReason = nil
    }

    func tags() -> Tags { TagIO.readITunesTags(url) }

    var audioRange: (offset: UInt64, length: UInt64)? { TagIO.mp4MediaData(url) }

    // afconvert's own words for a cut-off or broken .m4a are a four-letter code ('wht?'). Other
    // failures (a full drive, say) aren't the file's fault, so afconvert's message stands.
    func decodeFailureReason(afconvertError: String) -> String? {
        guard info == nil || afconvertError.contains("input file") else { return nil }
        return "Couldn't read this ALAC file — it may still be downloading, or be damaged"
    }
}
