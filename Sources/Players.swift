import Foundation

/// A DJ player the USB check knows: what it plays from USB. Player limits come from the
/// manufacturers' specifications (sources beside each entry); wrong data here is the fastest way
/// to lose a DJ's trust, so change a value only with a source.
struct Player: Identifiable, Hashable {
    let id: String              // the CLI's --player name
    let name: String
    let plays: Set<String>      // AudioSource names it plays from USB, besides AIFF
    let rates: Set<Int>         // sample rates it plays (Hz)
    let depths: Set<Int>        // bit depths it plays

    private static let lossless: Set<String> = [FlacSource.name, WavSource.name, AlacSource.name]
    private static let upTo96: Set<Int> = [44_100, 48_000, 88_200, 96_000]
    private static let upTo48: Set<Int> = [44_100, 48_000]

    static let all: [Player] = [
        // CDJ-3000X manual p. 12 (WAV/AIFF/ALAC/FLAC: 16/24-bit, 44.1–96 kHz); the CDJ-3000 is the same.
        Player(id: "cdj-3000", name: "CDJ-3000 / CDJ-3000X", plays: lossless, rates: upTo96, depths: [16, 24]),
        // CDJ-2000NXS2 manual p. 7; AlphaTheta support: "96 kHz … 24 bits".
        Player(id: "cdj-2000nxs2", name: "CDJ-2000NXS2", plays: lossless, rates: upTo96, depths: [16, 24]),
        // github.com/joeselway/Pioneer-DJ-File-Formats (table from the manuals).
        Player(id: "opus-quad", name: "OPUS-QUAD", plays: lossless, rates: upTo96, depths: [16, 24]),
        Player(id: "xdj-1000mk2", name: "XDJ-1000MK2", plays: lossless, rates: upTo48, depths: [16, 24]),
        // Same table: FLAC since a 2019 firmware update on the XDJ-XZ; no ALAC on either.
        Player(id: "xdj-rx3", name: "XDJ-RX3 / XDJ-XZ", plays: [FlacSource.name, WavSource.name],
               rates: upTo48, depths: [16, 24]),
        // CDJ-2000NXS manual p. 7 (WAV/AIFF 44.1/48 kHz, 16/24-bit; no FLAC or ALAC); the others per the same table.
        Player(id: "cdj-2000nxs", name: "CDJ-2000NXS / CDJ-900NXS / XDJ-1000 / XDJ-700",
               plays: [WavSource.name], rates: upTo48, depths: [16, 24]),
    ]

    static func named(_ id: String) -> Player? { all.first { $0.id == id } }

    /// The Format choice that makes files this player plays.
    var format: OutputMode { (rates.max() ?? 0) > 48_000 ? .max96 : .max48 }
}

/// The Format menu: titles and the text under it. The player names come from `Player.all`.
extension OutputMode {
    var title: String {
        switch self {
        case .original: return "Original (lossless)"
        case .max96:    return "Up to 24-bit / 96 kHz"
        case .max48:    return "Up to 24-bit / 48 kHz"
        case .cd:       return "Audio CD: 16-bit / 44.1 kHz"
        }
    }

    var explanation: String {
        switch self {
        case .original:
            return "Same quality as the source. For Apple Music, software, and players that take any file."
        case .max96, .max48:
            let names = Player.all.filter { $0.format == self }.map(\.name)
            let list = names.dropLast().joined(separator: ", ") + (names.count > 1 ? " and " : "") + (names.last ?? "")
            let khz = self == .max96 ? "96 or 88.2" : "48 or 44.1"
            return "For the \(list). Higher sample rates are lowered to \(khz) kHz, 32-bit files to 24-bit. "
                + "Based on the manufacturers' specifications; check your player's manual."
        case .cd:
            return "Makes everything 16-bit / 44.1 kHz, the audio CD format, for burning CDs."
        }
    }
}
