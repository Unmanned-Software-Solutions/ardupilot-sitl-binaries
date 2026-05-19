# ardupilot-sitl-binaries (scaffold)

Scaffold for the public GitHub repository that hosts pre-built ArduPilot SITL
binaries for use by Ground Control. The live repo is
[`Unmanned-Software-Solutions/ardupilot-sitl-binaries`](https://github.com/Unmanned-Software-Solutions/ardupilot-sitl-binaries).
This folder lives inside the Ground Control tree as the canonical reference copy
of the workflow / scripts / manifest schema — keep it in sync when you change the
live repo.

## What this repo does

- Builds ArduPilot SITL binaries from upstream `ArduPilot/ardupilot` tags for
  five vehicles (`copter`, `plane`, `rover`, `tracker`, `sub`) across five
  platforms (`linux-x64`, `linux-arm64`, `macos-x64`, `macos-arm64`,
  `windows-x64`).
- Publishes each (vehicle × version) as its own GitHub Release, named identically
  to the upstream tag (e.g. `Copter-4.6.3`). Each release holds one asset per
  platform, plus the matching `default_params/*.parm` files frozen at that tag
  so the binary and its params can never drift.
- Maintains `manifest.json` at the repo root listing every available build —
  this is what Ground Control reads to populate its firmware-version dropdown.

## Why per-vehicle-per-version releases

ArduPilot tags each vehicle independently. `Copter-4.6.3` and `Rover-4.6.3`
shipped 16 days apart in November 2025; `Plane-4.5.5` shipped 19 days after
`Copter-4.5.5`. Bundling them into a single release tagged by date would mean
either delaying the early vehicle until the laggards catch up, or shipping a
half-empty release. Independent tags avoid both.

## What is NOT in the matrix

- **Heli** — not a separate ArduPilot release stream. Heli SITL runs on the
  ArduCopter binary with `--model heli`. Ground Control transparently uses
  Copter builds when the user picks a Heli frame.
- **Versions older than 4.5.0** — older tags don't reliably build on current
  Ubuntu/macOS runners without toolchain pinning. Backfill is via manual
  `workflow_dispatch`.

## Layout

- `.github/workflows/build-sitl.yml` — per-tag build matrix
  (workflow_dispatch + called from `discover-versions`).
- `.github/workflows/discover-versions.yml` — scheduled poll of ArduPilot tags;
  dispatches `build-sitl` for any (vehicle, version) we haven't published yet.
- `scripts/build_one.sh` — builds one (vehicle, version) on the current runner.
- `scripts/update_manifest.py` — rebuilds `manifest.json` by listing existing
  GitHub Releases.
- `manifest.json` — the live index Ground Control fetches.

## Asset naming

```
ardupilot-sitl-<Tag>-<platform>.<ext>

# examples
ardupilot-sitl-Copter-4.6.3-linux-x64.tar.gz
ardupilot-sitl-Copter-4.6.3-windows-x64.zip
ardupilot-sitl-ArduSub-4.5.7-macos-arm64.tar.gz
```

Each archive contains:

```
<archive root>/
  bin/ArduCopter                 (or ArduCopter.exe on Windows)
  params/                        (snapshot from ArduPilot Tools/autotest at this tag)
  README.txt                     (build provenance: runner, date, commit)
  cygwin/*.dll                   (Windows builds only)
```
