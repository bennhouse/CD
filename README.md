# CD

Album player of the Selfmade Utilities suite. Drop a folder of music (FLAC, WAV, AIFF, ALAC/AAC M4A,
MP3, CAF…): tracks are ordered by disc and track number from their tags, the cover is printed on a
disc that spins while the music plays, and the queue opens beside it.

## Gapless engine (`Sources/CD/Engine.swift`)
The whole queue plays as one continuous stream: a decoder thread writes the tracks back to back into
a ~20 s lock-free ring buffer (8 MB at 44.1 kHz, 16 MB at most), the render callback only copies out
of it. Files stream from disk (no album in RAM). For slow or sleeping external disks, a read-ahead
thread (`ReadAhead.swift`) fetches the current file ~96 MB ahead of the decoder and the first 64 MB of
the next one into the file cache; the decoder opens the next file only once that is done, and every
(re)start waits for 1.5 s of buffered audio, so a slow disk delays the start instead of stuttering. One mixer converts to
the device rate across all tracks. Reordering the queue drops only the part of the lookahead that no
longer follows the track being heard.

## Build
    scripts/setup-signing.sh      # once: local signing identity in signing/
    scripts/build-app.sh          # build, sign, install in /Applications, launch
    NO_INSTALL=1 scripts/build-app.sh

## Tests
    .build/debug/CD --render OUT.wav [--rate 48000] [--reorder-at SEC] FOLDER
renders the album through the real engine offline (checked bit-identical to each file decoded on its
own and concatenated). App hooks: `CD_OPEN`, `CD_MUTE=1`, `CD_ACTIONS="2:play,5:skip,…"`, `CD_STATS`,
`CD_SNAPSHOT` (+ `CD_BURST=1`), `CD_FRAMELOG=1`, `CD_WATCHDOG=1` — see `Snapshots.swift`.
`CD_SLOWDISK="MBps:seconds"` simulates a slow disk (bandwidth, latency on first touch of each file);
`CD_RING_SECONDS`, `CD_NOREADAHEAD=1` reproduce the old settings for comparison.

## Known limits
- A disk barely faster than the music itself (e.g. 0.65 MB/s for 24-bit/96 kHz WAV, which needs
  0.55 MB/s) with seconds of latency per file can still run dry at a track change: there is no spare
  bandwidth to read ahead. Tested clean at 0.8 MB/s + 5 s and 2 MB/s + 10 s per file.
- An album that mixes sample rates gets a faint (−37 dB) resampler transient at the track where the
  rate changes; no gap. Albums at one rate, at any device rate, are sample-exact.
- AAC/MP3 junctions are exactly what the files contain (encoder delay/padding removed by Core Audio);
  tracks encoded separately can carry their own small edge artefacts.
