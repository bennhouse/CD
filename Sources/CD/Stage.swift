import AppKit
import SwiftUI

// The window: the disc column, and the queue to its right while music plays.
//
// Showing the queue makes the window wider by the queue's width (and narrower again when it goes).
// During that animation the disc column keeps its width, so nothing inside it moves: the window
// edge simply uncovers (or covers) the queue. Only when the window can't grow (full screen, or no
// room on the screen) does the column make room instead, with a SwiftUI animation.

/// Sizes of the interface, 30% smaller than CD 1.0 (texts and buttons keep their size).
enum Metrics {
    static let queueWidth: CGFloat = 240
    /// The title bar needs this much for the volume and the four transport buttons.
    static let minColumn: CGFloat = 330
    static let minHeight: CGFloat = 345
    static let infoHeight: CGFloat = 86
    static let spacing: CGFloat = 17
    static let discMax: CGFloat = 323
    static let discMin: CGFloat = 132
    /// How far around the disc's square the pointer still counts as hovering it.
    static let hoverMargin: CGFloat = 48
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
        // The accent colour follows the CD.
        .tint(player.accent?.color ?? Color.accentColor)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                VolumeSlider()
            }
            // Flexible space: volume on the left, the transport on the right.
            ToolbarItem(placement: .automatic) { Spacer() }
            ToolbarItemGroup(placement: .automatic) {
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

/// A plain volume slider: full (the standard level) to silent. Drawn by hand, because the system
/// slider in a title bar ignores the accent colour: the filled part is in the CD's colour.
struct VolumeSlider: View {
    @ObservedObject private var player = Player.shared
    @Environment(\.controlActiveState) private var active
    @State private var dragging = false
    private let width: CGFloat = 96
    private let knob: CGFloat = 15

    var body: some View {
        let accent = player.accent?.color ?? Color.accentColor
        let travel = width - knob
        let x = CGFloat(player.volume) * travel
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
            Capsule().fill(active == .inactive ? Color.secondary.opacity(0.6) : accent)
                .frame(width: x + knob / 2, height: 4)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(dragging ? 0.3 : 0.2), radius: dragging ? 2.5 : 1.5, y: 0.5)
                .frame(width: knob, height: knob)
                .offset(x: x)
        }
        .frame(width: width, height: 22)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            dragging = true
            player.volume = Double(min(1, max(0, (g.location.x - knob / 2) / travel)))
        }.onEnded { _ in dragging = false })
        .padding(.horizontal, 6)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(player.volume * 100)) percent")
        .accessibilityAdjustableAction { d in
            player.volume = min(1, max(0, player.volume + (d == .increment ? 0.1 : -0.1)))
        }
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
    /// The album whose CD is rising in (its disc runs the entrance once).
    @State private var entering: UUID?

    var body: some View {
        GeometryReader { geo in
            let side = max(Metrics.discMin, min(Metrics.discMax, min(geo.size.width - 50, geo.size.height - Metrics.infoHeight - Metrics.spacing - 40)))
            let top = max(14, (geo.size.height - side - Metrics.spacing - Metrics.infoHeight) / 2)
            // From its place to just below the bottom of the window.
            let travel = geo.size.height - top + 12
            ZStack(alignment: .top) {
                // The housing: the empty, frosted disc the CDs go into. It never moves, lifts or casts a shadow.
                Housing(side: side)
                // Keyed by album, so the disc that leaves is the very view that was on screen (same angle).
                ForEach([leaving, card].compactMap { $0 }) { c in
                    let isCurrent = c.id == card.id
                    // A CD with a cover moves in Core Animation (its own layers); SwiftUI moves the rest.
                    let layered = c.cover != nil
                    let exitDistance = geo.size.width / 2 + side / 2 + 30
                    VStack(spacing: Metrics.spacing) {
                        disc(c, side: side, current: isCurrent,
                             enterFrom: isCurrent && entering == c.id ? travel : nil,
                             exitBy: isCurrent ? nil : exitDistance)
                            .offset(y: isCurrent && !layered ? (1 - arrive) * travel : 0)
                            .offset(x: !isCurrent && !layered ? -leave * exitDistance : 0)
                            .opacity(!isCurrent && !layered ? 1 - Double(leave) * 0.4 : 1)
                        info(c)
                            .frame(width: max(side + 60, 300), height: Metrics.infoHeight, alignment: .top)
                            // The new title is uncovered from the disc's lower edge down as the disc rises past it.
                            .mask(alignment: .top) {
                                Rectangle()
                                    .frame(height: Metrics.infoHeight + travel + 40)
                                    .offset(y: isCurrent ? -Metrics.spacing + (1 - arrive) * travel : -Metrics.spacing)
                            }
                            .offset(x: isCurrent ? 0 : -leave * exitDistance)
                            .opacity(isCurrent ? 1 : 1 - Double(leave) * 0.4)
                    }
                    .zIndex(isCurrent ? 1 : 0)
                }
                // Hover anywhere around the disc (its square plus a wide margin), whatever is in it: the CD
                // lifts and the corner buttons appear. No tooltips here. A click on the CD plays or pauses it; on the empty housing it opens a
                // folder too.
                let canChange = player.state != .playing
                let margin = Metrics.hoverMargin
                ZStack(alignment: .center) {
                    Color.clear
                        .frame(width: side, height: side)
                        .contentShape(DiscShape(), eoFill: true)
                        // Click the CD to play it (and again to pause); click the empty housing to open one.
                        .onTapGesture {
                            if card.isEmpty { if canChange { Actions.open() } } else { player.togglePlayPause() }
                        }
                        .overlay(alignment: .topLeading) {
                            CornerButton(symbol: card.isEmpty ? "folder" : "arrow.triangle.2.circlepath", shown: hover, delay: 0) {
                                Actions.open()
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if !card.isEmpty {
                                CornerButton(symbol: "xmark", shown: hover, delay: 0.04) { player.eject() }
                            }
                        }
                }
                .frame(width: side + 2 * margin, height: side + 2 * margin)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 0.3)) { hover = h && canChange } }
                .padding(.top, -margin)
                .zIndex(2)
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
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            leaving = card
            leave = 0
            card = new
            arrive = 0
            hover = false
            entering = new.id
        }
        let old = leaving?.id
        // Next frame, from those starting values: the old disc speeds away, the new one comes in fast
        // and lands softly.
        DispatchQueue.main.async {
            withAnimation(Swap.animation(Swap.exitCurve, Swap.exitDuration)) { leave = 1 }
            withAnimation(Swap.animation(Swap.enterCurve, Swap.enterDuration).delay(Swap.enterDelay)) { arrive = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if leaving?.id == old { leaving = nil } }
        }
    }

    /// A CD: the cover on a disc, lifted while hovered.
    /// The empty card has no CD: only the housing shows.
    @ViewBuilder
    private func disc(_ c: AlbumCard, side: CGFloat, current: Bool, enterFrom: CGFloat?, exitBy: CGFloat?) -> some View {
        // Shadow and lift only while hovered: never at rest, never on a CD that is leaving.
        let lifted = current && hover
        if let cover = c.cover {
            DiscView(cover: cover, spinning: current && player.state == .playing, lifted: lifted, animateLift: current,
                     label: "", enterFrom: enterFrom, exitBy: exitBy)
                .frame(width: side, height: side)
                .allowsHitTesting(false)
        } else if !c.isEmpty {
            // An album without a cover: a plain light disc, which lifts like the others.
            DiscShape().fill(Color(nsColor: .controlBackgroundColor), style: FillStyle(eoFill: true))
                .overlay(DiscShape().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(lifted ? 0.32 : 0), radius: 13, y: 6)
                .scaleEffect(lifted ? DiscNSView.liftScale : 1)
                .transaction { if !current { $0.animation = nil } }
                .frame(width: side, height: side)
                .allowsHitTesting(false)
        } else {
            Color.clear.frame(width: side, height: side)
        }
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


/// Where the CD goes: a frosted, recessed disc. It never moves, lifts or casts a shadow.
struct Housing: View {
    let side: CGFloat

    var body: some View {
        ZStack {
            DiscShape().fill(.regularMaterial, style: FillStyle(eoFill: true))
            // A faint inner edge: a hollow, not a raised disc.
            DiscShape().stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .frame(width: side, height: side)
    }
}

/// A round button in a corner of the disc's square. It comes in rising a little and coming into focus,
/// and leaves quicker, softening in place.
struct CornerButton: View {
    let symbol: String
    let shown: Bool
    let delay: Double
    let action: () -> Void
    @State private var pressedHover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(pressedHover ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .scaleEffect(pressedHover ? 1.06 : 1)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { pressedHover = h } }
        .opacity(shown ? 1 : 0)
        .blur(radius: shown ? 0 : 4)
        .offset(y: shown ? 0 : 5)
        .animation(shown ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.36).delay(0.06 + delay) : .easeIn(duration: 0.14), value: shown)
        .allowsHitTesting(shown)
        .padding(2)
    }
}
