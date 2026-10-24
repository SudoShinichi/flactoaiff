import CryptoKit
import Foundation

/// What verification covered, shown next to each converted file.
struct Checks {
    var audio = false   // decoded samples match the FLAC's own MD5
    var tags = false    // the written tags read back as intended

    var label: String { audio ? "verified" : tags ? "tags verified" : "format checked" }
}

/// Checks a finished AIFF before it is published. A failure throws, so the caller discards it.
enum Verifier {
    static func verify(aiff: URL, source: StreamInfo?, expected: Converter.OutputFormat, lossless: Bool) throws -> Checks {
        if ProcessInfo.processInfo.environment["FLACTOAIFF_TEST_DAMAGE"] == "format" {   // TEST HOOK — only test.sh sets this
            damageSampleSize(aiff)
        }
        guard let info = TagIO.aiffInfo(aiff) else {
            throw ConvertError.verificationFailed("Output format is wrong (the AIFF can't be read back)")
        }

        func wrong(_ what: String, _ got: Any, _ want: Any) -> ConvertError {
            .verificationFailed("Output format is wrong (\(what): got \(got), expected \(want))")
        }
        guard info.bitsPerSample == expected.depth else { throw wrong("bit depth", info.bitsPerSample, expected.depth) }
        if let rate = expected.rate ?? source?.rate, info.rate != Double(rate) {
            throw wrong("sample rate", info.rate, rate)
        }
        if let source {
            guard info.channels == source.channels else { throw wrong("channels", info.channels, source.channels) }
            // afconvert happily converts a truncated FLAC (a download or copy still being
            // written), so check the length against STREAMINFO. Resampled lengths are within ±2.
            if source.samples > 0 {
                let want = Double(source.samples) * Double(expected.rate ?? source.rate) / Double(source.rate)
                guard abs(Double(info.frames) - want) <= 2 else {
                    throw ConvertError.afconvertFailed(
                        "FLAC is incomplete — only \(Int(Double(info.frames) / want * 100))% of the audio is there")
                }
            }
        }

        var checks = Checks()
        if lossless, let source, let md5 = source.md5, source.bitsPerSample <= info.bitsPerSample {
            guard try audioMD5(aiff, info, sourceBits: source.bitsPerSample) == md5 else {
                throw ConvertError.verificationFailed("Audio doesn't match the FLAC")
            }
            checks.audio = true
        }
        return checks
    }

    /// MD5 of the AIFF's samples in FLAC's own form: signed little-endian, ceil(bits/8) bytes
    /// each. A lossless up-conversion only appended zero bits, so shifting them off restores
    /// the source samples.
    private static func audioMD5(_ url: URL, _ info: AIFFInfo, sourceBits: Int) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: info.soundDataOffset)
        let outBytes = info.bitsPerSample / 8, srcBytes = (sourceBits + 7) / 8
        let chunk = outBytes * info.channels * (1 << 20 / (outBytes * info.channels))   // ≈1 MiB of whole frames
        var md5 = Insecure.MD5()
        var remaining = Int(info.soundDataLength)
        while remaining > 0 {
            guard let data = try fh.read(upToCount: min(chunk, remaining)), !data.isEmpty else {
                throw ConvertError.verificationFailed("Audio doesn't match the FLAC")   // SSND shorter than it claims
            }
            remaining -= data.count
            var out = [UInt8]()
            out.reserveCapacity(data.count / outBytes * srcBytes)
            var i = data.startIndex
            while i + outBytes <= data.endIndex {
                // Left-align the big-endian sample in 32 bits; its top `sourceBits` bits are the source value.
                var u = UInt32(data[i]) << 24
                if outBytes > 1 { u |= UInt32(data[i + 1]) << 16 }
                if outBytes > 2 { u |= UInt32(data[i + 2]) << 8 }
                if outBytes > 3 { u |= UInt32(data[i + 3]) }
                let v = Int32(bitPattern: u) >> Int32(32 - sourceBits)
                for k in 0..<srcBytes { out.append(UInt8(truncatingIfNeeded: v >> Int32(8 * k))) }
                i += outBytes
            }
            md5.update(data: out)
        }
        return Data(md5.finalize())
    }

    /// Test hook: change COMM's sample size (afconvert writes COMM first, at file offset 26).
    private static func damageSampleSize(_ url: URL) {
        guard let fh = try? FileHandle(forUpdating: url) else { return }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: 12)) != nil, fh.readData(ofLength: 4) == Data("COMM".utf8),
              (try? fh.seek(toOffset: 26)) != nil, let old = fh.readData(ofLength: 2).last else { return }
        _ = try? fh.seek(toOffset: 26)
        try? fh.write(contentsOf: Data([0, old == 8 ? 16 : 8]))
    }
}
