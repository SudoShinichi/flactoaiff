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
    /// Identifies the source among files with the same name, so an AIFF made from another
    /// file isn't mistaken for this one's. Recorded in the AIFF it becomes.
    var fingerprint: String { get }
    /// Why this file is left alone without trying, or nil to convert it.
    var skipReason: String? { get }
    /// A plain reason for a failed decode, when the format can explain it better than afconvert.
    var decodeFailureReason: String? { get }
}

extension AudioSource {
    func audioChecksum() -> Data? { info?.md5 }
    var skipReason: String? { nil }
    var decodeFailureReason: String? { nil }

    /// The audio checksum when there is one, else the file's size.
    var fingerprint: String {
        if let md5 = audioChecksum() { return "md5:" + md5.map { String(format: "%02x", $0) }.joined() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return "size:\(size)"
    }
}

/// The input formats, and lookups across them.
enum AudioSources {
    static let formats: [AudioSource.Type] = [FlacSource.self, WavSource.self]

    /// "FLAC or WAV", for messages about what the app takes.
    static let names = formats.map { $0.name }.joined(separator: " or ")

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

    var decodeFailureReason: String? {
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
