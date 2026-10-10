# DKR-R macOS build handoff

The source/build kit contains no ROM or extracted game assets. On an Apple host
with Xcode and Homebrew installed, run:

```bash
./Build-macOS.sh --rom-v77 "/path/to/US 1.0.z64" --rom-v80 "/path/to/US Rev A.z64"
```

The command installs build tools, fetches pinned dependencies and generates
both revision payloads. Both ROMs are needed for building; only one is needed
to play. See `docs/BUILDING.md` at the source root for prerequisites and build
options.

RT64 selects Metal on macOS. The script builds the native `.app`, runs CTest and
runtime self-tests, stages licences and assets, scans for prohibited game data,
applies an ad-hoc local signature and creates the architecture-specific ZIP in
`dist`.

Before publishing, test startup, ROM selection, Accurate and Modern gameplay,
audio, controller navigation, fullscreen, save writes, texture pack switching
and application exit on physical Apple hardware. Distribution signing and
notarization require the publisher's Apple credentials and are not performed by
the repository script.
