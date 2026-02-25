# KEFControl

A macOS menu bar app for controlling KEF wireless speakers.

Works with KEF speakers that use the HTTP control API (port 80):
- KEF LS50 Wireless II
- KEF LSX II / LSX II LT
- KEF LS60

**Does not work with** the original LS50W or LSX (gen 1).

## Features

- **Auto-discovery** — finds KEF speakers on your network via mDNS/Bonjour
- **Power on/off** with spinner feedback while the speaker transitions
- **Source switching** — WiFi, Bluetooth, TV, Optical, Coaxial, Analog, USB
- **Volume slider** — per-source volume is synced when switching inputs
- **Now playing** — shows track title, artist, and album when streaming
- **Playback controls** — play/pause, next, previous
- **Settings** — option to hardcode a speaker IP if discovery doesn't work

The app runs entirely in the menu bar (no Dock icon).

## Building

Requires Xcode / Swift toolchain (macOS 14+).

```
swift build
swift run KEFControl
```

Or use the Makefile:

```
make run        # debug build + run
make release    # optimized build
```

You can also open `Package.swift` in Xcode for a full IDE experience.

## How it works

KEF wireless speakers (gen 2) expose a local HTTP API on port 80 with no authentication. The app communicates via simple GET requests:

- `GET /api/getData?path=...&roles=value` — read speaker state
- `GET /api/setData?path=...&roles=value&value=...` — change settings

Discovery uses Apple's Network framework (`NWBrowser`) to scan for `_http._tcp` Bonjour services and filter by name for KEF models.

Based on the API discovered by the [pykefcontrol](https://github.com/N0ciple/pykefcontrol) Python library.

## License

MIT
