#!/usr/bin/env python3
"""
Rebuild manifest.json by walking every Release in this repo and inspecting the
assets attached to each. The manifest is intentionally derived from the Releases
themselves (not from a separate ledger file) so it can't drift from what's
actually downloadable.

Run after each successful build-sitl job — invoked from build-sitl.yml.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

PLATFORM_RE = re.compile(
    r"^ardupilot-sitl-(?P<tag>.+?)-(?P<platform>linux-x64|linux-arm64|macos-x64|macos-arm64|windows-x64)\.(?P<ext>tar\.gz|zip)$"
)
SHA_RE = re.compile(
    r"^ardupilot-sitl-(?P<tag>.+?)-(?P<platform>linux-x64|linux-arm64|macos-x64|macos-arm64|windows-x64)\.(?:tar\.gz|zip)\.sha256$"
)

VEHICLE_PATTERNS = {
    "copter":  re.compile(r"^(?:Copter|ArduCopter)-(\d+\.\d+\.\d+)$"),
    "plane":   re.compile(r"^(?:Plane|ArduPlane)-(\d+\.\d+\.\d+)$"),
    "rover":   re.compile(r"^(?:Rover|APMrover2)-(\d+\.\d+\.\d+)$"),
    "tracker": re.compile(r"^(?:Tracker|AntennaTracker)-(\d+\.\d+\.\d+)$"),
    "sub":     re.compile(r"^ArduSub-(\d+\.\d+\.\d+)$"),
}

WAF_TARGET = {
    "copter": "copter", "plane": "plane", "rover": "rover",
    "tracker": "antennatracker", "sub": "sub",
}

CANONICAL_BIN = {
    "copter": "ArduCopter", "plane": "ArduPlane", "rover": "ArduRover",
    "tracker": "AntennaTracker", "sub": "ArduSub",
}


def classify(tag: str) -> tuple[str, str] | None:
    for vehicle, pat in VEHICLE_PATTERNS.items():
        m = pat.match(tag)
        if m:
            return vehicle, m.group(1)
    return None


def list_releases() -> list[dict]:
    repo = os.environ["GITHUB_REPOSITORY"]
    out = subprocess.check_output(
        ["gh", "release", "list", "--repo", repo, "--limit", "2000",
         "--json", "tagName,name,createdAt,publishedAt"],
        text=True,
    )
    return json.loads(out)


def list_assets(tag: str) -> list[dict]:
    repo = os.environ["GITHUB_REPOSITORY"]
    out = subprocess.check_output(
        ["gh", "release", "view", tag, "--repo", repo,
         "--json", "assets"],
        text=True,
    )
    return json.loads(out)["assets"]


def fetch_sha(repo: str, tag: str, name: str) -> str:
    """Download the .sha256 sidecar and return its content. Cheap — 64 bytes."""
    url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
    out = subprocess.check_output(["curl", "-sL", url], text=True).strip()
    return out.split()[0] if out else ""


def fetch_upstream_release_date(tag: str) -> str:
    """Date the ArduPilot tag itself was created (not when we built it)."""
    out = subprocess.check_output(
        ["gh", "api", f"/repos/ArduPilot/ardupilot/git/refs/tags/{tag}"],
        text=True,
    )
    sha = json.loads(out)["object"]["sha"]
    obj = subprocess.check_output(
        ["gh", "api", f"/repos/ArduPilot/ardupilot/git/tags/{sha}"],
        text=True,
    )
    try:
        return json.loads(obj)["tagger"]["date"][:10]
    except KeyError:
        # Lightweight tag — fall back to the commit date.
        commit = subprocess.check_output(
            ["gh", "api", f"/repos/ArduPilot/ardupilot/commits/{tag}"],
            text=True,
        )
        return json.loads(commit)["commit"]["committer"]["date"][:10]


def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    builds: list[dict] = []
    latest_by_vehicle: dict[str, tuple[tuple[int, int, int], str]] = {}

    for rel in list_releases():
        tag = rel["tagName"]
        c = classify(tag)
        if c is None:
            continue
        vehicle, version = c

        platforms: dict[str, dict] = {}
        for asset in list_assets(tag):
            m = PLATFORM_RE.match(asset["name"])
            if not m:
                continue
            platform = m.group("platform")
            ext = m.group("ext")
            sha_name = asset["name"] + ".sha256"
            sha = fetch_sha(repo, tag, sha_name)
            platforms[platform] = {
                "asset": asset["name"],
                "sha256": sha,
                "executable": f"bin/{CANONICAL_BIN[vehicle]}{'.exe' if platform.startswith('windows') else ''}",
            }

        if not platforms:
            continue

        builds.append({
            "vehicle": vehicle,
            "version": version,
            "ardupilotTag": tag,
            "ardupilotReleasedAt": fetch_upstream_release_date(tag),
            "ourReleaseTag": tag,
            "wafTarget": WAF_TARGET[vehicle],
            "platforms": platforms,
        })

        v_tuple = tuple(int(p) for p in version.split("."))
        if vehicle not in latest_by_vehicle or v_tuple > latest_by_vehicle[vehicle][0]:
            latest_by_vehicle[vehicle] = (v_tuple, version)  # type: ignore[assignment]

    manifest = {
        "schemaVersion": 1,
        "updatedAt": dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stable": {v: ver for v, (_, ver) in latest_by_vehicle.items()},
        "builds": builds,
    }

    with open("manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
