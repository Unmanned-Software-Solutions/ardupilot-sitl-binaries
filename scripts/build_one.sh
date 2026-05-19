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

./waf configure --board sitl
./waf "$waf_target"

# Locate built binary — path differs slightly by vehicle, but always under build/sitl/bin.
src_bin="build/sitl/bin/${bin_name}"
[[ -f "${src_bin}.exe" ]] && src_bin="${src_bin}.exe"
test -f "$src_bin" || { echo "missing built binary at $src_bin"; ls build/sitl/bin || true; exit 2; }

cd ..

out_dir="build-out/${platform}"
mkdir -p "${out_dir}/bin" "${out_dir}/params"

dest_name=$(canonical_out_name)
[[ "${src_bin}" == *.exe ]] && dest_name="${dest_name}.exe"
cp "ardupilot/${src_bin}" "${out_dir}/bin/${dest_name}"
[[ "${platform}" != windows-* ]] && chmod +x "${out_dir}/bin/${dest_name}"

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
