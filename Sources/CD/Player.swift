import AppKit
import AVFoundation
import MediaPlayer
import SwiftUI

enum PlayState { case stopped, playing, paused }

/// The playing time, on its own so that only the views that show it are redrawn, once per second.
@MainActor
final class Clock: ObservableObject {
    static let shared = Clock()
    @Published private(set) var seconds = 0
    func set(_ t: Double) {
        let s = Int(max(0, t))
        if s != seconds { seconds = s }
    }
}

/// The album, the queue and the transport. Drives the engine, the Now Playing info and the media keys.
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var cover: CGImage?
    @Published private(set) var state: PlayState = .stopped
    @Published private(set) var currentID: UUID?
    /// Time in the current track. Not published: only the clock label follows it (see `Clock`), so the
    /// rest of the window isn't rebuilt while the music plays.
    private(set) var elapsed: Double = 0 { didSet { Clock.shared.set(elapsed) } }
    @Published private(set) var queueVisible = false
    @Published private(set) var loading = false
    @Published private(set) var failed: Set<UUID> = []
    /// Changes once per album opened, when its tracks and cover are both ready.
    @Published private(set) var albumToken = UUID()
    /// 0…1 from the title bar slider; 1 is the standard level (no gain). The slider follows a
    /// squared curve so the lower half is usable.
    @Published var volume: Double = 1 { didSet { applyVolume() } }

    private func applyVolume() {
        engine?.engine.mainMixerNode.outputVolume = muted ? 0 : Float(volume * volume)
    }

    private var engine: PlaybackEngine?
    private var timer: Timer?
    private var loadToken = UUID()
    private var configObserver: NSObjectProtocol?
    let muted = ProcessInfo.processInfo.environment["CD_MUTE"] == "1"

    init() { setUpRemoteCommands() }

    // MARK: album info

    var albumTitle: String? { mostCommon(tracks.compactMap(\.album)) }
    var albumArtist: String? {
        mostCommon(tracks.compactMap(\.albumArtist)) ?? mostCommon(tracks.compactMap(\.artist))
    }
    var year: String? { mostCommon(tracks.compactMap(\.year)) }
    var genre: String? { mostCommon(tracks.compactMap(\.genre)) }
    var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }
    var formatSummary: String? {
        let f = Set(tracks.compactMap(\.format))
        return f.count == 1 ? f.first : (f.isEmpty ? nil : "Mixed formats")
    }
    var current: Track? { tracks.first { $0.id == currentID } }
    var discCount: Int { Set(tracks.map { $0.disc ?? 1 }).count }

    private func mostCommon(_ v: [String]) -> String? {
        guard !v.isEmpty else { return nil }
        let counts = Dictionary(v.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    // MARK: loading

    func open(_ urls: [URL]) {
        stop()
        let token = UUID()
        loadToken = token
        loading = true
        Task.detached(priority: .userInitiated) {
            let files = Library.audioFiles(in: urls)
            // Header reads in parallel: track numbers and album come straight from the tags.
            var read = [Track?](repeating: nil, count: files.count)
            read.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: files.count) { i in base[i] = Library.read(files[i]) }
            }
            var tracks = Library.sort(read.compactMap { $0 })
            let sorted = tracks
            // The cover comes with the tracks, so the new disc arrives already printed.
            let cover = Library.cover(for: sorted)
            await MainActor.run {
                guard self.loadToken == token else { return }
                guard !sorted.isEmpty else { self.loading = false; NSSound.beep(); return }   // no music there: keep the disc
                self.cover = cover
                self.setTracks(sorted)
                self.userReordered = false
                self.failed = []
                self.loading = false
                let t0 = CACurrentMediaTime()
                self.albumToken = token
                Snapshots.log(String(format: "album published (%.1f ms)", (CACurrentMediaTime() - t0) * 1000))
                DispatchQueue.main.async { Snapshots.log(String(format: "next runloop +%.1f ms", (CACurrentMediaTime() - t0) * 1000)) }
            }
            // Disc numbers and album artist come from a slower reader, in the background; re-sort if needed.
            var changed = false
            for i in tracks.indices {
                let x = await Library.extras(tracks[i].url)
                if x.disc != nil || x.albumArtist != nil { changed = true }
                tracks[i].disc = x.disc
                tracks[i].albumArtist = x.albumArtist
            }
            guard changed else { return }
            let final = tracks
            await MainActor.run {
                guard self.loadToken == token else { return }
                // Keep any order the user made meanwhile; only the album order of an untouched queue changes.
                let byID = Dictionary(uniqueKeysWithValues: final.map { ($0.id, $0) })
                Snapshots.log("extras applied")
                let updated = self.tracks.map { byID[$0.id] ?? $0 }
                self.setTracks(self.userReordered ? updated : Library.sort(updated))
            }
        }
    }

    private var userReordered = false

    private func setTracks(_ t: [Track]) {
        tracks = t
        engine?.setQueue(queueItems)
        updateNowPlaying()
    }

    private var queueItems: [QueueItem] { tracks.map { QueueItem(id: $0.id, url: $0.url) } }

    // MARK: transport

    func play() {
        switch state {
        case .playing: return
        case .paused:
            engine?.resume()
            setState(.playing)
        case .stopped:
            guard let first = tracks.first(where: { !failed.contains($0.id) }) else { return }
            start(at: first.id)
        }
    }

    func pause() {
        guard state == .playing else { return }
        engine?.pause()
        setState(.paused)
    }

    func togglePlayPause() { state == .playing ? pause() : play() }

    func stop() {
        guard state != .stopped else { return }
        engine?.stop()
        setState(.stopped)
        currentID = nil
        elapsed = 0
        queueVisible = false
        updateNowPlaying()
    }

    func skip() {
        guard state != .stopped, let cur = currentID, let i = tracks.firstIndex(where: { $0.id == cur }) else { return }
        guard let next = tracks[(i + 1)...].first(where: { !failed.contains($0.id) }) else { stop(); return }
        jump(to: next.id)
    }

    func previous() {
        guard state != .stopped, let cur = currentID, let i = tracks.firstIndex(where: { $0.id == cur }) else { return }
        if elapsed > 3 || i == 0 { jump(to: cur) } else { jump(to: tracks[i - 1].id) }
    }

    func jump(to id: UUID) {
        if state == .stopped { start(at: id); return }
        engine?.jump(to: id, playing: state == .playing)
        currentID = id
        elapsed = 0
        updateNowPlaying()
    }

    func seek(to time: Double) {
        guard state != .stopped, let cur = currentID else { return }
        engine?.jump(to: cur, offset: max(0, time), playing: state == .playing)
        elapsed = time
        updateNowPlaying()
    }

    func move(from source: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
        userReordered = true
        engine?.setQueue(queueItems)
    }

    private func start(at id: UUID) {
        guard let t = tracks.first(where: { $0.id == id }) else { return }
        let rate = sampleRate(t.url) ?? 44100
        if engine == nil || engine!.rate != rate {
            engine?.stop()
            engine = try? PlaybackEngine(rate: rate)
            observeConfiguration()
            applyVolume()
        }
        guard let engine else { return }
        engine.setQueue(queueItems)
        engine.play(from: id)
        currentID = id
        elapsed = 0
        setState(.playing)
        queueVisible = true
        updateNowPlaying()
    }

    private func sampleRate(_ url: URL) -> Double? {
        (try? AVAudioFile(forReading: url))?.fileFormat.sampleRate
    }

    private func observeConfiguration() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        guard let e = engine?.engine else { return }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine?.restartAfterConfigurationChange(playing: self.state == .playing)
            }
        }
    }

    private func setState(_ s: PlayState) {
        state = s
        timer?.invalidate()
        timer = nil
        if s != .stopped {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        updateNowPlaying()
    }

    private func tick() {
        guard let engine else { return }
        if engine.finished && state == .playing { stop(); return }
        let f = engine.decoder.failedIDs
        if f != failed { failed = f }
        guard let pos = engine.decoder.position() else { return }
        if pos.id != currentID {
            currentID = pos.id
            elapsed = pos.time
            updateNowPlaying()
        } else {
            elapsed = pos.time
        }
    }

    // MARK: Now Playing & media keys

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ name: String, _ f: @escaping @MainActor () -> Void) {
            cmd.isEnabled = true
            cmd.addTarget { _ in MainActor.assumeIsolated { Snapshots.log("remote \(name)"); f() }; return .success }
        }
        on(c.playCommand, "play") { Player.shared.play() }
        on(c.pauseCommand, "pause") { Player.shared.pause() }
        on(c.togglePlayPauseCommand, "toggle") { Player.shared.togglePlayPause() }
        on(c.stopCommand, "stop") { Player.shared.stop() }
        on(c.nextTrackCommand, "next") { Player.shared.skip() }
        on(c.previousTrackCommand, "previous") { Player.shared.previous() }
        c.changePlaybackPositionCommand.isEnabled = true
        c.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            MainActor.assumeIsolated { Player.shared.seek(to: t) }
            return .success
        }
    }

    private var artwork: MPMediaItemArtwork?
    private var artworkSource: CGImage?

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard state != .stopped, let t = current else {
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyPlaybackDuration: t.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let a = t.artist ?? albumArtist { info[MPMediaItemPropertyArtist] = a }
        if let a = albumTitle { info[MPMediaItemPropertyAlbumTitle] = a }
        if let n = tracks.firstIndex(where: { $0.id == t.id }) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = n
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = tracks.count
        }
        if let c = cover {
            if artworkSource !== c {
                let img = NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
                artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                artworkSource = c
            }
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        center.playbackState = state == .playing ? .playing : .paused
    }

    /// Diagnostics for tests: underruns, resident memory.
    var stats: (underruns: Int, rendered: Int) {
        (engine?.state.underruns.load(ordering: .relaxed) ?? 0, engine?.state.renderedFrames.load(ordering: .relaxed) ?? 0)
    }
}
