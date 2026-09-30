#!/usr/bin/env bash
# Pack the build-out/<platform> tree into a release asset and write its sha256.
# Args: <vehicle> <ardupilot_tag> <platform> <ext>   (ext = tar.gz | zip)

set -euo pipefail

vehicle="$1"
ardupilot_tag="$2"
platform="$3"
ext="$4"

src="build-out/${platform}"
test -d "$src" || { echo "missing $src"; exit 1; }

mkdir -p dist
asset_base="ardupilot-sitl-${ardupilot_tag}-${platform}"
asset="dist/${asset_base}.${ext}"

case "$ext" in
  tar.gz)
    tar -C "${src}" -czf "${asset}" .
    ;;
  zip)
    # 7z is present on the GitHub Windows runner image but not inside the Cygwin
    # environment we build under; Cygwin's `zip` package covers that case. Prefer
    # whichever is on PATH so the script works in both.
    if command -v 7z >/dev/null; then
      (cd "${src}" && 7z a -tzip "../../${asset}" . >/dev/null)
    elif command -v zip >/dev/null; then
      (cd "${src}" && zip -r -q "../../${asset}" .)
    else
      echo "no zip tool found (need 7z or zip)"; exit 3
    fi
    ;;
  *) echo "unknown ext: $ext"; exit 2 ;;
esac

if command -v sha256sum >/dev/null; then
  sha256sum "${asset}" | awk '{print $1}' > "${asset}.sha256"
else
  shasum -a 256 "${asset}" | awk '{print $1}' > "${asset}.sha256"
fi

echo "Packaged: ${asset}"
echo "sha256:   $(cat "${asset}.sha256")"
