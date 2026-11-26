import AppKit
import QuartzCore

extension Notification.Name { static let cdDebugHover = Notification.Name("CDDebugHover") }

/// Development aid: with CD_SNAPSHOT=<folder> in the environment, CD writes a PNG of each of
/// its windows (toolbar included) every second, so the layout can be checked without screen
/// recording permission. Does nothing otherwise.
@MainActor
enum Snapshots {
    private static var timer: Timer?

    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let script = env["CD_ACTIONS"] { runActions(script) }
        if let path = env["CD_STATS"] { startStats(path) }
        if env["CD_WATCHDOG"] == "1" { Watchdog.start() }
        // Tests run with the window behind others; App Nap would then throttle the app like any background one.
        if env["CD_NOAPPNAP"] == "1" { activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "test") }
        guard let dir = env["CD_SNAPSHOT"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                // Which window has the focus (to check that nothing steals it).
                let key = NSApp.keyWindow.map { $0.title.isEmpty ? "main window" : $0.title } ?? "none"
                try? (key + "\n").write(toFile: "\(dir)/key.txt", atomically: true, encoding: .utf8)
                for (i, w) in NSApp.windows.enumerated() where w.isVisible {
                    guard let frameView = w.contentView?.superview else { continue }
                    let b = frameView.bounds
                    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: b) else { continue }
                    frameView.cacheDisplay(in: b, to: rep)
                    let name = w.title.isEmpty ? "window\(i)" : w.title.replacingOccurrences(of: " ", with: "-")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
                    // The window as the window server composites it (materials, vibrancy), which
                    // cacheDisplay doesn't draw. An app may capture its own windows without permission.
                    if let img = WindowCapture.image(w.windowNumber) {
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: "\(dir)/\(name)-screen.png"))
                    }
                }
            }
        }
    }
}

extension Snapshots {
    /// CD_ACTIONS="2:play,6:skip,8:pause,9:play,10:jump3,14:move,20:stop": transport actions at seconds after launch.
    /// `jumpN` plays the Nth track of the queue, `move` puts the last track after the current one.
    static func runActions(_ script: String) {
        for part in script.split(separator: ",") {
            let kv = part.split(separator: ":")
            guard kv.count == 2, let t = Double(kv[0]) else { continue }
            let action = String(kv[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                MainActor.assumeIsolated {
                    let p = Player.shared
                    switch action {
                    case "play": p.play()
                    case "pause": p.pause()
                    case "stop": p.stop()
                    case "skip": p.skip()
                    case "previous": p.previous()
                    case "move":
                        if let cur = p.tracks.firstIndex(where: { $0.id == p.currentID }), p.tracks.count > 2 {
                            p.move(from: IndexSet(integer: p.tracks.count - 1), to: cur + 1)
                        }
                    case "quit": NSApp.terminate(nil)
                    case "open1", "open2": if let o = ProcessInfo.processInfo.environment["CD_" + action.uppercased()] { p.open([URL(fileURLWithPath: o)]) }
                    case "hover": NotificationCenter.default.post(name: .cdDebugHover, object: true)
                    case "unhover": NotificationCenter.default.post(name: .cdDebugHover, object: false)
                    default:
                        if action.hasPrefix("jump"), let n = Int(action.dropFirst(4)), n >= 1, n <= p.tracks.count { p.jump(to: p.tracks[n - 1].id) }
                        if action.hasPrefix("seek"), let s = Double(action.dropFirst(4)) { p.seek(to: s) }
                    }
                    log("action \(action)")
                    if ProcessInfo.processInfo.environment["CD_FRAMELOG"] == "1" { FrameLog.watch(action, seconds: 1.5) }
                    if let dir = ProcessInfo.processInfo.environment["CD_SNAPSHOT"], ProcessInfo.processInfo.environment["CD_BURST"] == "1" {
                        burst(dir: dir, name: action, seconds: 1.4)
                    }
                }
            }
        }
    }

    /// After each action (CD_BURST=1): composited window images every 1/30 s, and the window width.
    static func burst(dir: String, name: String, seconds: Double) {
        var n = 0
        let t0 = CACurrentMediaTime()
        var widths: [String] = []
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 300 }) else { return }
                if let img = WindowCapture.image(w.windowNumber, nominal: true) {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: String(format: "%@/burst-%@-%03d.png", dir, name, n)))
                }
                widths.append(String(format: "%.3f %.1f %.1f", CACurrentMediaTime() - t0, w.frame.width, w.frame.minX))
                n += 1
                if CACurrentMediaTime() - t0 > seconds {
                    timer.invalidate()
                    try? widths.joined(separator: "\n").write(toFile: "\(dir)/burst-\(name).txt", atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private static var activity: NSObjectProtocol?
    private static var statsPath: String?
    private static var lastCPU: Double = 0
    private static var lastTime = Date()

    static func log(_ line: String) {
        guard let p = statsPath else { return }
        let s = String(format: "%8.2f ", ProcessInfo.processInfo.systemUptime) + line + "\n"
        if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); try? h.close() }
    }

    /// CD_STATS=<file>: every second, resident memory, CPU use, underruns and the track playing.
    static func startStats(_ path: String) {
        statsPath = path
        FileManager.default.createFile(atPath: path, contents: nil)
        if ProcessInfo.processInfo.environment["CD_NOMEM"] == "1" { return }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                _ = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
                }
                var ru = rusage()
                getrusage(RUSAGE_SELF, &ru)
                let cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
                let now = Date()
                let pct = (cpu - lastCPU) / now.timeIntervalSince(lastTime) * 100
                lastCPU = cpu; lastTime = now
                let p = Player.shared
                let st = p.stats
                log(String(format: "footprint %.1f MB  cpu %.1f%%  underruns %d  state %@  track %@  %@",
                           Double(info.phys_footprint) / 1048576, pct, st.underruns, "\(p.state)",
                           p.current.map { "\((p.tracks.firstIndex(of: $0) ?? -1) + 1)" } ?? "-", Format.time(p.elapsed)))
            }
        }
    }
}

