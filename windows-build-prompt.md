# Task: build and publish 4 missing Windows ArduPilot SITL binaries

You are on a Windows x64 machine. Build ArduPilot SITL for Windows with Cygwin, package it, and upload it to existing GitHub Releases in `Unmanned-Software-Solutions/ardupilot-sitl-binaries` (call it "the binaries repo"). Every other platform for these releases is already published. Only the Windows zip is missing.

## Targets (exactly these four)

| Upstream ArduPilot tag | vehicle key | asset to produce |
|---|---|---|
| `Sub-4.7.2`     | `sub`     | `ardupilot-sitl-Sub-4.7.2-windows-x64.zip` (+ `.sha256`) |
| `Tracker-4.7.0` | `tracker` | `ardupilot-sitl-Tracker-4.7.0-windows-x64.zip` (+ `.sha256`) |
| `Tracker-4.7.1` | `tracker` | `ardupilot-sitl-Tracker-4.7.1-windows-x64.zip` (+ `.sha256`) |
| `Tracker-4.7.2` | `tracker` | `ardupilot-sitl-Tracker-4.7.2-windows-x64.zip` (+ `.sha256`) |

The release name is the same as the upstream tag (e.g. release `Sub-4.7.2`).

## Rules

- **Never replace an existing asset.** Do not use `--clobber`. The GroundControl app checks the sha256 of each file, so overwriting a published file breaks app versions already shipped. Before uploading, check that the asset is not already there. If it is, skip that target and report it.
- Only add the two files per target listed above. Do not delete or edit releases, tags or other assets. Do not touch the `AntennaTracker-4.7.1` release (it is a known duplicate and the owner will handle it).
- Do not push commits to the binaries repo. Do not trigger GitHub Actions workflows (no `gh workflow run`).
- Build in this order: `Sub-4.7.2`, `Tracker-4.7.0`, `Tracker-4.7.1`, `Tracker-4.7.2`. Build, test and upload one target before starting the next. If one fails, stop and report. Do not improvise workarounds that change the build (different compiler, different flags, patching ArduPilot sources).

## How the CI builds Windows (match it)

The binaries repo's `.github/workflows/build-sitl.yml` builds Windows with Cygwin, the same way ArduPilot's own `cygwin_build.yml` does. Read that workflow, `scripts/build_one.sh` and `scripts/package_one.sh` before you start. The important parts:

- Cygwin packages: `gcc-g++=13.4.0-1 ccache git procps-ng gettext python312 python312-pip python312-future python312-lxml`. Only one Python inside Cygwin, so `python3` is 3.12.
- Python deps inside Cygwin: `python3 -m pip install 'empy==3.3.4' pexpect`, then `python3 -m pip install --upgrade dronecan`. empy must be 3.3.4 (4.x breaks the dronecan generator). Do not use `--break-system-packages`.
- All build commands run in Cygwin bash with
  `export PATH=/usr/local/bin:/usr/bin:$(/usr/bin/cygpath -u "$SYSTEMROOT")/system32`
  so a Windows Python or Git Bash on PATH can't get in the way (a Windows Python on PATH caused an earlier `/dev/null` FileNotFoundError).
- `build_one.sh` (platform `windows-x64`) runs `python3 ./waf --toolchain x86_64-pc-cygwin --board sitl configure` then `python3 ./waf <target> -j8`. It copies the binary to `build-out/windows-x64/bin/<Name>.exe` (`ArduSub.exe` / `AntennaTracker.exe`), copies every `cyg*.dll` it depends on (found via `cygcheck`) from `/usr/bin`, and fails if `cygwin1.dll` is not bundled. It also copies `params/` and writes `README.txt`.
- `package_one.sh <vehicle> <tag> windows-x64 zip` zips `build-out/windows-x64` into `dist/ardupilot-sitl-<tag>-windows-x64.zip` with `7z`, and writes the `.sha256` file (just the hex hash, then a newline).
- Line endings must stay LF. Set `git config --global core.autocrlf false` (and `core.longpaths true`) before cloning anything.

## Steps

