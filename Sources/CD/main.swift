import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var player = Player.shared

    var body: some Scene {
        Window("CD", id: "main") {
            ContentView()
        }
        .defaultSize(width: 560, height: 620)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { Actions.open() }.keyboardShortcut("o")
            }
            CommandMenu("Controls") {
                Button(player.state == .playing ? "Pause" : "Play") { player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(player.tracks.isEmpty)
                Button("Stop") { player.stop() }.keyboardShortcut(".")
                    .disabled(player.state == .stopped)
                Divider()
                Button("Next Track") { player.skip() }.keyboardShortcut(.rightArrow)
                    .disabled(player.state == .stopped)
                Button("Previous Track") { player.previous() }.keyboardShortcut(.leftArrow)
                    .disabled(player.state == .stopped)
            }
        }
    }
}

/// The queue: double click a track to play it, drag to reorder.
struct QueuePanel: View {
    @ObservedObject private var player = Player.shared
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Queue").font(.headline).tone(.primary)
                Spacer()
                if let t = player.current { TimeLabel(duration: t.duration) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Divider().padding(.horizontal, 12)
            List(selection: $selection) {
                ForEach(player.tracks) { t in
                    QueueRow(track: t, index: (player.tracks.firstIndex(of: t) ?? 0) + 1,
                             current: t.id == player.currentID, playing: player.state == .playing,
                             failed: player.failed.contains(t.id))
                        .tag(t.id)
                        .listRowSeparator(.hidden)
                }
                .onMove { player.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first {
                    Button("Play") { player.jump(to: id) }
                }
            } primaryAction: { ids in
                if let id = ids.first { player.jump(to: id) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .padding(.vertical, 16)
        .padding(.trailing, 16)
        .padding(.leading, 4)
    }
}

struct TimeLabel: View {
    @ObservedObject private var clock = Clock.shared
    let duration: Double
    var body: some View {
        Text("\(Format.time(Double(clock.seconds))) / \(Format.time(duration))")
            .font(.callout).monospacedDigit().tone(.secondary)
    }
}

struct QueueRow: View {
    let track: Track
    let index: Int
    let current: Bool
    let playing: Bool
    let failed: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if current {
                    Image(systemName: playing ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(track.number ?? index)").monospacedDigit().tone(.tertiary)
                }
            }
            .frame(width: 24, alignment: .trailing)
            Text(track.title).fontWeight(current ? .semibold : .regular).tone(failed ? .tertiary : .primary).lineLimit(1)
            Spacer(minLength: 6)
            Text(failed ? "Can't play" : Format.time(track.duration)).monospacedDigit().font(.callout).tone(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

enum Format {
    static func time(_ t: Double) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    static func long(_ t: Double) -> String {
        let m = Int((t / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
enum Actions {
    static func open() {
        let panel = NSOpenPanel()
        panel.title = "Open Album"
        panel.message = "Choose a folder of music, or some tracks."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .audio]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Player.shared.open(panel.urls)
    }

    static func load(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { lock.lock(); urls.append(u); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { if !urls.isEmpty { Player.shared.open(urls) } }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Snapshots.startIfRequested()
            let env = ProcessInfo.processInfo.environment
            let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
            if let p = env["CD_OPEN"] {
                Player.shared.open([URL(fileURLWithPath: p)])
            } else if !args.isEmpty {
                Player.shared.open(args.map { URL(fileURLWithPath: $0) })
            }
            if let d = env["CD_PLAY"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + d) { MainActor.assumeIsolated { Player.shared.play() } }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Player.shared.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--render" {
    exit(MainActor.assumeIsolated { CLI.render(Array(CommandLine.arguments.dropFirst(2))) })
} else {
    CDApp.main()
}
