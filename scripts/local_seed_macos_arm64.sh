#!/usr/bin/env bash
# Batch-build macos-arm64 SITL binaries for every (vehicle, version) listed in
# manifest.json that doesn't already have a macos-arm64 asset, then upload them
# to the matching GitHub Release.
#
# This is an OPTIONAL accelerator for an Apple Silicon Mac to help drain the
# macos-arm64 backlog when the CI runner queue is slow. The normal path is CI:
# this script only fills gaps. CI's build-sitl workflow has a skip-if-exists
# step, so anything seeded here will short-circuit CI's attempt automatically —
# no conflict, no wasted runner minutes.
#
# Requirements (one-time):
#   - macOS on Apple Silicon (this script will hard-stop on Intel)
#   - Homebrew with: ccache wget
#   - python3 (system /usr/bin/python3 is fine) + pip install of:
#       pyserial pymavlink future lxml 'empy==3.3.4' pexpect fastcrc dronecan
#     (use a venv to keep these out of system site-packages)
#   - gh CLI authenticated against the repo
#
# Usage:
#   bash scripts/local_seed_macos_arm64.sh                 # build everything missing
#   bash scripts/local_seed_macos_arm64.sh copter          # only copter
#   bash scripts/local_seed_macos_arm64.sh plane 4.6.0     # only Plane-4.6.0
#
# The script is idempotent: re-running after a partial pass skips what's already
# uploaded.

set -euo pipefail

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This script is for Apple Silicon (arm64). Run on macos-x64 via cross-compile or skip." >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS only." >&2; exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SITL_WORK_DIR:-/tmp/sitl-batch}"
REPO="${SITL_BINARIES_REPO:-Unmanned-Software-Solutions/ardupilot-sitl-binaries}"

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
# repo's manifest.json — single source of truth.
mapfile -t TARGETS < <(/usr/bin/python3 - <<PY
import json
m = json.load(open("$REPO_ROOT/manifest.json"))
vf = "$vehicle_filter" or None
vver = "$version_filter" or None
for b in m["builds"]:
    if "macos-arm64" in b["platforms"]:
        continue
    if vf and b["vehicle"] != vf:
        continue
    if vver and b["version"] != vver:
        continue
    print(f"{b['vehicle']}\t{b['version']}\t{b['ardupilotTag']}")
PY
)

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "Nothing to do — macos-arm64 column is complete (or filters matched nothing)."
  exit 0
fi

echo "==> will build ${#TARGETS[@]} macos-arm64 binaries:"
for line in "${TARGETS[@]}"; do echo "    $line"; done
echo

success=0
fail=0
for line in "${TARGETS[@]}"; do
  IFS=$'\t' read -r vehicle version tag <<<"$line"
  asset="ardupilot-sitl-${tag}-macos-arm64.tar.gz"

  echo "================================================================"
  echo "Building ${tag} (vehicle=${vehicle})"
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
  git clean -fdx --exclude=build

  cd "$WORK"
  rm -rf build-out dist
  if ! bash "$REPO_ROOT/scripts/build_one.sh" "$vehicle" "$tag" "macos-arm64"; then
    echo "  BUILD FAILED for $tag — continuing"
    fail=$((fail+1))
    continue
  fi
  bash "$REPO_ROOT/scripts/package_one.sh" "$vehicle" "$tag" "macos-arm64" "tar.gz"

  gh release upload "$tag" \
       "$WORK/dist/$asset" \
       "$WORK/dist/$asset.sha256" \
       --repo "$REPO" --clobber

  success=$((success+1))
  echo "  uploaded $asset"
done

echo
echo "================================================================"
echo "seeded $success binaries, $fail failures"
echo "================================================================"
echo "The release:published events will trigger update-manifest.yml in CI"
echo "automatically, so the consuming manifest.json will catch up shortly."
