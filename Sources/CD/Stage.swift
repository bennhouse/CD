import AppKit
import SwiftUI

// The window: the disc column, and the queue to its right while music plays.
//
// Showing the queue makes the window wider by the queue's width (and narrower again when it goes).
// During that animation the disc column keeps its width, so nothing inside it moves: the window
// edge simply uncovers (or covers) the queue. Only when the window can't grow (full screen, or no
// room on the screen) does the column make room instead, with a SwiftUI animation.

enum Metrics {
    static let queueWidth: CGFloat = 340
    static let minColumn: CGFloat = 360
    static let minHeight: CGFloat = 430
    static let infoHeight: CGFloat = 86
    static let spacing: CGFloat = 24
}

@MainActor
final class WindowSizer: ObservableObject {
    static let shared = WindowSizer()
    weak var window: NSWindow? {
        didSet {
            guard let window, window !== oldValue else { return }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { WindowSizer.shared.collapseForSave() }
            }
        }
    }
    /// Width the disc column holds while the window frame animates.
    @Published private(set) var frozenColumn: CGFloat?
    /// The queue takes part in the layout (it may still be fading in or out).
    @Published private(set) var queueShown = false
    @Published private(set) var queueOpacity: Double = 0
    private var generation = 0

    /// Frame animation: quick start, long soft landing.
    private static let duration = 0.46
    private static let curve = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.12, 1)

    var minWidth: CGFloat { Metrics.minColumn + (queueShown && frozenColumn == nil ? Metrics.queueWidth : 0) }

    func setQueue(_ show: Bool) {
        guard show != queueShown || frozenColumn != nil else { return }
        generation += 1
        let gen = generation
        let q = Metrics.queueWidth
        guard let w = window, let content = w.contentView else {
            queueShown = show
            queueOpacity = show ? 1 : 0
            return
        }
        let column = frozenColumn ?? (content.bounds.width - (queueShown ? q : 0))
        var f = w.frame
        let screen = w.screen?.visibleFrame ?? f
        let canResize = !w.styleMask.contains(.fullScreen) && !w.isZoomed

        if show {
            queueShown = true
            if canResize, f.width + q <= screen.width {
                frozenColumn = column
                f.size.width += q
                if f.maxX > screen.maxX { f.origin.x = max(screen.minX, screen.maxX - f.width) }
                withAnimation(.easeOut(duration: 0.32).delay(0.1)) { queueOpacity = 1 }
                animate(w, to: f) { if self.generation == gen { self.frozenColumn = nil } }
            } else {
                frozenColumn = nil
                withAnimation(.smooth(duration: Self.duration)) { queueOpacity = 1 }
            }
        } else {
            withAnimation(.easeIn(duration: 0.18)) { queueOpacity = 0 }
            if canResize, f.width - q >= Metrics.minColumn {
                frozenColumn = column
                f.size.width -= q
                animate(w, to: f) {
                    guard self.generation == gen else { return }
                    self.queueShown = false
                    self.frozenColumn = nil
                }
            } else {
                frozenColumn = nil
                withAnimation(.smooth(duration: Self.duration)) { queueShown = false }
            }
        }
    }

    /// Quitting or closing with the queue open: give back its width first, so the saved frame is the
    /// window without the queue (otherwise every session would open 340 pt wider).
    func collapseForSave() {
        guard queueShown, let w = window, !w.styleMask.contains(.fullScreen) else { return }
        var f = w.frame
        f.size.width = max(Metrics.minColumn, f.width - Metrics.queueWidth)
        generation += 1
        queueShown = false
        queueOpacity = 0
        frozenColumn = nil
        w.setFrame(f, display: false)
        w.saveFrame(usingName: w.frameAutosaveName)
    }

    private func animate(_ w: NSWindow, to f: NSRect, done: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.duration
            ctx.timingFunction = Self.curve
            w.animator().setFrame(f, display: true)
        } completionHandler: {
            MainActor.assumeIsolated { done() }
        }
    }
}

/// Hands the hosting NSWindow to the sizer.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ v: NSView, context: Context) {}
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated { WindowSizer.shared.window = window }
        }
    }
}

