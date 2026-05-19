# overrides/

Parameter tweaks layered on top of ArduPilot's stock `default_params/*` and
`models/*` files when consuming clients build the `--defaults` file passed to
SITL.

Why a separate dir, not changes to the binary's bundled params: the bundled
ones are frozen at the ArduPilot tag they were built from, so they always
match the binary's source. The overrides here are independent — they can be
edited and pushed without rebuilding any binary or re-cutting any release.

## Files

Each file is a normal ArduPilot `.parm`: comment lines start with `#`, each
non-comment line is `PARAM_NAME value`. Layered on top of the archive's
params with last-occurrence wins.

`parm/<file>.parm` is referenced by name from each consuming client's model
definition. The client decides which files apply per (vehicle, frame).

## How clients fetch

Files served as plain content from:

```
https://raw.githubusercontent.com/Unmanned-Software-Solutions/ardupilot-sitl-binaries/main/overrides/parm/<name>
```

Clients should cache on disk and refresh once per session (or honour
If-Modified-Since on subsequent fetches). If the network is unavailable and
the cache is empty, falling back to "no overrides" is the safe behaviour —
the binary's bundled defaults are valid on their own.