1. **Install tools.**
   - Cygwin x64 into `C:\cygwin` with the package list above plus `p7zip` (gives `7z` inside Cygwin) and `wget`. The setup command line accepts `-q -P pkg1,pkg2,...`, and `gcc-g++=13.4.0-1` pins the version. If 13.4.0-1 is no longer on the mirror, stop and report. Do not pick another version.
   - GitHub CLI (`gh`) on Windows. Check `gh auth status` has write access to the binaries repo. If not authenticated, ask the user to run `gh auth login`. Do not ask for a token.
2. **Set up a short work path** (avoids Windows path-length problems), e.g. `C:\sitl`. Inside Cygwin bash (`C:\cygwin\bin\bash.exe --login`), with the PATH export above:
   ```bash
   git config --global core.autocrlf false
   git config --global core.longpaths true
   git config --global --add safe.directory '*'
   cd /cygdrive/c/sitl
   git clone https://github.com/Unmanned-Software-Solutions/ardupilot-sitl-binaries.git
   git clone https://github.com/ArduPilot/ardupilot.git work/ardupilot
   ```
3. **For each target** (`TAG`, `VEH` from the table), inside Cygwin bash:
   ```bash
   export PATH=/usr/local/bin:/usr/bin:$(/usr/bin/cygpath -u "$SYSTEMROOT")/system32
   B=/cygdrive/c/sitl/ardupilot-sitl-binaries
   cd /cygdrive/c/sitl/work/ardupilot
   git fetch origin tag "$TAG" && git checkout -f "$TAG"
   git submodule sync --recursive && git submodule update --init --recursive --jobs 4
   git clean -fdx && git submodule foreach --recursive git clean -fdx   # no stale objects from the previous tag
   cd /cygdrive/c/sitl/work
   rm -rf build-out dist
   bash -o igncr "$B/scripts/build_one.sh" "$VEH" "$TAG" windows-x64 2>&1 | tee "build-$TAG.log"
   bash "$B/scripts/package_one.sh" "$VEH" "$TAG" windows-x64 zip
   ```
   The scripts expect the working directory to contain `ardupilot/`, and they write `build-out/` and `dist/` there. Running them from `/cygdrive/c/sitl/work` does that.
4. **Check the zip** before uploading:
   - The layout matches the published `Plane-4.7.1` Windows zip: `bin/<Name>.exe`, `bin/cygwin1.dll`, `bin/cyggcc_s-seh-1.dll`, `bin/cygstdc++-6.dll`, `bin/cygiconv-2.dll`, `bin/cygintl-8.dll`, `README.txt` and `params/default_params/...`. The archive root is `bin/`, not a wrapper folder.
   - `README.txt` shows the right tag and an `ardupilot HEAD` that matches `git rev-parse "$TAG^{commit}"`.
   - Smoke test from **plain PowerShell or cmd, outside Cygwin** (this proves the bundled DLLs are enough). Unzip to a temp folder, then run
     `bin\ArduSub.exe --model vectored --home 47.397742,8.545594,488,0 -I0 --defaults params\default_params\sub.parm`
     (for Tracker: `bin\AntennaTracker.exe --model tracker --home 47.397742,8.545594,488,0 -I0`).
     Within about 15 s it must be listening on TCP 5760 (`netstat -ano | findstr 5760`). Then stop the process. If it exits early or complains about a missing DLL, stop and report.
5. **Upload** (PowerShell or Cygwin, with `R=Unmanned-Software-Solutions/ardupilot-sitl-binaries`):
   ```bash
   gh release view "$TAG" -R "$R" --json assets --jq '.assets[].name'   # windows zip must NOT be listed yet
   gh release upload "$TAG" "dist/ardupilot-sitl-$TAG-windows-x64.zip" "dist/ardupilot-sitl-$TAG-windows-x64.zip.sha256" -R "$R"
   ```
6. **Verify the upload.** Download both files back with `gh release download "$TAG" -R "$R" -p "*windows-x64.zip*" -D <new empty dir>`. Hash the downloaded zip with `sha256sum` and check it matches both the local `.sha256` and the downloaded `.sha256`.

## Report back

For each target, report:
- tag
- uploaded yes/no
- sha256
- zip size
- smoke test result
- gcc version (`gcc --version | head -1`)
- Cygwin version (`uname -r`)

Also include the full error output for anything that failed or was skipped. Do not run the "Update manifest" workflow. The owner will refresh the manifest after reviewing your report.