struct ContentView: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var sizer = WindowSizer.shared
    @State private var dropTargeted = false

    var body: some View {
        GeometryReader { geo in
            let col = sizer.frozenColumn ?? max(Metrics.minColumn, geo.size.width - (sizer.queueShown ? Metrics.queueWidth : 0))
            ZStack(alignment: .topLeading) {
                DiscStage()
                    .frame(width: col, height: geo.size.height)
                QueuePanel()
                    .frame(width: Metrics.queueWidth, height: geo.size.height)
                    .offset(x: col)
                    .opacity(sizer.queueOpacity)
                    .allowsHitTesting(sizer.queueShown)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(minWidth: sizer.minWidth, minHeight: Metrics.minHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor())
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Actions.load(providers)
            return true
        }
        .onChange(of: player.queueVisible) { _, v in sizer.setQueue(v) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                VolumeSlider()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { player.previous() } label: { Image(systemName: "backward.end.fill").toolbarIcon() }
                    .help("Previous Track")
                    .disabled(player.state == .stopped)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill").toolbarIcon()
                        .frame(width: 22)
                }
                    .help(player.state == .playing ? "Pause" : "Play")
                    .disabled(player.tracks.isEmpty)
                Button { player.skip() } label: { Image(systemName: "forward.end.fill").toolbarIcon() }
                    .help("Next Track")
                    .disabled(player.state == .stopped)
                Button { player.stop() } label: { Image(systemName: "stop.fill").toolbarIcon() }
                    .help("Stop")
                    .disabled(player.state == .stopped)
            }
        }
    }
}

/// A plain volume slider: full (the standard level) to silent.
struct VolumeSlider: View {
    @ObservedObject private var player = Player.shared
    var body: some View {
        Slider(value: $player.volume, in: 0...1)
            .controlSize(.small)
            .frame(width: 96)
            .help("Volume")
            .padding(.horizontal, 6)
    }
}

/// What the stage shows for one album: its disc and the lines below it.
struct AlbumCard: Identifiable {
    let id: UUID
    let cover: CGImage?
    let title: String
    let subtitle: String?
    let details: String?
    let isEmpty: Bool

    static let empty = AlbumCard(id: UUID(), cover: nil, title: "No Album",
                                 subtitle: "Drop a folder of music here, or click the disc.", details: nil, isEmpty: true)

    @MainActor
    static func from(_ p: Player) -> AlbumCard {
        guard !p.tracks.isEmpty else { return .empty }
        var parts = ["\(p.tracks.count) \(p.tracks.count == 1 ? "track" : "tracks")", Format.long(p.totalDuration)]
        if p.discCount > 1 { parts.insert("\(p.discCount) discs", at: 0) }
        if let f = p.formatSummary { parts.append(f) }
        return AlbumCard(id: p.albumToken, cover: p.cover, title: p.albumTitle ?? "Unknown Album",
                         subtitle: [p.albumArtist, p.year].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                         details: parts.joined(separator: " · "), isEmpty: false)
    }
}

/// The disc and the album, always at the same place in the column.
/// A new album: the old disc leaves to the left, the new one rises from below the window and, as its
/// lower edge passes over the text area, uncovers the new title. Hovering the stopped disc offers to
/// change it: the disc darkens and moves a little to the left; a click opens another folder.
struct DiscStage: View {
    @ObservedObject private var player = Player.shared
    @State private var card = AlbumCard.empty
    @State private var leaving: AlbumCard?
    @State private var arrive: CGFloat = 1
    @State private var leave: CGFloat = 0
    @State private var hover = false
    /// The album whose disc is shaded: the hovered one, kept while it is ejected.
    @State private var shaded: UUID?

