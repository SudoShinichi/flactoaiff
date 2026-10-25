import Foundation

/// A choice in the Player menu: how files are converted for it, and what it plays as is.
/// Player limits come from the manufacturer's manuals (sources beside each entry); wrong data
/// here is the fastest way to lose a DJ's trust, so change a value only with a source.
struct Player: Identifiable, Hashable {
    let id: String              // the CLI's --player name and the stored setting
    let name: String
    let mode: OutputMode
    let plays: Set<String>      // AudioSource names it plays from USB; empty for Original and CD
    let rates: Set<Int>         // sample rates it plays (Hz)
    let depths: Set<Int>        // bit depths it plays

    private static let lossless: Set<String> = [FlacSource.name, WavSource.name, AlacSource.name]
    private static let upTo96: Set<Int> = [44_100, 48_000, 88_200, 96_000]
    private static let upTo48: Set<Int> = [44_100, 48_000]

    static let original = Player(id: "original", name: "Original (lossless)", mode: .original, plays: [], rates: [], depths: [])
    static let cd = Player(id: "cd", name: "Audio CD", mode: .cd, plays: [], rates: [], depths: [])

    static let all: [Player] = [
        original,
        // CDJ-3000X manual p. 12 (WAV/AIFF/ALAC/FLAC: 16/24-bit, 44.1–96 kHz); the CDJ-3000 is the same.
        Player(id: "cdj-3000", name: "CDJ-3000 / CDJ-3000X", mode: .max96, plays: lossless, rates: upTo96, depths: [16, 24]),
        // CDJ-2000NXS2 manual p. 7; AlphaTheta support: "96 kHz … 24 bits".
        Player(id: "cdj-2000nxs2", name: "CDJ-2000NXS2", mode: .max96, plays: lossless, rates: upTo96, depths: [16, 24]),
        // github.com/joeselway/Pioneer-DJ-File-Formats (table from the manuals).
        Player(id: "opus-quad", name: "OPUS-QUAD", mode: .max96, plays: lossless, rates: upTo96, depths: [16, 24]),
        Player(id: "xdj-1000mk2", name: "XDJ-1000MK2", mode: .max48, plays: lossless, rates: upTo48, depths: [16, 24]),
        // Same table: FLAC since a 2019 firmware update on the XDJ-XZ; no ALAC on either.
        Player(id: "xdj-rx3", name: "XDJ-RX3 / XDJ-XZ", mode: .max48, plays: [FlacSource.name, WavSource.name],
               rates: upTo48, depths: [16, 24]),
        // CDJ-2000NXS manual p. 7 (WAV/AIFF 44.1/48 kHz, 16/24-bit; no FLAC or ALAC); the others per the same table.
        Player(id: "cdj-2000nxs", name: "CDJ-2000NXS / CDJ-900NXS / XDJ-1000 / XDJ-700", mode: .max48,
               plays: [WavSource.name], rates: upTo48, depths: [16, 24]),
        cd,
    ]

    static func named(_ id: String) -> Player? { all.first { $0.id == id } }

    /// Whether the player takes `source` as it is, so converting it can be skipped.
    func playsAsIs(_ source: AudioSource) -> Bool {
        guard plays.contains(type(of: source).name), let info = source.info else { return false }
        return rates.contains(info.rate) && depths.contains(info.bitsPerSample)
    }

    /// The text under the menu.
    var explanation: String {
        switch mode {
        case .original:
            return "Same quality as the source. For Apple Music, software, and players that take any file."
        case .cd:
            return "Makes everything 16-bit / 44.1 kHz, the audio CD format, for burning CDs."
        case .max96, .max48:
            let khz = mode == .max96 ? "96" : "48"
            let formats = ([FlacSource.name, WavSource.name, AlacSource.name].filter(plays.contains) + ["AIFF"])
            let list = formats.dropLast().joined(separator: ", ") + " and " + formats.last!
            return "Plays \(list) up to 24-bit / \(khz) kHz. Higher sample rates are lowered to \(khz) kHz, "
                + "32-bit files to 24-bit. Based on the manufacturer's specifications; check your player's manual."
        }
    }
}