/// CGWindowListCreateImage, looked up at run time: the macOS 15 SDK marks it unavailable, but it
/// still works for an app's own windows, which is all the snapshots need.
enum WindowCapture {
    private typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let fn: Fn? = {
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(h, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func image(_ windowNumber: Int, nominal: Bool = false) -> CGImage? {
        // includingWindow = 1 << 3; boundsIgnoreFraming = 1, bestResolution = 1 << 3, nominal = 1 << 4
        fn?(.null, 1 << 3, UInt32(windowNumber), 1 | (nominal ? 1 << 4 : 1 << 3))?.takeRetainedValue()
    }
}


/// CD_FRAMELOG=1: after each action, the longest gaps between display frames on the main thread.
@MainActor
final class FrameLog: NSObject {
    private static var current: FrameLog?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []
    private var end: CFTimeInterval = 0
    private var name = ""

    static func watch(_ name: String, seconds: Double) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 })?.contentView else { return }
        let f = FrameLog()
        f.name = name
        f.end = CACurrentMediaTime() + seconds
        f.link = view.displayLink(target: f, selector: #selector(tick(_:)))
        f.link?.add(to: .main, forMode: .common)
        current = f
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        if last > 0 {
            let g = (now - last) * 1000
            // The first interval of a new display link is always long (start-up), not counted.
            if g > 25 && gaps.count > 1 { Snapshots.log(String(format: "gap %.0f ms (frame %d of %@)", g, gaps.count, name)) }
            if gaps.count > 0 || g < 25 { gaps.append(g) } else { gaps.append(0) }
        }
        last = now
        if CACurrentMediaTime() > end {
            l.invalidate()
            let worst = gaps.sorted(by: >).prefix(5).map { String(format: "%.1f", $0) }.joined(separator: " ")
            let over = gaps.filter { $0 > 25 }.count
            Snapshots.log("frames \(name): \(gaps.count) frames, >25 ms: \(over), worst ms: \(worst)")
        }
    }
}


/// CD_WATCHDOG=1: a background thread pings the main thread every 5 ms and logs any reply later than 30 ms
/// (real main-thread stalls, unlike display-link gaps, which also come from the compositor).
enum Watchdog {
    static func start() {
        let t = Thread {
            while true {
                let sent = CACurrentMediaTime()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                sem.wait()
                let lag = (CACurrentMediaTime() - sent) * 1000
                if lag > 30 { DispatchQueue.main.async { MainActor.assumeIsolated { Snapshots.log(String(format: "MAIN THREAD STALL %.0f ms", lag)) } } }
                usleep(5000)
            }
        }
        t.start()
    }
}
