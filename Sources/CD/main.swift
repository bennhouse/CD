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
        .defaultSize(width: 420, height: 470)
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
            // No selection: a track is played with the ▶ that replaces its number on hover; rows are
            // dragged to reorder. The playing track is marked in the accent colour.
            List {
                ForEach(player.tracks) { t in
                    let current = t.id == player.currentID
                    QueueRow(track: t, index: (player.tracks.firstIndex(of: t) ?? 0) + 1,
                             current: current, playing: player.state == .playing,
                             failed: player.failed.contains(t.id)) { player.jump(to: t.id) }
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.tint.opacity(current ? 0.16 : 0))
                                .padding(.horizontal, 6)
                        )
                }
                .onMove { player.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
        .padding(.vertical, 11)
        .padding(.trailing, 11)
        .padding(.leading, 3)
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
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        let showPlay = hover && !failed && !(current && playing)
        HStack(spacing: 10) {
            // The number column keeps its size whatever it shows, so rows never move: the number, the
            // speaker of the playing track and the hover ▶ are drawn on top of each other.
            Text("\(track.number ?? index)")
                .monospacedDigit()
                .tone(.tertiary)
                .opacity(current || showPlay ? 0 : 1)
                .frame(width: 24, alignment: .center)
                .overlay {
                    Image(systemName: playing ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .opacity(current && !showPlay ? 1 : 0)
                }
                .overlay {
                    // On hover the number becomes a small play button: the way to play another track.
                    Button(action: play) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(.tint.opacity(0.18)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .scaleEffect(showPlay ? 1 : 0.7)
                    .opacity(showPlay ? 1 : 0)
                    .allowsHitTesting(showPlay)
                }
            Text(track.title).fontWeight(current ? .semibold : .regular).tone(failed ? .tertiary : .primary).lineLimit(1)
            Spacer(minLength: 6)
            Text(failed ? "Can't play" : Format.time(track.duration)).monospacedDigit().font(.callout).tone(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        // Test aid: CD_ROWHOVER=<n> shows row n as hovered.
        .onAppear { if ProcessInfo.processInfo.environment["CD_ROWHOVER"].flatMap(Int.init) == index { hover = true } }
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

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { WindowSizer.shared.collapseForSave() }
    }
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--accent" {
    // CD --accent IMAGE|AUDIO|FOLDER...: the accent colour of each cover and its contrast.
    for a in CommandLine.arguments.dropFirst(2) {
        let u = URL(fileURLWithPath: a)
        var img: CGImage?
        if let d = try? Data(contentsOf: u), let i = Library.downscale(d, 900) { img = i }
        if img == nil { img = Library.cover(for: Library.audioFiles(in: [u]).compactMap(Library.read)) }
        func hex(_ c: NSColor) -> String { String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)) }
        if let acc = Accent.from(img) {
            let l = RGB(Double(acc.light.redComponent), Double(acc.light.greenComponent), Double(acc.light.blueComponent))
            let d = RGB(Double(acc.dark.redComponent), Double(acc.dark.greenComponent), Double(acc.dark.blueComponent))
            print(String(format: "%@  light %@ (%.2f:1)  dark %@ (%.2f:1)", u.lastPathComponent, hex(acc.light), l.contrast(with: Accent.lightBackground),
                         hex(acc.dark), d.contrast(with: Accent.darkBackground)))
        } else {
            print("\(u.lastPathComponent)  system accent (\(img == nil ? "no cover" : "no colour"))")
        }
    }
    exit(0)
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--render" {
    exit(MainActor.assumeIsolated { CLI.render(Array(CommandLine.arguments.dropFirst(2))) })
} else {
    CDApp.main()
}
