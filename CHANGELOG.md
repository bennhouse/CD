# Changelog

## Unreleased

- Covers embedded in WAV and AIFF files (an ID3 tag in an "id3 " chunk, as ffmpeg and most taggers write them) are shown: Core Audio reads their text but not their picture, so CD reads it itself.
- The volume slider works: dragging it no longer moves the window (it is an AppKit control now). The scroll wheel over it changes the volume too.
- Previous and next track use the double-arrow symbols of Apple Music.
- Below the disc: the album while the CD is still; once it plays, the track's title on the first line and the album before the artist on the second. Texts change in place, fading and blurring out and back into focus, without sliding.
- Queue rows have no gaps: each track's hover area reaches the next track.
- The queue first takes the room the window already has; the window grows only by what is missing to reach about 430 pt of disc column plus the queue, and gives exactly that back when the queue goes. The queue is a little wider (270 pt).
- The ▶ on a hovered track is drawn over the number: the list no longer moves when it appears.
- Muted covers (beige, slate, sepia, dark gradients) get a muted accent of their own colour; only grey, black or white covers keep the system accent.
- Queue: hovering a track turns its number into a small ▶, the way to play another track (no selection, no double-click; rows are still dragged to reorder). The playing track's row is tinted in the accent colour.
- The volume slider is drawn by CD, so its filled part follows the accent colour too.
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
