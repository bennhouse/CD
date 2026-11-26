# Changelog

## Unreleased

- Click the CD to play it, and again to pause.
- The disc is 10% larger than in the first 30%-smaller layout.
- The accent colour comes from the CD's cover (the slider, the playing track's icon, the corner buttons). It is adjusted separately for light and dark mode to keep at least 4.5:1 contrast and some colour (never near black or near white); covers without colour keep the system accent.
- Corner buttons replace the label on the disc: with no CD, a folder in the top-left corner of the disc's square opens an album; with a CD, that corner changes it and an × in the top-right corner takes it out. They appear while the pointer is anywhere around the disc, rising into focus. No tooltips on the disc.
- The interface is 30% smaller (queue, margins, window); texts and buttons keep their size.
- In the queue, the speaker icon and the track numbers share the same centre.
- Smoother CD change: the discs move in Core Animation (by the render server), not frame by frame from the app, so the change stays fluid while the new album loads.
- The disc no longer darkens or moves aside on hover: a loaded CD lifts off the window instead (its shadow fades in and it grows slightly, with a small "Change CD" label). At rest, while leaving, and with no CD in, there is no shadow.
- The empty frosted disc is the housing: it stays in place, never lifts, and CDs leave and arrive over it.

## 1.0

First release.

- Album player: drop a folder, tracks sorted by disc and track number from their tags, cover on a spinning disc, album details below it.
- Gapless playback: the whole album as one continuous stream, identical sample for sample to the files joined together; streamed from disk, about 20 s of audio in memory.
- Slow external disks: read-ahead of the current and next file, playback starts once 1.5 s is ready.
- Queue beside the disc while playing: double-click to play a track, drag to reorder; the window widens to make room.
- Title bar: volume on the left; previous, play/pause, next and stop on the right. Media keys and Control Center.
- Hover the still disc to change it; the old disc leaves to the left, the new one rises from below.
