import AppKit
import AudioToolbox
import AVFoundation

struct Track: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String?
    var number: Int?
    var disc: Int?
    var year: String?
    var genre: String?
    var duration: Double
    var format: String?

    var fileName: String { url.deletingPathExtension().lastPathComponent }
}

enum Library {
    static let extensions: Set<String> = ["flac", "wav", "wave", "aif", "aiff", "aifc", "m4a", "m4b", "mp4", "aac", "alac",
                                          "mp3", "mp2", "caf", "ac3", "ec3", "opus", "ogg", "oga", "snd", "au", "amr", "3gp"]
    static let imageNames = ["cover", "folder", "front", "album", "albumart", "albumartsmall"]

    /// The audio files of the dropped items: folders are read recursively (multi-disc albums), hidden files skipped.
    static func audioFiles(in urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let f = e?.nextObject() as? URL {
                    if extensions.contains(f.pathExtension.lowercased()) { out.append(f) }
                }
            } else if extensions.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        }
        return out
    }

    /// Tags of one file from Core Audio (fast: reads the header only). FLAC Vorbis comments, ID3, iTunes atoms.
    static func read(_ url: URL) -> Track? {
        var fid: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fid) == noErr, let fid else { return nil }
        defer { AudioFileClose(fid) }
        var info: [String: Any] = [:]
        var dict: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        if AudioFileGetProperty(fid, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr, let d = dict?.takeRetainedValue() as? [String: Any] {
            info = d
        }
        func s(_ k: String) -> String? { (info[k] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }

        var duration: Double = 0
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileGetProperty(fid, kAudioFilePropertyDataFormat, &size, &asbd)
        var ptable = AudioFilePacketTableInfo()
        size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        if AudioFileGetProperty(fid, kAudioFilePropertyPacketTableInfo, &size, &ptable) == noErr, ptable.mNumberValidFrames > 0, asbd.mSampleRate > 0 {
            duration = Double(ptable.mNumberValidFrames) / asbd.mSampleRate
        } else {
            var d: Float64 = 0
            size = UInt32(MemoryLayout<Float64>.size)
            if AudioFileGetProperty(fid, kAudioFilePropertyEstimatedDuration, &size, &d) == noErr { duration = d }
            if duration == 0, let a = s("approximate duration in seconds"), let v = Double(a) { duration = v }
        }

        var bits: UInt32 = 0
        size = 4
        if AudioFileGetProperty(fid, kAudioFilePropertySourceBitDepth, &size, &bits) != noErr || bits == 0 { bits = asbd.mBitsPerChannel }

        func num(_ v: String?) -> Int? { v.flatMap { Int($0.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "") } }
        return Track(url: url,
                     title: s("title") ?? url.deletingPathExtension().lastPathComponent,
                     artist: s("artist"),
                     album: s("album"),
                     albumArtist: nil,
                     number: num(s("track number")) ?? numberFromName(url),
                     disc: nil,
                     year: (s("year") ?? s("recorded date")).map { String($0.prefix(4)) },
                     genre: s("genre"),
                     duration: duration,
                     format: formatName(asbd, bits: Int(bits)))
    }

    /// "01 Name", "1. Name", "1-03 Name".
    static func numberFromName(_ url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        let digits = name.prefix { $0.isNumber || $0 == "-" }
        let last = digits.split(separator: "-").last.map(String.init) ?? ""
        return Int(last)
    }

    /// Disc number and album artist, which Core Audio leaves out (AVFoundation reads them).
    static func extras(_ url: URL) async -> (disc: Int?, albumArtist: String?) {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return (nil, nil) }
        var disc: Int?, aa: String?
        for i in items {
            let id = i.identifier?.rawValue ?? ""
            if id == "vorb/DISCNUMBER" || id == "id3/TPOS" || id == "itsk/disk" || id == "org.id3/TPOS" {
                if let d = try? await i.load(.dataValue), id == "itsk/disk", d.count >= 4 {
                    disc = Int(d[3])
                } else if let v = try? await i.load(.stringValue) {
                    disc = Int(v.split(separator: "/").first ?? "")
                }
            } else if id == "vorb/ALBUMARTIST" || id == "id3/TPE2" || id == "itsk/aART" {
                aa = try? await i.load(.stringValue)
            }
        }
        return (disc, aa)
    }

    static func formatName(_ a: AudioStreamBasicDescription, bits: Int) -> String? {
        let name: String
        switch a.mFormatID {
        case kAudioFormatFLAC: name = "FLAC"
        case kAudioFormatAppleLossless: name = "ALAC"
        case kAudioFormatLinearPCM: name = "PCM"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD: name = "AAC"
        case kAudioFormatMPEGLayer3: name = "MP3"
        case kAudioFormatOpus: name = "Opus"
        case kAudioFormatAC3, kAudioFormatEnhancedAC3: name = "AC-3"
        default: return nil
        }
        let khz = a.mSampleRate / 1000
        let rate = khz == khz.rounded() ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
        let lossless = ["FLAC", "ALAC", "PCM"].contains(name)
        return lossless && bits > 0 ? "\(name) · \(bits)-bit · \(rate)" : "\(name) · \(rate)"
    }

    /// Embedded artwork of the first file that has one, else an image in the folder. Downscaled once.
    static func cover(for tracks: [Track], maxPixels: Int = 900) -> CGImage? {
        for t in tracks.prefix(4) {
            var fid: AudioFileID?
            guard AudioFileOpenURL(t.url as CFURL, .readPermission, 0, &fid) == noErr, let fid else { continue }
            defer { AudioFileClose(fid) }
            var art: Unmanaged<CFData>?
            var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
            if AudioFileGetProperty(fid, kAudioFilePropertyAlbumArtwork, &size, &art) == noErr, let data = art?.takeRetainedValue() as Data?,
               let img = downscale(data, maxPixels) { return img }
        }
        let dirs = Array(Set(tracks.map { $0.url.deletingLastPathComponent() }))
        let fm = FileManager.default
        for dir in dirs + dirs.map({ $0.deletingLastPathComponent() }) {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let images = files.filter { ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff"].contains($0.pathExtension.lowercased()) }
            let preferred = images.first { imageNames.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
            if let u = preferred ?? (dir == dirs.first ? images.first : nil), let d = try? Data(contentsOf: u), let img = downscale(d, maxPixels) { return img }
        }
        return nil
    }

    static func downscale(_ data: Data, _ maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Album order: disc, then track number, then the file name in Finder order.
    static func sort(_ tracks: [Track]) -> [Track] {
        tracks.sorted { a, b in
            let da = a.disc ?? 1, db = b.disc ?? 1
            if da != db { return da < db }
            switch (a.number, b.number) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.url.path.localizedStandardCompare(b.url.path) == .orderedAscending
            }
        }
    }
}
