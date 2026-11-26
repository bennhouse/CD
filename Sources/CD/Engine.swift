import AVFoundation
import Synchronization

// Gapless playback.
//
// The whole queue is played as ONE continuous stream. A decoder thread opens the tracks one after the
// other and writes their samples, back to back, into a ring buffer of a few seconds; the audio render
// callback only copies samples out of that buffer. There is no per-track player and nothing is
// scheduled, so the last sample of a track is followed by the first sample of the next one in the
// very same render cycle: no gap, no pop, no stall.
//
// - Memory: only the ring buffer (4 s of stereo Float32) and one decode chunk are in RAM. Files are
//   streamed from disk by AVAudioFile (which also removes the encoder delay and padding of AAC/MP3, as
//   given by the file's packet table / iTunSMPB / LAME header).
// - Lookahead: ~15 s before a track ends the decoder opens the next file and asks the kernel to read
//   its first megabytes (F_RDADVISE), so the switch never waits on the disk.
// - Sample rate: the stream runs at the rate of the album (the first track played). The engine's mixer
//   converts it to the output device's rate with one converter that never restarts between tracks. A
//   track with a different rate goes through a decoder-side converter that is kept across consecutive
//   tracks of the same rate and flushed (tail included) only when the rate changes.
// - The render callback takes no locks and allocates nothing: positions are atomics, the buffer is
//   preallocated. The track that is "now playing" is found from the frames actually rendered.

let tracing = ProcessInfo.processInfo.environment["CD_TRACE"] == "1"
func trace(_ s: @autoclosure () -> String) { if tracing { FileHandle.standardError.write((s() + "\n").data(using: .utf8)!) } }

/// Single-producer single-consumer ring of interleaved stereo Float32 frames.
/// Positions are monotonic frame counts; `write - read` frames are buffered.
final class Ring: @unchecked Sendable {
    let capacity: Int
    let mask: Int
    let data: UnsafeMutablePointer<Float>
    let read = Atomic<Int>(0)
    let write = Atomic<Int>(0)

    init(seconds: Double, rate: Double) {
        var c = 1
        while Double(c) < seconds * rate { c <<= 1 }
        capacity = c
        mask = c - 1
        data = .allocate(capacity: c * 2)
        data.initialize(repeating: 0, count: c * 2)
    }
    deinit { data.deallocate() }

    var buffered: Int { write.load(ordering: .acquiring) - read.load(ordering: .acquiring) }
    var space: Int { capacity - buffered }

    /// Producer only. `frames` interleaved stereo frames; the caller made sure they fit.
    func push(_ src: UnsafePointer<Float>, _ frames: Int) {
        let w = write.load(ordering: .relaxed)
        var done = 0
        while done < frames {
            let idx = (w + done) & mask
            let n = min(frames - done, capacity - idx)
            (data + idx * 2).update(from: src + done * 2, count: n * 2)
            done += n
        }
        write.store(w + frames, ordering: .releasing)
    }
}

/// Where a track begins in the stream: ring position of its first frame, and the time in the track that frame is at.
struct Segment {
    let id: UUID
    let start: Int
    let offset: Double
}

struct QueueItem: Sendable {
    let id: UUID
    let url: URL
}

/// State shared between the render callback (real-time thread) and the rest. Atomics only.
final class RenderState: @unchecked Sendable {
    /// 1: play, 0: fade to silence and then stop consuming the buffer.
    let target = Atomic<Int>(0)
    /// While set the callback outputs silence and leaves the buffer alone (the decoder may reset it).
    let hold = Atomic<Bool>(true)
    /// The decoder has written the last frame of the queue.
    let ended = Atomic<Bool>(false)
    let underruns = Atomic<Int>(0)
    let renderedFrames = Atomic<Int>(0)
    /// Fade gain, touched by the callback only.
    var gain: Float = 0
    var step: Float = 0.001
    /// Gain as last left by the callback, for the control thread to wait on fades.
    let silent = Atomic<Bool>(true)
}

/// Decodes the queue into the ring, on its own thread.
final class Decoder: @unchecked Sendable {
    let ring: Ring
    let rate: Double
    let state: RenderState
    private let format: AVAudioFormat   // stereo interleaved Float32 at `rate`
    private var thread: Thread?

