# overrides/

Parameter tweaks layered on top of ArduPilot's stock `default_params/*` and
`models/*` files when a consuming client builds the `--defaults` file passed
to SITL.

Why a separate dir, not changes to the binary's bundled params: the bundled
ones are frozen at the ArduPilot tag they were built from, so they always
match the binary's source. The overrides here are independent — they can be
edited and pushed without rebuilding any binary or re-cutting any release.

## File format

Each file is a normal ArduPilot `.parm`: comment lines start with `#`, every
other non-blank line is `PARAM_NAME value`. Layered on top of the archive's
params with last-occurrence wins.

## Scope hierarchy

Three scope tiers, applied least- to most-specific. A more specific overlay
wins on conflict — that's the whole point of having tiers. Clients try each
tier independently and skip any that doesn't exist.

| Tier | Path | Applies to |
|---|---|---|
| Global | `parm/<name>` | every version of the named vehicle/frame |
| Major.minor | `parm/<major>.<minor>/<name>` | every patch of that minor (e.g. `parm/4.5/copter.parm` → all 4.5.x) |
| Exact | `parm/<version>/<name>` | only that exact version (e.g. `parm/4.5.7/copter.parm`) |

Use the **most general tier that still expresses the truth**, so the same
file rarely lives in more than one place. Examples:

- `TERRAIN_ENABLE 0.0` for every Copter, every version → one file at
  `parm/copter.parm`.
- A workaround that only matters on the 4.5 series → one file at
  `parm/4.5/copter.parm`.
- A regression worked around on a single release → one file at
  `parm/4.5.7/copter.parm`.

You can also "block" a more general overlay by committing a smaller (or
empty) file at a more specific scope.

## How clients fetch

Files served as plain content from:

```
https://raw.githubusercontent.com/Unmanned-Software-Solutions/ardupilot-sitl-binaries/main/overrides/parm/<path>
```

Each client should cache responses (including 404s) for the process
lifetime. Missing files are normal — they just mean "no overlay at this
scope". Network failure should fall back to "no overlay" so launches still
work offline once the binary cache is warm.

## Filename convention

`<vehicle>.parm` is the vehicle-wide overlay (e.g. `copter.parm`,
`plane.parm`). Per-frame overlays use `<vehicle>-<frame>.parm` (e.g.
`plane-jet.parm`, `motorboat.parm`). The client decides which files to
layer for each (vehicle, frame) combination.
