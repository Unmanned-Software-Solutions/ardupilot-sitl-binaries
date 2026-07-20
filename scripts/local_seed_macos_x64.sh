#!/usr/bin/env bash
# Batch-build macos-x64 SITL binaries for every (vehicle, version) listed in
# manifest.json that doesn't already have a macos-x64 asset, then upload them
# to the matching GitHub Release.
#
# This is the Intel counterpart to local_seed_macos_arm64.sh, and it is the
# PRIMARY path for macos-x64 rather than an accelerator. CI keeps macos-13 in
# the build matrix with continue-on-error, because Intel runners queue long
# enough to gate manifest publication for every other platform — so in practice
# the macos-x64 column never fills from CI. Seeding it from a real Intel Mac is
# what makes SITL work for Intel-Mac GroundControl users at all.
#
# CI's build-sitl workflow has a skip-if-exists step, so anything seeded here
# short-circuits CI's attempt automatically — no conflict, no wasted minutes.
#
# Requirements (one-time):
#   - macOS on Intel (this script will hard-stop on Apple Silicon)
#   - Xcode Command Line Tools (clang + a macOS SDK)
#   - python3 with the ArduPilot build deps. Homebrew is NOT required; a venv is
#     enough and keeps these out of system site-packages:
#       python3 -m venv ~/.sitl-venv
#       ~/.sitl-venv/bin/pip install pyserial pymavlink future lxml \
#           'empy==3.3.4' pexpect fastcrc dronecan
#     then point this script at it:  export SITL_PYTHON=~/.sitl-venv/bin/python
#   - gh CLI authenticated against the repo
#
# Usage:
#   bash scripts/local_seed_macos_x64.sh                 # build everything missing
#   bash scripts/local_seed_macos_x64.sh copter          # only copter
#   bash scripts/local_seed_macos_x64.sh plane 4.6.0     # only Plane-4.6.0
#
# Env knobs:
#   SITL_PYTHON      python interpreter used for the waf build (default: python3)
#   SITL_WORK_DIR    scratch dir for the ArduPilot clone + outputs
#   SITL_NO_UPLOAD=1 build and package only; skip `gh release upload`
#   SITL_MAX_BUILDS  stop after N successful builds (useful for a pilot run)
#
# The script is idempotent: re-running after a partial pass skips what's already
# uploaded.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS only." >&2; exit 2
fi
if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "This script is for Intel Macs (x86_64). On Apple Silicon use local_seed_macos_arm64.sh." >&2
  echo "(Running it under Rosetta would produce a binary labelled macos-x64 — don't.)" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SITL_WORK_DIR:-/tmp/sitl-batch}"
REPO="${SITL_BINARIES_REPO:-Unmanned-Software-Solutions/ardupilot-sitl-binaries}"
PLATFORM="macos-x64"
PY="${SITL_PYTHON:-python3}"

command -v "$PY" >/dev/null || { echo "python not found: $PY" >&2; exit 2; }

# waf shells out to plain `python`/`python3` internally, so putting the chosen
# interpreter's bin dir first on PATH is what actually makes a venv take effect.
PATH="$(cd "$(dirname "$(command -v "$PY")")" && pwd):$PATH"
export PATH

vehicle_filter="${1:-}"
version_filter="${2:-}"

mkdir -p "$WORK"
cd "$WORK"

# Persistent ArduPilot clone so submodule deltas across tags are cheap.
if [[ ! -d ardupilot/.git ]]; then
  echo "==> first-run: cloning ArduPilot (deep, ~2GB) into $WORK/ardupilot"
  git clone https://github.com/ArduPilot/ardupilot.git
fi

# Build the list of (vehicle, version, tag) to seed. Read straight from the
# repo's manifest.json — single source of truth. macOS ships bash 3.2 which
# lacks `mapfile`, so use a temp file and a portable read loop.
TARGETS_FILE="$WORK/.targets-x64.tsv"
"$PY" - <<PY > "$TARGETS_FILE"
import json
m = json.load(open("$REPO_ROOT/manifest.json"))
vf = "$vehicle_filter" or None
vver = "$version_filter" or None
for b in m["builds"]:
    if "$PLATFORM" in b["platforms"]:
        continue
    if vf and b["vehicle"] != vf:
        continue
    if vver and b["version"] != vver:
        continue
    print(f"{b['vehicle']}\t{b['version']}\t{b['ardupilotTag']}")
