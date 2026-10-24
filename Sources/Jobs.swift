import Foundation

/// One FLAC to convert, and the folder its AIFF goes into.
struct Job {
    let source: URL
    let destDir: URL
}

/// Work produced by expanding dropped items: a conversion, or a message for an input
/// that yields no conversion (e.g. a folder without FLACs).
enum WorkItem {
    case job(Job)
    case note(name: String, message: String)
}

/// The result of one work item, as listed in the window and printed by the CLI.
struct Row: Identifiable {
    enum Kind { case converted, alreadyConverted, skipped, failed }
    let id = UUID()
    let name: String
    let kind: Kind
    let detail: String
    let output: URL?   // the AIFF (converted or already converted), for Reveal in Finder
}

/// Turning dropped files/folders into work, and work into rows. UI-free.
enum Jobs {
    /// Folders are walked recursively and keep their structure under
    /// `outputRoot/<folder name>/`. Hidden files (incl. AppleDouble `._x.flac`) and
    /// non-FLAC files inside folders are ignored; single dropped files are always
    /// passed on so a non-FLAC one gets reported.
    static func expand(_ inputs: [URL], into outputRoot: URL) -> [WorkItem] {
        var items: [WorkItem] = []
        let fm = FileManager.default
        for input in inputs {
            var url = input
            // A Finder alias → its target.
            if (try? url.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true,
               let resolved = try? URL(resolvingAliasFileAt: url) {
                url = resolved
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                items.append(.job(Job(source: url, destDir: outputRoot)))
                continue
            }

            let folderOut = outputRoot.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            let flacs = (fm.subpaths(atPath: url.path) ?? [])
                .filter { rel in
                    var relIsDir: ObjCBool = false
                    return rel.lowercased().hasSuffix(".flac")
                        && !rel.split(separator: "/").contains { $0.hasPrefix(".") }
                        && fm.fileExists(atPath: url.appendingPathComponent(rel).path, isDirectory: &relIsDir)
                        && !relIsDir.boolValue
                }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if flacs.isEmpty {
                items.append(.note(name: url.lastPathComponent, message: "No .flac files found"))
            }
            for rel in flacs {
                let subdir = (rel as NSString).deletingLastPathComponent
                let dest = subdir.isEmpty ? folderOut : folderOut.appendingPathComponent(subdir, isDirectory: true)
                items.append(.job(Job(source: url.appendingPathComponent(rel), destDir: dest)))
            }
        }
        return items
    }

    /// Run one work item. `outputRoot` must already exist and be writable: a missing
    /// root (e.g. an unplugged drive) fails rather than being recreated somewhere unexpected.
    static func run(_ item: WorkItem, outputRoot: URL, options: ConvertOptions) -> Row {
        switch item {
        case .note(let name, let message):
            return Row(name: name, kind: .skipped, detail: message, output: nil)
        case .job(let job):
            let name = job.source.lastPathComponent
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: outputRoot.path, isDirectory: &isDir), isDir.boolValue,
                  FileManager.default.isWritableFile(atPath: outputRoot.path) else {
                return Row(name: name, kind: .failed,
                           detail: ConvertError.outputFolderUnavailable.description, output: nil)
            }
            do {
                switch try Converter.convert(flacURL: job.source, destDir: job.destDir, options: options) {
                case .converted(let out, let note):
                    return Row(name: name, kind: .converted,
                               detail: "→ \(out.lastPathComponent)" + (note.map { " (\($0))" } ?? ""),
                               output: out)
                case .alreadyConverted(let out):
                    return Row(name: name, kind: .alreadyConverted, detail: "Already converted", output: out)
                }
            } catch ConvertError.notFlac {
                return Row(name: name, kind: .skipped, detail: ConvertError.notFlac.description, output: nil)
            } catch {
                return Row(name: name, kind: .failed, detail: "\(error)", output: nil)
            }
        }
    }
}
