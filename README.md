# EdgeAurora

EdgeAurora lights the edges of your Mac's screen with an aurora that moves to
the music playing in Apple Music or Spotify. It is a fork of
[EdgeBeat](https://github.com/ChaitanyaSai-Meka/EdgeBeat) by Chaitanya Sai Meka,
rebuilt around a GPU renderer and a new look.

It runs from the menu bar, stays visible over full-screen apps, follows the
MacBook notch, and takes its colours from the current album art.

> The app inside is still named **EdgeBeat** (same bundle identifier), so it
> replaces an installed EdgeBeat and keeps its settings and permissions.

## What is different from EdgeBeat

**The look**
- An aurora ribbon along every edge: a soft glowing line at the screen edge, a
  body that fades steeply inward, and a faint inner edge that undulates and drifts.
- The spectrum is laid around the screen: bass along the bottom, mids up the
  sides, treble across the top. How far each ray reaches follows the music under it.
- Living rays: each one is born, shoots out, flickers and fades on its own
  clock; kicks spark rays along the bottom, snares and hi-hats across the top.
- Colours come from the album art, blended in OKLCH so gradients stay vivid
  instead of passing through grey, output in Display P3, and crossfaded between
  tracks. Near-greyscale covers still get colour.
- Frosted glass under the band, an optional album-tinted smoked shade so the glow
  reads over white windows, and slow breathing in quiet passages.

**Controls** — menu › Aurora: Frosted Glass, Halo, Reactivity, Ray Length, Smoke.
Every slider's midpoint is the default look. Glow and Thickness work as before.

**Efficiency** — the SwiftUI canvas was replaced by one Metal shader drawn into
four edge strips, so only the band that can light up is rendered or composited,
and the render loop stops completely when nothing is playing.

| Measured with Apple Music playing | EdgeBeat 1.4.0 | EdgeAurora |
|---|---|---|
| CPU (EdgeBeat process) | ~41% | ~7–12% |
| Memory | ~327 MB | ~150–190 MB |
| Idle (music stopped) | — | ~1% CPU, ~44 MB |

One Apple M3 Pro MacBook Pro on macOS 27, glow at full thickness; your numbers
will differ. `scripts/measure.sh` records the same figures on your machine. The
menu also shows live CPU, watts and frame rate while it is open.

**Fixes offered upstream** ([EdgeBeat#3](https://github.com/ChaitanyaSai-Meka/EdgeBeat/pull/3))
- With Spotify not installed, every poll compiled `tell application "Spotify"`,
  which opens a hidden "Where is Spotify?" chooser and hangs track detection.
- The Now Playing window kept its SwiftUI view ticking while hidden.

## Requirements

- macOS 14.4 or later, Apple silicon recommended
- Apple Music or Spotify
- Xcode Command Line Tools to build

## Build and run

```sh
git clone https://github.com/contactdharsan-blip/edgeaurora.git
cd edgeaurora
bash scripts/build.sh          # release build, assembles and signs EdgeBeat.app
open EdgeBeat.app
```

`build.sh` signs ad hoc by default. macOS then treats every rebuild as a new app
and asks again for system-audio and automation permission. To keep permissions
across rebuilds, sign with your own identity:

```sh
EDGEBEAT_SIGN_ID="Apple Development: you@example.com (TEAMID)" bash scripts/build.sh
```

To install, copy `EdgeBeat.app` to `/Applications`. On first launch allow system
audio recording (Privacy & Security › Screen & System Audio Recording) and, if
asked, control of Music or Spotify.

There are no prebuilt releases yet; build from source.

## Development

```sh
swift test
EDGEBEAT_SNAPSHOT_DIR=/tmp/aurora swift test --filter GlowSnapshotTests   # also writes PNGs
bash scripts/measure.sh 20 "my label"                                     # CPU / memory / power
```

The snapshot tests render the aurora offscreen through the real shader and check
it pixel by pixel; they skip on machines without a Metal device.

## Credits and license

EdgeBeat is © 2026 Chaitanya Sai Meka; EdgeAurora's changes are © 2026
contactdharsan-blip. Both under the MIT License, see [LICENSE](LICENSE). The bundled
MediaRemoteAdapter keeps its own license in `Resources/MediaRemoteAdapter.LICENSE`.
