#!/usr/bin/env bash
# Build one (vehicle, ardupilot_tag) on the current runner.
# Outputs land in ./build-out/<platform>/{bin,params,README.txt}
#
# Args: <vehicle> <ardupilot_tag> <platform>
#   vehicle: copter|plane|rover|tracker|sub
#   ardupilot_tag: full upstream tag (Copter-4.6.3, ArduSub-4.5.7, ...)
#   platform: linux-x64|linux-arm64|macos-x64|macos-arm64|windows-x64

set -euo pipefail

vehicle="$1"
ardupilot_tag="$2"
platform="$3"

case "$vehicle" in
  copter)  waf_target=copter;          bin_name=arducopter ;;
  plane)   waf_target=plane;           bin_name=arduplane  ;;
  rover)   waf_target=rover;           bin_name=ardurover  ;;
  tracker) waf_target=antennatracker;  bin_name=antennatracker ;;
  sub)     waf_target=sub;             bin_name=ardusub    ;;
  *) echo "unknown vehicle: $vehicle" >&2; exit 1 ;;
esac

# Canonical binary names produced by ArduPilot's waf (lowercase). The packaging
# step renames them to the conventional MixedCase used in the manifest.
canonical_out_name() {
  case "$vehicle" in
    copter)  echo "ArduCopter" ;;
    plane)   echo "ArduPlane" ;;
    rover)   echo "ArduRover" ;;
    tracker) echo "AntennaTracker" ;;
    sub)     echo "ArduSub" ;;
  esac
}

cd ardupilot

# macOS arm64 link fix for ArduPilot ≤ 4.5.5: the modern Apple linker enforces
# pointer alignment that AP_FWVersion::fwver didn't satisfy until 4.5.6. The
# `ld_classic` flag falls back to the older linker which tolerates the old
# layout. Harmless on newer versions where the issue is already fixed.
if [[ "$platform" == macos-* ]]; then
  export LDFLAGS="${LDFLAGS:-} -Wl,-ld_classic"
fi

if [[ "$platform" == windows-* ]]; then
  # Windows SITL is built under Cygwin with the cygwin g++ toolchain — the same
  # path ArduPilot uses for the Mission Planner SITL exes (Tools/scripts/cygwin_build.sh).
  # waf must be invoked through `python` (the cygwin python alias) and pointed at
  # the cygwin cross-target so the linker emits a PE executable.
  #
  # --no-submodule-update: the submodules were already populated by actions/checkout.
  # Windows git wrote the submodule .git gitdir pointers as Windows paths (D:/a/...),
  # which Cygwin git can't resolve, so waf's `git submodule status` task aborts the
  # build. Disabling waf's submodule management sidesteps that — the sources are
  # already on disk, waf just shouldn't try to git-manage them.
  python ./waf configure --board sitl --toolchain x86_64-pc-cygwin --no-submodule-update
  python ./waf "$waf_target" -j8
else
  ./waf configure --board sitl
  ./waf "$waf_target"
fi

# Locate built binary — path differs slightly by vehicle, but always under build/sitl/bin.
# Cygwin emits the PE executable with no .exe suffix (e.g. build/sitl/bin/arducopter),
# so the no-suffix fallback below covers Windows too.
src_bin="build/sitl/bin/${bin_name}"
[[ -f "${src_bin}.exe" ]] && src_bin="${src_bin}.exe"
test -f "$src_bin" || { echo "missing built binary at $src_bin"; ls build/sitl/bin || true; exit 2; }

cd ..

out_dir="build-out/${platform}"
mkdir -p "${out_dir}/bin" "${out_dir}/params"

dest_name=$(canonical_out_name)
[[ "${platform}" == windows-* ]] && dest_name="${dest_name}.exe"
cp "ardupilot/${src_bin}" "${out_dir}/bin/${dest_name}"
[[ "${platform}" != windows-* ]] && chmod +x "${out_dir}/bin/${dest_name}"

# Bundle the Cygwin runtime DLLs the exe depends on, so it runs on a machine with
# no Cygwin install. cygcheck walks the import table; we keep only the cyg*.dll
# entries (system DLLs like KERNEL32 are already present on every Windows box) and
# copy each out of /usr/bin. Mirrors the DLL-harvest loop in ArduPilot's
# Tools/scripts/cygwin_build.sh. The set produced here matches the list the
# GroundControl SITL launcher expects (cygwin1.dll, cygstdc++-6.dll, …).
if [[ "$platform" == windows-* ]]; then
  mkdir -p "${out_dir}/cygwin"
  cygcheck "${out_dir}/bin/${dest_name}" \
    | grep -oP 'cyg[^\s\\/]+\.dll' \
    | sort -u \
    | while read -r dll; do
        if [[ -f "/usr/bin/${dll}" ]]; then
          cp -v "/usr/bin/${dll}" "${out_dir}/cygwin/${dll}"
        fi
      done
  test -n "$(ls -A "${out_dir}/cygwin" 2>/dev/null)" || {
    echo "no cygwin DLLs harvested for ${dest_name}"; exit 3;
  }
fi

# Freeze param files at this tag so client never has to fetch from raw.githubusercontent.com.
cp -r ardupilot/Tools/autotest/default_params "${out_dir}/params/default_params"
cp -r ardupilot/Tools/autotest/models         "${out_dir}/params/models" 2>/dev/null || true

cat > "${out_dir}/README.txt" <<EOF
ArduPilot SITL build
  vehicle:        ${vehicle}
  upstream tag:   ${ardupilot_tag}
  platform:       ${platform}
  built on:       $(date -u +%Y-%m-%dT%H:%M:%SZ)
  runner:         ${RUNNER_OS:-unknown}/${RUNNER_ARCH:-unknown}
  ardupilot HEAD: $(cd ardupilot && git rev-parse HEAD)
EOF
