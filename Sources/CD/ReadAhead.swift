import Foundation
import QuartzCore
import Synchronization

/// Keeps the disk ahead of the decoder.
///
/// A slow external disk (or one that has spun down) can take seconds to answer. The decoder must never
/// wait on it, so this thread reads the raw bytes of the current file well ahead of the decoder's
/// position, and the beginning of the next file, into the system's file cache. The decoder then reads
/// from memory. The app itself holds only a 256 KB scratch buffer: the data lives in the file cache, which
/// the system can reclaim under memory pressure (the read-ahead simply refills it).
final class ReadAhead: @unchecked Sendable {
    /// How far ahead of the decoder the current file is read, and how much of the next file.
    static let aheadBytes: Int64 = 96 << 20
    static let nextBytes: Int64 = 64 << 20
    private static let chunk = 256 << 10

    private struct Target { var current: URL?; var fraction: Double = 0; var next: URL? }
    private let target = Mutex(Target())
    /// The byte range of each file already read (one contiguous run; a jump elsewhere starts a new one).
    private let warmed = Mutex([URL: Range<Int64>]())
    private let wake = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(true)
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: ReadAhead.chunk, alignment: 4096)
    let disk = SimulatedDisk.fromEnvironment()

    init() {
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInitiated
        t.name = "CD read-ahead"
        t.start()
    }

    deinit { buffer.deallocate() }

    func shutdown() {
        running.store(false, ordering: .releasing)
        wake.signal()
    }

    /// Called by the decoder as it goes: which file, how far into it, and what follows.
    func follow(current: URL?, fraction: Double, next: URL?) {
        guard enabled else { return }
        let changed = target.withLock { t -> Bool in
            let c = t.current != current || t.next != next || abs(t.fraction - fraction) > 0.002
            t = Target(current: current, fraction: fraction, next: next)
            return c
        }
        if changed { wake.signal() }
    }

    /// Whether these bytes of `url` have been read ahead.
    func isWarm(_ url: URL, _ bytes: Range<Int64>) -> Bool {
        warmed.withLock { w in
            guard let r = w[url] else { return false }
            return r.lowerBound <= bytes.lowerBound && bytes.upperBound <= r.upperBound
        }
    }
    let enabled = ProcessInfo.processInfo.environment["CD_NOREADAHEAD"] != "1"

    private func loop() {
        var fds: [URL: Int32] = [:]
        var sizes: [URL: Int64] = [:]
        while running.load(ordering: .acquiring) {
            let t = target.withLock { $0 }
            var work: (URL, Int64)?
            func consider(_ url: URL?, from start: Int64, span: Int64) {
                guard work == nil, let url else { return }
                if sizes[url] == nil {
                    sizes[url] = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
                }
                let size = sizes[url] ?? 0
                let end = min(size, start + span)
                // Continue the run that covers `start`, or start a new one there.
                let run = warmed.withLock { w -> Range<Int64> in
                    if let r = w[url], r.lowerBound <= start, start <= r.upperBound { return r }
                    let s0 = start & ~4095
                    w[url] = s0..<s0
                    return s0..<s0
                }
                if run.upperBound < end { work = (url, run.upperBound) }
            }
            if let cur = t.current {
                let size = sizes[cur] ?? 0
                consider(cur, from: Int64(Double(size) * t.fraction), span: Self.aheadBytes)
            }
            consider(t.next, from: 0, span: Self.nextBytes)
            guard let (url, offset) = work else {
                // Nothing to read: close files no longer needed and wait for the decoder to move on.
                for (u, fd) in fds where u != t.current && u != t.next { close(fd); fds[u] = nil }
                _ = wake.wait(timeout: .now() + .milliseconds(500))
                continue
            }
            if fds[url] == nil {
                disk?.open(url)
                fds[url] = Darwin.open(url.path, O_RDONLY)
            }
            guard let fd = fds[url], fd >= 0 else { sizes[url] = 0; continue }
            disk?.read(url, offset..<(offset + Int64(Self.chunk)))
            let n = pread(fd, buffer, Self.chunk, off_t(offset))
            if n <= 0 {
                sizes[url] = 0   // unreadable or shorter than reported: stop trying
            } else {
                warmed.withLock { w in
                    if let r = w[url], r.upperBound == offset { w[url] = r.lowerBound..<(offset + Int64(n)) }
                }
            }
        }
        for fd in fds.values { close(fd) }
    }
}

/// Test aid: CD_SLOWDISK="MBps:seconds" makes every read of the app behave like a very slow disk:
/// `MBps` of bandwidth, and `seconds` of latency the first time a file is touched (a disk spinning up
/// or seeking far away). Reads the read-ahead has already made are free, as they come from memory.
final class SimulatedDisk: @unchecked Sendable {
    let bytesPerSecond: Double
    let openLatency: Double
    private let touched = Mutex(Set<URL>())
    private let busyUntil = Mutex(CACurrentMediaTime())

    init(mbps: Double, latency: Double) {
        bytesPerSecond = mbps * 1_048_576
        openLatency = latency
    }

    static func fromEnvironment() -> SimulatedDisk? {
        guard let v = ProcessInfo.processInfo.environment["CD_SLOWDISK"] else { return nil }
        let p = v.split(separator: ":").compactMap { Double($0) }
        guard p.count == 2 else { return nil }
        return SimulatedDisk(mbps: p[0], latency: p[1])
    }

    /// First touch of a file pays the latency.
    func open(_ url: URL) {
        let first = touched.withLock { $0.insert(url).inserted }
        if first { occupy(openLatency) }
    }

    /// Bytes already fetched, by anyone (as the system's file cache would keep them), in 64 KB blocks.
    private let cached = Mutex([URL: IndexSet]())

    /// Reading `range` of `url`: only blocks nobody has fetched yet cost disk time. The disk is shared,
    /// so transfers queue behind each other.
    func read(_ url: URL, _ range: Range<Int64>) {
        guard !range.isEmpty else { return }
        let blocks = Int(range.lowerBound >> 16)..<Int((range.upperBound + 65535) >> 16)
        let missing = cached.withLock { c -> Int in
            var set = c[url] ?? IndexSet()
            let have = set.intersection(IndexSet(integersIn: blocks)).count
            set.insert(integersIn: blocks)
            c[url] = set
            return blocks.count - have
        }
        if missing > 0 { occupy(Double(missing * 65536) / bytesPerSecond) }
    }

    private func occupy(_ seconds: Double) {
        let wait = busyUntil.withLock { until -> Double in
            let now = CACurrentMediaTime()
            let start = max(now, until)
            until = start + seconds
            return until - now
        }
        if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
    }
}
