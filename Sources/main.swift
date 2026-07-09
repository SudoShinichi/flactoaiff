import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Headless CLI mode (used by test.sh): --convert <in.flac> <destDir>

let cliArgs = CommandLine.arguments
if cliArgs.count >= 2 && cliArgs[1] == "--convert" {
    guard cliArgs.count == 4 else {
        FileHandle.standardError.write(
            "usage: FlacToAiff --convert <in.flac> <destDir>\n".data(using: .utf8)!)
        exit(2)
    }
    do {
        let out = try Converter.convert(
            flacURL: URL(fileURLWithPath: cliArgs[2]),
            destDir: URL(fileURLWithPath: cliArgs[3], isDirectory: true)
        )
        print("OK \(out.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write("ERROR \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - GUI

/// One row in the results list.
struct FileStatus: Identifiable {
    let id = UUID()
    let name: String
    let ok: Bool
    let detail: String
}

struct DropView: View {
    @State private var targeted = false
    @State private var results: [FileStatus] = []
    @State private var produced: [URL] = []
    @State private var working = false

    private var downloadsDir: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    var body: some View {
        VStack(spacing: 12) {
            dropZone
            if !results.isEmpty && !working {
                HStack {
                    Button("Reveal in Finder") { reveal() }
                        .disabled(produced.isEmpty)
                    Spacer()
                    Button("Clear") { results = []; produced = [] }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 300)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundColor(targeted ? .accentColor : Color.secondary.opacity(0.5))
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )

            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 44, weight: .light))
                    Text(working ? "Converting…" : "Drop .flac here")
                        .font(.headline)
                    Text("Converted .aiff files are saved to Downloads")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(targeted ? .accentColor : .primary)
                .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(results) { r in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(r.ok ? .green : .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name).font(.callout)
                                    Text(r.detail).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            handleDrop(providers)
        }
    }

    private func reveal() {
        // The button is disabled while produced.isEmpty, so this always has URLs.
        NSWorkspace.shared.activateFileViewerSelecting(produced)
    }

    @discardableResult
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !working else { return false }   // C2: one batch at a time
        results = []
        produced = []
        working = true

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let u = url {
                    lock.lock(); urls.append(u); lock.unlock()
                }
            }
        }

        let dest = downloadsDir
        group.notify(queue: .global(qos: .userInitiated)) {
            for original in urls {
                var u = original
                // A Finder alias named song.flac → convert its target.
                if let vals = try? u.resourceValues(forKeys: [.isAliasFileKey]), vals.isAliasFile == true,
                   let resolved = try? URL(resolvingAliasFileAt: u) {
                    u = resolved
                }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    DispatchQueue.main.async {
                        results.append(FileStatus(name: u.lastPathComponent, ok: false,
                                                  detail: "Skipped — folders aren't supported; drop the .flac files inside"))
                    }
                    continue
                }
                do {
                    // Converter.convert is the single source of the extension check
                    // and the "Skipped — not a .flac file" message (via ConvertError).
                    let out = try Converter.convert(flacURL: u, destDir: dest)
                    DispatchQueue.main.async {
                        produced.append(out)
                        results.append(FileStatus(name: u.lastPathComponent, ok: true,
                                                  detail: "→ \(out.lastPathComponent)"))
                    }
                } catch {
                    DispatchQueue.main.async {
                        results.append(FileStatus(name: u.lastPathComponent, ok: false,
                                                  detail: "\(error)"))
                    }
                }
            }
            DispatchQueue.main.async { working = false }
        }
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false   // AppDelegate holds a strong ref; avoid over-release
        window.title = "FLAC → AIFF"
        window.contentView = NSHostingView(rootView: DropView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FLAC → AIFF",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FLAC → AIFF",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FLAC → AIFF",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
