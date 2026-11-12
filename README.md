# ardupilot-sitl-binaries

Pre-built ArduPilot SITL binaries for `copter`, `plane`, `rover`,
`antennatracker`, and `sub`, across `linux-x64`, `linux-arm64`, `macos-x64`,
`macos-arm64`, and `windows-x64`.

Built from upstream `ArduPilot/ardupilot` tags (4.5.0 and newer) and published
as standard GitHub Releases. A `manifest.json` at the repo root indexes every
available build for tooling that wants to download them programmatically.

## What this repo does

- Builds SITL from upstream ArduPilot tags whenever a new one is detected.
- Publishes each (vehicle × version) as its own GitHub Release, named identically
  to the upstream tag (e.g. `Copter-4.6.3`). Each release holds one asset per
  platform plus the matching `default_params/*.parm` files frozen at that tag so
  binaries and parameters can never drift.
- Maintains `manifest.json` at the repo root as a machine-readable index of every
  available build.

## Why per-vehicle-per-version releases

ArduPilot tags each vehicle independently. `Copter-4.6.3` and `Rover-4.6.3`
shipped 16 days apart in November 2025; `Plane-4.5.5` shipped 19 days after
`Copter-4.5.5`. Bundling them into a single release tagged by date would mean
either delaying the early vehicle until the laggards catch up, or shipping a
half-empty release. Independent tags avoid both.

## What is NOT in the matrix

- **Heli** — not a separate ArduPilot release stream. Heli SITL runs on the
  ArduCopter binary with `--model heli`. Use ArduCopter releases for heli.
- **Versions older than 4.5.0** — older tags don't reliably build on current
  Ubuntu / macOS runners without toolchain pinning. Backfill is via manual
  `workflow_dispatch`.

## Layout

- `.github/workflows/build-sitl.yml` — per-tag build matrix
  (workflow_dispatch + called from `discover-versions`).
- `.github/workflows/discover-versions.yml` — scheduled poll of ArduPilot tags;
  dispatches `build-sitl` for any (vehicle, version) we haven't published yet.
- `scripts/build_one.sh` — builds one (vehicle, version) on the current runner.
- `scripts/update_manifest.py` — rebuilds `manifest.json` by listing existing
  GitHub Releases.
- `manifest.json` — the live index.

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
  bin/cyg*.dll                   (Windows builds only: Cygwin runtime)
```

## License

Copyright (C) 2026 Unmanned Software Solutions Sp. z o.o.

| Files | License |
|---|---|
| `scripts/`, `.github/workflows/`, the documentation (`*.md`) | GNU General Public License v3.0 or later (`GPL-3.0-or-later`), see [`LICENSE`](LICENSE) |
| `manifest.json`, `overrides/parm/` | CC0 1.0 Universal (`CC0-1.0`), see [`LICENSES/CC0-1.0.txt`](LICENSES/CC0-1.0.txt) |

Every script, workflow and parameter file names its license in an
`SPDX-License-Identifier` line; `manifest.json` cannot hold a comment, so this
table is its license statement. The data files are dedicated to the public
domain so any tool can read, copy and ship them without conditions.

The published binaries are built from ArduPilot and are licensed under
`GPL-3.0-or-later`, like ArduPilot. Windows archives also contain Cygwin
runtime libraries under their own licenses.
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) lists everything inside
the archives, the license texts in [`LICENSES/`](LICENSES), and how to get
the source code.
