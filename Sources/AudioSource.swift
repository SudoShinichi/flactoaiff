import Foundation

/// One input file the converter can read. Each input format is one type, listed in
/// `AudioSources.formats`; the converter, the folder walk and the watch folder go through it.
protocol AudioSource {
    /// Lowercased file extensions of this format.
    static var extensions: [String] { get }
    /// nil when `url` isn't this format.
    init?(url: URL)

    var url: URL { get }
    /// The format and length the file declares, or nil when it can't be read (afinfo is the fallback).
    var info: StreamInfo? { get }
    func tags() -> Tags
    /// Identifies the source among files with the same name, so an AIFF made from another
    /// file isn't mistaken for this one's. Recorded in the AIFF it becomes.
    var fingerprint: String { get }
    /// A plain reason for a failed decode, when the format can explain it better than afconvert.
    var decodeFailureReason: String? { get }
}

extension AudioSource {
    /// The audio checksum when the file declares one, else its size.
    var fingerprint: String {
        if let md5 = info?.md5 { return "md5:" + md5.map { String(format: "%02x", $0) }.joined() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return "size:\(size)"
    }
}

/// The input formats, and lookups across them.
enum AudioSources {
    static let formats: [AudioSource.Type] = [FlacSource.self]

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
