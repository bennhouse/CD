import Foundation

/// Cover art stored in an ID3 tag inside a WAV or AIFF file (an "id3 " / "ID3 " chunk), which is how
/// ffmpeg, Mp3tag, foobar2000 and others tag WAV files. Core Audio reads the text of that tag but not its
/// picture, so the picture is read here: only the chunk headers and the tag itself are read, never the
/// audio.
enum ChunkArtwork {
    static func read(_ url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 12), head.count == 12 else { return nil }
        let form = String(decoding: head[0..<4], as: UTF8.self)
        let kind = String(decoding: head[8..<12], as: UTF8.self)
        let little: Bool
        switch (form, kind) {
        case ("RIFF", "WAVE"), ("RF64", "WAVE"): little = true
        case ("FORM", "AIFF"), ("FORM", "AIFC"): little = false
        default: return nil
        }
        let end = (try? h.seekToEnd()) ?? 0
        var offset: UInt64 = 12
        // Walk the chunks; the tag is usually after the audio, so skip over the audio without reading it.
        for _ in 0..<64 {
            guard offset + 8 <= end else { break }
            try? h.seek(toOffset: offset)
            guard let ch = try? h.read(upToCount: 8), ch.count == 8 else { break }
            let id = String(decoding: ch[0..<4], as: UTF8.self)
            let b = [UInt8](ch[4..<8])
            let size = little
                ? UInt64(b[0]) | UInt64(b[1]) << 8 | UInt64(b[2]) << 16 | UInt64(b[3]) << 24
                : UInt64(b[3]) | UInt64(b[2]) << 8 | UInt64(b[1]) << 16 | UInt64(b[0]) << 24
            if id.lowercased() == "id3 ", size > 10, size < 64 << 20 {
                guard let tag = try? h.read(upToCount: Int(size)) else { return nil }
                return ID3.picture(in: tag)
            }
            // RF64 stores the real data size elsewhere (0xFFFFFFFF here): no tag can be found past it.
            if size == 0xFFFF_FFFF { break }
            offset += 8 + size + (size & 1)
        }
        return nil
    }
}

/// The front cover (or the first picture) of an ID3v2.2/2.3/2.4 tag.
enum ID3 {
    static func picture(in tag: Data) -> Data? {
        let d = [UInt8](tag)
        guard d.count > 10, d[0] == 0x49, d[1] == 0x44, d[2] == 0x33 else { return nil }   // "ID3"
        let version = d[3]
        let flags = d[5]
        let tagSize = syncsafe(d, 6)
        var p = 10
        if flags & 0x40 != 0, version >= 3, d.count > 14 {
            // Extended header.
            p += version == 4 ? syncsafe(d, 10) : (be32(d, 10) + 4)
        }
        let end = min(d.count, 10 + tagSize)
        var first: Data?
        while p + (version == 2 ? 6 : 10) <= end {
            let idLen = version == 2 ? 3 : 4
            let id = String(decoding: d[p..<(p + idLen)], as: UTF8.self)
            if d[p] == 0 { break }   // padding
            let size: Int
            if version == 2 {
                size = Int(d[p + 3]) << 16 | Int(d[p + 4]) << 8 | Int(d[p + 5])
                p += 6
            } else {
                size = version == 4 ? syncsafe(d, p + 4) : be32(d, p + 4)
                p += 10
            }
            guard size > 0, p + size <= end else { break }
            if id == "APIC" || id == "PIC" {
                if let (type, data) = parsePicture(Array(d[p..<(p + size)]), v2: version == 2) {
                    if type == 3 { return data }
                    if first == nil { first = data }
                }
            }
            p += size
        }
        return first
    }

    /// APIC: encoding, MIME (or 3-letter format in v2.2), picture type, description, image bytes.
    private static func parsePicture(_ b: [UInt8], v2: Bool) -> (UInt8, Data)? {
        guard b.count > 4 else { return nil }
        let enc = b[0]
        var i = 1
        if v2 { i += 3 } else {
            while i < b.count && b[i] != 0 { i += 1 }
            i += 1
        }
        guard i < b.count else { return nil }
        let type = b[i]
        i += 1
        // Description: terminated by 0 (Latin-1, UTF-8) or 00 00 on an even boundary (UTF-16).
        if enc == 1 || enc == 2 {
            while i + 1 < b.count && !(b[i] == 0 && b[i + 1] == 0) { i += 2 }
            i += 2
        } else {
            while i < b.count && b[i] != 0 { i += 1 }
            i += 1
        }
        guard i < b.count else { return nil }
        return (type, Data(b[i...]))
    }

    private static func syncsafe(_ d: [UInt8], _ i: Int) -> Int {
        guard i + 3 < d.count else { return 0 }
        return Int(d[i] & 0x7F) << 21 | Int(d[i + 1] & 0x7F) << 14 | Int(d[i + 2] & 0x7F) << 7 | Int(d[i + 3] & 0x7F)
    }

    private static func be32(_ d: [UInt8], _ i: Int) -> Int {
        guard i + 3 < d.count else { return 0 }
        return Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
    }
}