    // Shared with the main side, under `lock`.
    private struct Shared {
        var queue: [QueueItem] = []
        var queueVersion = 0
        var request: (id: UUID, offset: Double, gen: Int)?
        var segments: [Segment] = []
        var running = true
        var failed: Set<UUID> = []
    }
    private let lock = Mutex(Shared())
    private let wake = DispatchSemaphore(value: 0)
    private let requestDone = DispatchSemaphore(value: 0)

    // Decoder thread only.
    private var queue: [QueueItem] = []
    private var seenVersion = -1
    private var current: QueueItem?
    private var lastBegun: UUID?
    private var file: AVAudioFile?
    private var fileBuffer: AVAudioPCMBuffer?
    private var next: (item: QueueItem, file: AVAudioFile)?
    private var converter: AVAudioConverter?
    private var converterRate: Double = 0
    private var pending: [AVAudioPCMBuffer] = []
    private var stereo = [Float]()
    private let chunk: AVAudioFrameCount = 4096

    init(ring: Ring, rate: Double, state: RenderState) {
        self.ring = ring
        self.rate = rate
        self.state = state
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)!
    }

    func start() {
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInteractive
        t.name = "CD decoder"
        thread = t
        t.start()
    }

    func shutdown() {
        lock.withLock { $0.running = false }
        wake.signal()
    }

    func setQueue(_ items: [QueueItem]) {
        lock.withLock { $0.queue = items; $0.queueVersion += 1 }
        wake.signal()
    }

    /// Tests: waits until the decoder has taken the last queue into account.
    func waitForQueue() {
        let v = lock.withLock { $0.queueVersion }
        while applied.load(ordering: .acquiring) < v { usleep(100) }
    }
    private let applied = Atomic<Int>(-1)

    /// Restarts the stream at `id`, `offset` seconds in. The callback must be on hold. Waits until the
    /// decoder has reset the buffer and written the first frames (or 1 s).
    func restart(at id: UUID, offset: Double) {
        lock.withLock { $0.request = (id, offset, ($0.request?.gen ?? 0) + 1) }
        wake.signal()
        _ = requestDone.wait(timeout: .now() + 1)
    }

    /// The track being heard and the time in it.
    func position() -> (id: UUID, time: Double)? {
        let r = ring.read.load(ordering: .acquiring)
        return lock.withLock { s in
            guard let seg = s.segments.last(where: { $0.start <= r }) ?? s.segments.first else { return nil }
            return (seg.id, seg.offset + Double(max(0, r - seg.start)) / rate)
        }
    }

    var failedIDs: Set<UUID> { lock.withLock { $0.failed } }

    // MARK: decoder thread

    private func loop() {
        while true {
            let (running, req, q, version) = lock.withLock { s -> (Bool, (id: UUID, offset: Double, gen: Int)?, [QueueItem], Int) in
                let r = s.request
                s.request = nil
                return (s.running, r, s.queue, s.queueVersion)
            }
            if !running { break }
            if version != seenVersion {
                queue = q
                seenVersion = version
                if req == nil { queueChanged() }
                applied.store(version, ordering: .releasing)
            }
            if let req {
                reset(at: req.id, offset: req.offset)
                fill(minimum: Int(rate * 0.25))
                requestDone.signal()
                continue
            }
            if !fill(minimum: 0) {
                // Buffer full, or nothing left to decode: sleep until the callback has used ~1/4 of it.
                _ = wake.wait(timeout: .now() + .milliseconds(Int(Double(ring.capacity) / rate * 250)))
            }
        }
        file = nil
        next = nil
    }

    private func reset(at id: UUID, offset: Double) {
        // The callback is on hold: the read position doesn't move, the buffer can be dropped.
        ring.write.store(ring.read.load(ordering: .acquiring), ordering: .releasing)
        lock.withLock { $0.segments.removeAll() }
        state.ended.store(false, ordering: .releasing)
        file = nil
        next = nil
        converter = nil
        converterRate = 0
        pending.removeAll()
        guard let item = queue.first(where: { $0.id == id }) else { current = nil; state.ended.store(true, ordering: .releasing); return }
        begin(item, offset: offset)
    }

    /// Opens `item` (or the first readable track after it) and marks where it starts in the stream.
    private func begin(_ item: QueueItem, offset: Double = 0, opened: AVAudioFile? = nil) {
        var item = item
        var f = opened
        while true {
            if f == nil { f = open(item) }
            if f != nil { break }
            lock.withLock { _ = $0.failed.insert(item.id) }
            guard let n = after(item.id) else { current = nil; finish(); return }
            item = n
        }
        guard let f else { return }
        if offset > 0 { f.framePosition = min(f.length, AVAudioFramePosition(offset * f.processingFormat.sampleRate)) }
        current = item
        lastBegun = item.id
        file = f
        if f.processingFormat.sampleRate != converterRate || converter == nil && f.processingFormat.sampleRate != rate {
            flushConverter()
            converterRate = f.processingFormat.sampleRate
            converter = converterRate == rate ? nil : AVAudioConverter(
                from: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: converterRate, channels: 2, interleaved: true)!,
                to: format)
            converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        }
        let start = ring.write.load(ordering: .relaxed)
        lock.withLock { $0.segments.append(Segment(id: item.id, start: start, offset: offset)) }
    }

    private func open(_ item: QueueItem) -> AVAudioFile? {
        guard let f = try? AVAudioFile(forReading: item.url, commonFormat: .pcmFormatFloat32, interleaved: true),
              f.processingFormat.channelCount > 0 else { return nil }
        return f
    }

    private func after(_ id: UUID) -> QueueItem? {
        guard let i = queue.firstIndex(where: { $0.id == id }), i + 1 < queue.count else { return nil }
        return queue[i + 1]
    }

    /// Decodes while there is room. Returns false when it did nothing (buffer full or end of queue).
    @discardableResult
    private func fill(minimum: Int) -> Bool {
        var did = false
        let startBuffered = ring.buffered
        while true {
            guard let f = file, let item = current else { return did }
            // Room for one chunk after conversion (up to 192 kHz from 8 kHz: ×24 at most, keep a margin).
            let worst = Int(Double(chunk) * max(1, rate / f.processingFormat.sampleRate)) + 4096
            if ring.space < worst { return did }
            if minimum > 0, ring.buffered - startBuffered >= minimum, did { return did }

            let ch = Int(f.processingFormat.channelCount)
            if fileBuffer == nil || fileBuffer!.format != f.processingFormat {
                fileBuffer = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: chunk)
            }
            let buf = fileBuffer!
            do { try f.read(into: buf, frameCount: chunk) } catch { buf.frameLength = 0 }
            let n = Int(buf.frameLength)
            if n > 0 {
                // To stereo: mono is doubled, more channels keep front left/right.
                if stereo.count < n * 2 { stereo = [Float](repeating: 0, count: n * 2) }
                let src = buf.floatChannelData![0]
                stereo.withUnsafeMutableBufferPointer { dst in
                    if ch == 1 {
                        for i in 0..<n { dst[2 * i] = src[i]; dst[2 * i + 1] = src[i] }
                    } else {
                        for i in 0..<n { dst[2 * i] = src[ch * i]; dst[2 * i + 1] = src[ch * i + 1] }
                    }
                }
                output(stereo, frames: n, rate: f.processingFormat.sampleRate)
                did = true
            }
            if n == 0 || f.framePosition >= f.length {
                // End of this track: the next one starts at the very next frame of the stream.
                if let n = after(item.id) {
                    let opened = next?.item.id == n.id ? next?.file : nil
                    next = nil
                    begin(n, opened: opened)
                } else {
                    finish()
                    return true
                }
                continue
            }
            prefetchNext(remaining: Double(f.length - f.framePosition) / f.processingFormat.sampleRate)
        }
    }

    private func finish() {
        flushConverter()
        file = nil
        current = nil
        state.ended.store(true, ordering: .releasing)
    }

    /// ~15 s before the end, open the next file and warm the page cache with its beginning.
    private func prefetchNext(remaining: Double) {
        guard remaining < 15, let item = current, let n = after(item.id), next?.item.id != n.id else { return }
        if let f = open(n) {
            next = (n, f)
            let fd = Darwin.open(n.url.path, O_RDONLY)
            if fd >= 0 {
                var ra = radvisory(ra_offset: 0, ra_count: 4 << 20)
                _ = fcntl(fd, F_RDADVISE, &ra)
                close(fd)
            }
        }
    }

    /// The queue was reordered. Every track buffered after the one being heard must still follow it in
    /// the new order; from the first that doesn't, the buffer is dropped and decoding resumes there.
    private func queueChanged() {
        guard let pos = position() else { return }
        let segs = lock.withLock { $0.segments }
        trace("queueChanged heard=\(pos.id) read=\(ring.read.load(ordering: .relaxed)) write=\(ring.write.load(ordering: .relaxed)) segs=\(segs.map { "\($0.id.uuidString.prefix(4))@\($0.start)" }) queue=\(queue.map { $0.id.uuidString.prefix(4) })")
        guard let h = segs.lastIndex(where: { $0.id == pos.id }) else { return }
        var expect = pos.id
        for k in (h + 1)..<segs.count {
            if segs[k].id != after(expect)?.id { cut(at: segs[k].start, index: k, after: expect); return }
            expect = segs[k].id
        }
        // What is buffered is still right; the file prepared for later may not be.
        if let n = next, let cur = current, after(cur.id)?.id != n.item.id { next = nil }
        // The end of the queue had been reached, and tracks now follow the last one: carry on, seamlessly.
        if current == nil, state.ended.load(ordering: .acquiring), let last = lastBegun, let n = after(last) {
            state.ended.store(false, ordering: .releasing)
            begin(n)
        }
    }

    private func cut(at start: Int, index: Int, after id: UUID) {
        // Never cut under the callback: keep at least what it may be reading right now. When the cut is
        // that close, the track already buffered plays and the new order applies after it.
        let safety = 16384
        guard start - ring.read.load(ordering: .acquiring) > safety else { return }
        ring.write.store(start, ordering: .releasing)
        lock.withLock { s in s.segments.removeSubrange(index...) }
        file = nil
        next = nil
        pending.removeAll()
        converter?.reset()
        state.ended.store(false, ordering: .releasing)
        if let n = after(id) { begin(n) } else { finish() }
    }

    // MARK: output (with sample-rate conversion when needed)

    private func output(_ samples: [Float], frames: Int, rate fileRate: Double) {
        if fileRate == rate || converter == nil {
            samples.withUnsafeBufferPointer { ring.push($0.baseAddress!, frames) }
            return
        }
        let inFmt = converter!.inputFormat
        let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(frames))!
        inBuf.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: frames * 2) }
        pending.append(inBuf)
        convert(endOfStream: false)
    }

    private func convert(endOfStream: Bool) {
        guard let conv = converter else { return }
        let ratio = rate / conv.inputFormat.sampleRate
        while true {
            let cap = AVAudioFrameCount(Double(chunk) * ratio) + 1024
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap)!
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, st in
                if self.pending.isEmpty {
                    st.pointee = endOfStream ? .endOfStream : .noDataNow
                    return nil
                }
                st.pointee = .haveData
                return self.pending.removeFirst()
            }
            if out.frameLength > 0 { ring.push(out.floatChannelData![0], Int(out.frameLength)) }
            if status != .haveData || out.frameLength == 0 { break }
        }
    }

    private func flushConverter() {
        if converter != nil { convert(endOfStream: true) }
        converter = nil
        converterRate = 0
        pending.removeAll()
    }
}

