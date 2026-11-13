#!/usr/bin/env bash
# Batch-build macos-arm64 SITL binaries for every (vehicle, version)
# that doesn't already have a macos-arm64 asset, then upload them
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

# Build the list of (vehicle, version, tag) to seed: every published release that
# has at least one binary archive but no macos-arm64 one.
# macOS ships bash 3.2 which lacks `mapfile`, so use a temp file and a portable read loop.
RELEASES_FILE="$WORK/.releases.tsv"
TARGETS_FILE="$WORK/.targets.tsv"
gh api --paginate "repos/$REPO/releases?per_page=100" \
  --jq '.[] | select(.draft | not) | [.tag_name, ([.assets[].name] | join(" "))] | @tsv' \
  > "$RELEASES_FILE"
/usr/bin/python3 - "$RELEASES_FILE" "$vehicle_filter" "$version_filter" <<'PY' > "$TARGETS_FILE"
import re
import sys

releases_file, vehicle_filter, version_filter = sys.argv[1:4]
# Release tags are ArduPilot's; older vehicle names are still in use for some tags.
vehicles = {
    "copter":  re.compile(r"^(?:Copter|ArduCopter)-(\d+\.\d+\.\d+)$"),
    "plane":   re.compile(r"^(?:Plane|ArduPlane)-(\d+\.\d+\.\d+)$"),
    "rover":   re.compile(r"^(?:Rover|APMrover2)-(\d+\.\d+\.\d+)$"),
    "tracker": re.compile(r"^(?:Tracker|AntennaTracker)-(\d+\.\d+\.\d+)$"),
    "sub":     re.compile(r"^(?:Sub|ArduSub)-(\d+\.\d+\.\d+)$"),
}
platforms = "linux-x64|linux-arm64|macos-x64|macos-arm64|windows-x64"

for line in open(releases_file):
    tag, _, names = line.rstrip("\n").partition("\t")
    match = next(((v, p.match(tag)) for v, p in vehicles.items() if p.match(tag)), None)
    if match is None:
        continue
    vehicle, version = match[0], match[1].group(1)
    archive = re.compile(rf"^ardupilot-sitl-{re.escape(tag)}-(?:{platforms})\.(?:tar\.gz|zip)$")
    assets = names.split()
    if not any(archive.match(name) for name in assets):
        continue
    if f"ardupilot-sitl-{tag}-macos-arm64.tar.gz" in assets:
        continue
    if vehicle_filter and vehicle != vehicle_filter:
        continue
    if version_filter and version != version_filter:
        continue
    print(f"{vehicle}\t{version}\t{tag}")
PY

n_targets=$(wc -l < "$TARGETS_FILE" | tr -d ' ')
if [[ "$n_targets" -eq 0 ]]; then
  echo "Nothing to do — macos-arm64 column is complete (or filters matched nothing)."
  exit 0
fi

echo "==> will build $n_targets macos-arm64 binaries:"
cat "$TARGETS_FILE" | sed 's/^/    /'
echo

success=0
fail=0
while IFS=$'\t' read -r vehicle version tag; do
  [[ -z "$vehicle" ]] && continue
  asset="ardupilot-sitl-${tag}-macos-arm64.tar.gz"

  echo "================================================================"
  echo "Building ${tag} (vehicle=${vehicle})"
  echo "================================================================"

  # Double-check: if someone (CI) uploaded the asset since the releases were
  # listed, skip without rebuilding.
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
done < "$TARGETS_FILE"

echo
echo "================================================================"
echo "seeded $success binaries, $fail failures"
echo "================================================================"
