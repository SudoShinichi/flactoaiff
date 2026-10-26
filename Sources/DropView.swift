import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Whether the watch folder could be watched (main thread).
final class WatchState: ObservableObject {
    @Published var unavailable = false
}

struct DropView: View {
    @ObservedObject var queue: ConversionQueue
    @ObservedObject var settings: Settings
    @ObservedObject var watchState: WatchState
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 12) {
            dropZone
            settingsBar
            ActionBar(canReveal: !queue.outputs.isEmpty && !queue.isWorking,
                      canClear: !queue.rows.isEmpty && !queue.isWorking,
                      checkStick: { player in
                          if let url = pickFolder(startingAt: URL(fileURLWithPath: "/Volumes"), prompt: "Check") {
                              queue.check(url, for: player)
                          }
                      },
                      reveal: { NSWorkspace.shared.activateFileViewerSelecting(queue.outputs) },
                      clear: { queue.clear() })
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 400)
    }

    private var settingsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Save to:").foregroundColor(.secondary)
                Button(action: chooseOutputFolder) {
                    HStack(spacing: 4) {
                        Text(settings.outputFolder.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .help(settings.outputFolder.path)
                Spacer()
            }
            HStack(spacing: 6) {
                Text("Watch:").foregroundColor(.secondary)
                Menu {
                    Button("Choose Folder…") {
                        if let url = pickFolder(startingAt: settings.watchFolder ?? Settings.downloads, prompt: "Watch") {
                            settings.watchFolder = url
                        }
                    }
                    if settings.watchFolder != nil {
                        Button("Stop Watching") { settings.watchFolder = nil }
                    }
                } label: {
                    Text(settings.watchFolder?.lastPathComponent ?? "Off")
                }
                .fixedSize()
                .help(settings.watchFolder?.path ?? "Convert new \(AudioSources.names) files that land in a folder, while the app is open")
                if settings.watchFolder != nil && watchState.unavailable {
                    Text("Watch folder not available").font(.caption).foregroundColor(.red)
                }
                Spacer()
            }
            FormatPicker(format: $settings.format)
            Text(settings.format.explanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
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

            if queue.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 44, weight: .light))
                    Text(queue.isConverting ? "Converting…" : queue.isWorking ? "Checking…" : "Drop \(AudioSources.names) files or folders here")
                        .font(.headline)
                    Text("Converted .aiff files are saved to \(settings.outputFolder.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    if let watched = settings.watchFolder {
                        Text("Watching \(watched.lastPathComponent)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .foregroundColor(targeted ? .accentColor : .primary)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(queue.rows) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: row.kind.symbol)
                                    .foregroundColor(row.kind.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).font(.callout)
                                    Text(row.detail).font(.caption).foregroundColor(.secondary)
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

    private func chooseOutputFolder() {
        if let url = pickFolder(startingAt: settings.outputFolder, prompt: "Save Here") {
            settings.outputFolder = url
        }
    }

    private func pickFolder(startingAt start: URL, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
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

        // Drops while a batch runs are queued behind it.
        group.notify(queue: .main) {
            self.queue.enqueue(urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        }
        return true
    }
}

/// The Format menu.
struct FormatPicker: View {
    @Binding var format: OutputMode

    var body: some View {
        Picker("Format:", selection: $format) {
            ForEach(OutputMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .font(.callout)
    }
}

/// The window's bottom row: the USB check, and what to do with the rows.
struct ActionBar: View {
    let canReveal: Bool, canClear: Bool
    let checkStick: (Player) -> Void, reveal: () -> Void, clear: () -> Void

    var body: some View {
        HStack {
            Menu("Check USB Stick") {
                ForEach(Player.all) { player in
                    Button("For \(player.name)…") { checkStick(player) }
                }
            }
            .fixedSize()
            .help("List the tracks on a stick that a player won't play. Nothing on the stick is changed.")
            Spacer()
            Button("Reveal in Finder", action: reveal).disabled(!canReveal)
            Button("Clear", action: clear).disabled(!canClear)
        }
    }
}

private extension Row.Kind {
    var symbol: String {
        switch self {
        case .converted:        return "checkmark.circle.fill"
        case .alreadyConverted: return "forward.end.circle.fill"
        case .info:             return "info.circle.fill"
        case .skipped:          return "minus.circle.fill"
        case .failed:           return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .converted:                     return .green
        case .alreadyConverted, .skipped:    return .secondary
        case .info:                          return .accentColor
        case .failed:                        return .red
        }
    }
}