/// The audio graph: one source node reading the ring, into the main mixer.
final class PlaybackEngine: @unchecked Sendable {
    let engine = AVAudioEngine()
    let ring: Ring
    let state = RenderState()
    let decoder: Decoder
    let rate: Double
    private var source: AVAudioSourceNode!
    private let control = DispatchQueue(label: "CD control")

    init(rate: Double, manual: Bool = false, outputRate: Double? = nil) throws {
        self.rate = rate
        ring = Ring(seconds: 4, rate: rate)
        decoder = Decoder(ring: ring, rate: rate, state: state)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let ring = ring, state = state
        state.step = Float(1 / (0.010 * rate))   // 10 ms fades
        source = AVAudioSourceNode(format: fmt) { isSilence, _, frameCount, abl -> OSStatus in
            Self.render(ring: ring, state: state, frames: Int(frameCount), abl: abl, isSilence: isSilence)
        }
        engine.attach(source)
        if manual {
            let outFmt = AVAudioFormat(standardFormatWithSampleRate: outputRate ?? rate, channels: 2)!
            try engine.enableManualRenderingMode(.offline, format: outFmt, maximumFrameCount: 4096)
        }
        engine.connect(source, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        decoder.start()
    }

    deinit { decoder.shutdown() }

    /// Real-time thread. No locks, no allocation.
    private static func render(ring: Ring, state: RenderState, frames: Int,
                               abl: UnsafeMutablePointer<AudioBufferList>, isSilence: UnsafeMutablePointer<ObjCBool>) -> OSStatus {
        let list = UnsafeMutableAudioBufferListPointer(abl)
        let L = list[0].mData!.assumingMemoryBound(to: Float.self)
        let R = list.count > 1 ? list[1].mData!.assumingMemoryBound(to: Float.self) : L
        let target: Float = state.target.load(ordering: .relaxed) == 1 ? 1 : 0
        if state.hold.load(ordering: .acquiring) || (target == 0 && state.gain == 0) {
            L.update(repeating: 0, count: frames)
            if R != L { R.update(repeating: 0, count: frames) }
            state.gain = 0
            state.silent.store(true, ordering: .releasing)
            isSilence.pointee = true
            return noErr
        }
        let r = ring.read.load(ordering: .relaxed)
        let w = ring.write.load(ordering: .acquiring)
        let n = min(frames, w - r)
        let data = ring.data, mask = ring.mask
        var g = state.gain
        let step = state.step
        for i in 0..<n {
            if g != target { g = target > g ? min(target, g + step) : max(target, g - step) }
            let idx = ((r + i) & mask) * 2
            L[i] = data[idx] * g
            R[i] = data[idx + 1] * g
        }
        if n < frames {
            (L + n).update(repeating: 0, count: frames - n)
            if R != L { (R + n).update(repeating: 0, count: frames - n) }
            if !state.ended.load(ordering: .relaxed) && target == 1 { state.underruns.add(1, ordering: .relaxed) }
        }
        state.gain = g
        state.silent.store(g == 0, ordering: .releasing)
        ring.read.store(r + n, ordering: .releasing)
        state.renderedFrames.add(frames, ordering: .relaxed)
        return noErr
    }

    // MARK: control (all blocking work happens off the main thread)

    func setQueue(_ items: [QueueItem]) { decoder.setQueue(items) }

    /// Starts (or restarts) the stream at a track, with a fade in.
    func play(from id: UUID, offset: Double = 0, completion: @escaping @Sendable () -> Void = {}) {
        control.async { [self] in
            fadeOut()
            state.hold.store(true, ordering: .releasing)
            decoder.restart(at: id, offset: offset)
            state.hold.store(false, ordering: .releasing)
            if !engine.isInManualRenderingMode, !engine.isRunning { try? engine.start() }
            state.target.store(1, ordering: .releasing)
            completion()
        }
    }

    /// Jumps to a track keeping the current play/pause state.
    func jump(to id: UUID, offset: Double = 0, playing: Bool) {
        control.async { [self] in
            fadeOut()
            state.hold.store(true, ordering: .releasing)
            decoder.restart(at: id, offset: offset)
            state.hold.store(false, ordering: .releasing)
            if playing { state.target.store(1, ordering: .releasing) }
        }
    }

    func pause() {
        control.async { [self] in
            fadeOut()
            if !engine.isInManualRenderingMode { engine.pause() }
        }
    }

    func resume() {
        control.async { [self] in
            if !engine.isInManualRenderingMode, !engine.isRunning { try? engine.start() }
            state.target.store(1, ordering: .releasing)
        }
    }

    func stop() {
        control.async { [self] in
            fadeOut()
            state.hold.store(true, ordering: .releasing)
            if !engine.isInManualRenderingMode { engine.stop() }
        }
    }

    /// Waits (≤ 50 ms) for the callback to finish the fade to silence.
    private func fadeOut() {
        state.target.store(0, ordering: .releasing)
        guard engine.isRunning || engine.isInManualRenderingMode else { return }
        let deadline = Date().addingTimeInterval(0.05)
        while !state.silent.load(ordering: .acquiring) && Date() < deadline { usleep(1000) }
    }

    func sync() { control.sync {} }

    /// The output device changed (or its sample rate): AVAudioEngine stopped itself. The stream and its
    /// position are untouched, so starting again resumes at the same frame.
    func restartAfterConfigurationChange(playing: Bool) {
        control.async { [self] in
            engine.prepare()
            if playing { try? engine.start() }
        }
    }

    /// The queue has been played to its last sample.
    var finished: Bool { state.ended.load(ordering: .acquiring) && ring.buffered == 0 }
}
