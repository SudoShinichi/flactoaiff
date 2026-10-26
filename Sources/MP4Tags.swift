import AVFoundation
import Foundation

/// MP4 (.m4a): where the audio is, and the iTunes tags.
extension TagIO {
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
}