    var body: some View {
        GeometryReader { geo in
            let side = max(170, min(420, min(geo.size.width - 80, geo.size.height - Metrics.infoHeight - Metrics.spacing - 64)))
            let top = max(20, (geo.size.height - side - Metrics.spacing - Metrics.infoHeight) / 2)
            // From its place to just below the bottom of the window.
            let travel = geo.size.height - top + 12
            ZStack(alignment: .top) {
                // Keyed by album, so the disc that leaves is the very view that was on screen (same angle).
                ForEach([leaving, card].compactMap { $0 }) { c in
                    let isCurrent = c.id == card.id
                    VStack(spacing: Metrics.spacing) {
                        disc(c, side: side, current: isCurrent)
                            .offset(y: isCurrent ? (1 - arrive) * travel : 0)
                        info(c)
                            .frame(width: max(side + 60, 300), height: Metrics.infoHeight, alignment: .top)
                            // The new title is uncovered from the disc's lower edge down as the disc rises past it.
                            .mask(alignment: .top) {
                                Rectangle()
                                    .frame(height: Metrics.infoHeight + travel + 40)
                                    .offset(y: isCurrent ? -Metrics.spacing + (1 - arrive) * travel : -Metrics.spacing)
                            }
                    }
                    .offset(x: isCurrent ? 0 : -leave * (geo.size.width / 2 + side / 2 + 30))
                    .opacity(isCurrent ? 1 : 1 - Double(leave) * 0.4)
                    .zIndex(isCurrent ? 1 : 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .padding(.top, top)
        }
        .clipped()
        .onAppear { card = AlbumCard.from(player) }
        .onChange(of: player.albumToken) { _, _ in swap(to: AlbumCard.from(player)) }
        .onReceive(NotificationCenter.default.publisher(for: .cdDebugHover)) { n in
            withAnimation(.smooth(duration: 0.28)) { hover = (n.object as? Bool ?? false) && player.state != .playing }
        }
        .onChange(of: player.state) { _, s in if s == .playing, hover { withAnimation(.smooth(duration: 0.25)) { hover = false } } }
    }

    private func swap(to new: AlbumCard) {
        let wasHovered = hover
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            leaving = card
            leave = 0
            card = new
            arrive = 0
            hover = false
            shaded = wasHovered ? leaving?.id : nil
        }
        let old = leaving?.id
        // Next frame, from those starting values: the old disc speeds away, the new one comes in fast
        // and lands softly.
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.45, 0, 0.85, 0.35, duration: 0.3)) { leave = 1 }
            withAnimation(.timingCurve(0.12, 0.72, 0.22, 1, duration: 0.62).delay(0.08)) { arrive = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if leaving?.id == old { leaving = nil } }
        }
    }

    @ViewBuilder
    private func disc(_ c: AlbumCard, side: CGFloat, current: Bool) -> some View {
        let canChange = current && player.state != .playing
        ZStack {
            if let cover = c.cover {
                DiscView(cover: cover, spinning: current && player.state == .playing)
            } else {
                DiscShape().fill(.regularMaterial, style: FillStyle(eoFill: true))
                    .overlay(DiscShape().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
            if (current && hover) || (!current && shaded == c.id) {
                DiscShape().fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                VStack(spacing: 6) {
                    Image(systemName: "eject.fill").font(.system(size: 24, weight: .medium))
                    Text(c.isEmpty ? "Open Album" : "Change CD").font(.headline)
                }
                .foregroundStyle(.white)
                .offset(y: side * 0.21)
            }
        }
        .frame(width: side, height: side)
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .offset(x: (current && hover) || (!current && shaded == c.id) ? -16 : 0)
        .contentShape(DiscShape(), eoFill: true)
        .onHover { h in
            guard current else { return }
            withAnimation(.smooth(duration: 0.28)) { hover = h && canChange }
        }
        .onTapGesture { if canChange { Actions.open() } }
        .help(canChange ? (c.isEmpty ? "Open Album…" : "Change CD…") : "")
    }

    private func info(_ c: AlbumCard) -> some View {
        VStack(spacing: 5) {
            Text(c.title)
                .font(.title2.weight(.semibold)).tone(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
            if let s = c.subtitle {
                Text(s).font(c.isEmpty ? .callout : .body).tone(.secondary).lineLimit(1)
            }
            if let d = c.details {
                Text(d).font(.callout).monospacedDigit().tone(.tertiary).lineLimit(1).padding(.top, 3)
            }
        }
    }
}