PY

n_targets=$(wc -l < "$TARGETS_FILE" | tr -d ' ')
if [[ "$n_targets" -eq 0 ]]; then
  echo "Nothing to do — $PLATFORM column is complete (or filters matched nothing)."
  exit 0
fi

echo "==> will build $n_targets $PLATFORM binaries:"
sed 's/^/    /' "$TARGETS_FILE"
echo

success=0
fail=0
failed_tags=""
while IFS=$'\t' read -r vehicle version tag; do
  [[ -z "$vehicle" ]] && continue

  if [[ -n "${SITL_MAX_BUILDS:-}" && "$success" -ge "$SITL_MAX_BUILDS" ]]; then
    echo "==> SITL_MAX_BUILDS=$SITL_MAX_BUILDS reached — stopping early"
    break
  fi

  asset="ardupilot-sitl-${tag}-${PLATFORM}.tar.gz"

  echo "================================================================"
  echo "Building ${tag} (vehicle=${vehicle}, platform=${PLATFORM})"
  echo "================================================================"

  # Double-check: if someone (CI) uploaded the asset between manifest read and
  # now, skip without rebuilding.
  if gh release view "$tag" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null \
       | grep -Fxq "$asset"; then
    echo "  already published — skipping"
    continue
  fi

  cd "$WORK/ardupilot"
  git fetch --tags --depth=1 origin "$tag" 2>/dev/null || git fetch --tags origin
  git checkout -f "$tag"
  git submodule sync --recursive
  git submodule update --init --recursive --jobs 4
  # Wipe the waf build dir between tags. Keeping it would let stale .o files
  # from a newer tag relink as the older tag's binary in seconds — a 20-second
  # "success" that's actually a Frankenbinary. Pay the ~4-min cost per build
  # to get a genuinely correct artifact.
  git clean -fdx

  cd "$WORK"
  rm -rf build-out dist
  if ! bash "$REPO_ROOT/scripts/build_one.sh" "$vehicle" "$tag" "$PLATFORM"; then
    echo "  BUILD FAILED for $tag — continuing"
    fail=$((fail+1))
    failed_tags="${failed_tags} ${tag}"
    continue
  fi
  bash "$REPO_ROOT/scripts/package_one.sh" "$vehicle" "$tag" "$PLATFORM" "tar.gz"

  # Sanity-check the artifact really is an x86_64 Mach-O before publishing it.
  # A wrong-arch binary would install cleanly and only fail at SITL launch.
  built_bin=$(find "$WORK/build-out/$PLATFORM/bin" -type f -perm -u+x | head -1)
  if ! file -b "$built_bin" | grep -q 'Mach-O.*x86_64'; then
    echo "  WRONG ARCH for $tag: $(file -b "$built_bin") — not uploading"
    fail=$((fail+1))
    failed_tags="${failed_tags} ${tag}(arch)"
    continue
  fi

  if [[ -n "${SITL_NO_UPLOAD:-}" ]]; then
    echo "  SITL_NO_UPLOAD set — built and packaged, not uploading:"
    echo "    $WORK/dist/$asset"
  else
    gh release upload "$tag" \
         "$WORK/dist/$asset" \
         "$WORK/dist/$asset.sha256" \
         --repo "$REPO" --clobber
    echo "  uploaded $asset"
  fi

  success=$((success+1))
done < "$TARGETS_FILE"

echo
echo "================================================================"
echo "seeded $success binaries, $fail failures"
[[ -n "$failed_tags" ]] && echo "failed:${failed_tags}"
echo "================================================================"
# Note: uploading an asset to an ALREADY-published release does not re-fire
# `release: published`, so update-manifest.yml won't necessarily wake up on its
# own here. It also runs on a 4-hourly cron, so the manifest catches up within
# a few hours — or kick it immediately with:
#   gh workflow run update-manifest.yml --repo $REPO
