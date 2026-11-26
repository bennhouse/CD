import AVFoundation

/// Test entry points, run without the UI.
///   CD --render OUT.wav [--rate HZ] [--reorder-at SEC] FILE|FOLDER...
/// Plays the album through the real engine (same ring, decoder and source node) in offline manual
/// rendering and writes what the output would hear. `--rate` sets the output rate (the engine's mixer
/// then converts, as it does for a device at another rate). `--reorder-at` moves the last track right
/// after the one playing after that many seconds of output (tests dropping the lookahead).
enum CLI {
    static func render(_ args: [String]) -> Int32 {
        var a = args
        func opt(_ name: String) -> String? {
            guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
            let v = a[i + 1]; a.removeSubrange(i...(i + 1)); return v
        }
        let outRate = opt("--rate").flatMap(Double.init)
        let reorderAt = opt("--reorder-at").flatMap(Double.init)
        guard a.count >= 2 else { print("usage: CD --render OUT.wav [--rate HZ] FILES"); return 2 }
        let out = URL(fileURLWithPath: a[0])
        var tracks = Library.sort(Library.audioFiles(in: a.dropFirst().map { URL(fileURLWithPath: $0) }).compactMap(Library.read))
        guard let first = tracks.first, let rate = (try? AVAudioFile(forReading: first.url))?.fileFormat.sampleRate else { return 1 }
        do {
            let pe = try PlaybackEngine(rate: rate, manual: true, outputRate: outRate ?? rate)
            let e = pe.engine
            let fmt = e.manualRenderingFormat
            let file = try AVAudioFile(forWriting: out, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
                                                                    AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                                                                    AVLinearPCMIsFloatKey: true],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try e.start()
            pe.setQueue(tracks.map { QueueItem(id: $0.id, url: $0.url) })
            pe.play(from: first.id)
            pe.sync()
            pe.state.gain = 1   // no fade in, so the first sample can be compared too
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!
            var total = 0, lastID: UUID?, reordered = false
            var log: [String] = []
            let t0 = Date()
            while !pe.finished {
                // Real time is irrelevant here, but the decoder must keep up: wait for it as a device would not.
                if pe.ring.buffered < 4096 && !pe.state.ended.load(ordering: .acquiring) { usleep(200); continue }
                let st = try e.renderOffline(1024, to: buf)
                guard st == .success else { break }
                try file.write(from: buf)
                total += Int(buf.frameLength)
                if let p = pe.decoder.position(), p.id != lastID {
                    lastID = p.id
                    let t = tracks.first { $0.id == p.id }
                    log.append(String(format: "%10.3f s  %@", Double(total) / fmt.sampleRate, t?.url.lastPathComponent ?? "?"))
                }
                if let r = reorderAt, !reordered, Double(total) / fmt.sampleRate >= r {
                    reordered = true
                    let cur = pe.decoder.position().flatMap { p in tracks.firstIndex { $0.id == p.id } } ?? 0
                    tracks.insert(tracks.removeLast(), at: cur + 1)
                    pe.setQueue(tracks.map { QueueItem(id: $0.id, url: $0.url) })
                    pe.decoder.waitForQueue()   // as fast as it is in real time, relative to the audio
                    log.append(String(format: "%10.3f s  (moved last track after the current one)", Double(total) / fmt.sampleRate))
                }
            }
            log.forEach { print($0) }
            print(String(format: "rendered %d frames (%.3f s) at %.0f Hz in %.2f s; underruns %d; failed %d", total, Double(total) / fmt.sampleRate,
                         fmt.sampleRate, Date().timeIntervalSince(t0), pe.state.underruns.load(ordering: .relaxed), pe.decoder.failedIDs.count))
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}
