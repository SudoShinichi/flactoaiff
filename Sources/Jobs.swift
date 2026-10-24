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
        var folderNames = FolderNames()
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

            let folderOut = outputRoot.appendingPathComponent(folderNames.name(for: url), isDirectory: true)
            let flacs = flacs(in: url)
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

    /// FLACs anywhere under `folder`, as sorted paths relative to it. Hidden files
    /// (incl. AppleDouble `._x.flac`) and package contents are skipped; symlinked FLACs count.
    static func flacs(in folder: URL) -> [String] {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        let rootDepth = folder.standardizedFileURL.pathComponents.count
        return (walker?.allObjects as? [URL] ?? [])
            .filter { file in
                file.pathExtension.lowercased() == "flac"
                    && (try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            .map { $0.standardizedFileURL.pathComponents.dropFirst(rootDepth).joined(separator: "/") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Files from the watch folder `watchRoot`: each keeps its subfolder relative to
    /// the watch folder, so `<watchRoot>/Album/01.flac` → `<outputRoot>/Album/01.aiff`.
    static func watched(_ files: [URL], root watchRoot: URL, into outputRoot: URL) -> [WorkItem] {
        let rootDepth = watchRoot.standardizedFileURL.pathComponents.count
        return files.map { file in
            let subdirs = file.standardizedFileURL.deletingLastPathComponent().pathComponents.dropFirst(rootDepth)
            let dest = subdirs.reduce(outputRoot) { $0.appendingPathComponent($1, isDirectory: true) }
            return .job(Job(source: file, destDir: dest))
        }
    }

    /// Output folder names for the folders of one drop. Different folders that share a
    /// name (A/CD1, B/CD1) get "CD1", "CD1 2", … like Finder, instead of merging; the
    /// same drop again maps the same way, so re-dropping skips what was converted.
    private struct FolderNames {
        private var byPath: [String: String] = [:]
        private var taken: Set<String> = []   // lowercased: APFS/HFS+ are case-insensitive

        mutating func name(for folder: URL) -> String {
            let path = folder.standardizedFileURL.path
            if let name = byPath[path] { return name }
            let base = folder.lastPathComponent
            var name = base, n = 2
            while taken.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
            taken.insert(name.lowercased())
            byPath[path] = name
            return name
        }
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
