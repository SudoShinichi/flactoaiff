import Foundation

// MARK: - Headless CLI mode (used by test.sh)
//   --convert [--format original|max96|max48|cd] <file-or-folder>... <outputDir>
//   --watch   [--format …] [--catch-up-since <unix-time>] <watchDir> <outputDir>   (until killed)
//   --check   --player <name> <folder>   (USB check, read-only)

func cliUsage() -> Never {
    FileHandle.standardError.write("""
        usage: FlacToAiff --convert [--format original|max96|max48|cd] <file-or-folder>... <outputDir>
               FlacToAiff --watch [--format …] [--catch-up-since <unix-time>] <watchDir> <outputDir>
               FlacToAiff --check --player <name> <folder>
        <name>: \(Player.all.map(\.id).joined(separator: ", "))

        """.data(using: .utf8)!)
    exit(2)
}

/// `OK`/`SKIP` to stdout, `ERROR` to stderr, flushed at once. Returns false for an ERROR.
func cliPrint(_ row: Row) -> Bool {
    switch row.kind {
    case .converted:
        print("OK \(row.output!.path)\t\(row.checks ?? "")")
        if let warning = row.warning { print("NOTE \(row.name): \(warning)") }
    case .alreadyConverted: print("SKIP \(row.output!.path)")
    case .info:             print("NOTE \(row.name): \(row.detail)")
    case .skipped, .failed:
        FileHandle.standardError.write("ERROR \(row.name): \(row.detail)\n".data(using: .utf8)!)
    }
    fflush(stdout)
    return row.kind != .skipped && row.kind != .failed
}

/// Killed (Ctrl-C, kill): end the running afconvert and delete its temp file before exiting.
var cliSignalSources: [DispatchSourceSignal] = []
func cliStopOnSignals() {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { Converter.stopAll(); exit(128 + sig) }
        source.resume()
        cliSignalSources.append(source)
    }
}
