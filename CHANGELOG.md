# Changelog

## Unreleased

- Smoother CD change: the discs move in Core Animation (by the render server), not frame by frame from the app, so the change stays fluid while the new album loads.
- The "Change CD" / "Open Album" label comes in just after the lift, rising a few points and coming into focus; it leaves quicker.
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
