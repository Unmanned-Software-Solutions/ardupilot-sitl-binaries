#!/usr/bin/env python3
"""
Emit a JSON array of (vehicle, version, ardupilotTag) entries that exist as
ArduPilot upstream tags but do NOT yet have a corresponding GitHub Release in
this repo. Filters to >= 4.5.0 stable tags only.

Stdout shape:
  [{"vehicle":"copter","version":"4.6.4","ardupilotTag":"Copter-4.6.4"}, ...]
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from typing import Iterable

VEHICLE_PATTERNS = {
    "copter":  re.compile(r"^(?:Copter|ArduCopter)-(\d+\.\d+\.\d+)$"),
    "plane":   re.compile(r"^(?:Plane|ArduPlane)-(\d+\.\d+\.\d+)$"),
    "rover":   re.compile(r"^(?:Rover|APMrover2)-(\d+\.\d+\.\d+)$"),
    "tracker": re.compile(r"^(?:Tracker|AntennaTracker)-(\d+\.\d+\.\d+)$"),
    "sub":     re.compile(r"^ArduSub-(\d+\.\d+\.\d+)$"),
}

MIN_VERSION = (4, 5, 0)


def gh_json(args: list[str]) -> object:
    out = subprocess.check_output(["gh", *args, "--json", "name,tag_name,published_at,createdAt"], text=True)
    return json.loads(out)


def parse_version(v: str) -> tuple[int, int, int] | None:
    parts = v.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        return None
    return tuple(int(p) for p in parts)  # type: ignore[return-value]


def fetch_upstream_tags() -> list[str]:
    out = subprocess.check_output(
        ["gh", "api", "--paginate", "/repos/ArduPilot/ardupilot/git/refs/tags?per_page=100"],
        text=True,
    )
    # gh --paginate concatenates JSON arrays; split on `][` and rejoin.
    chunks = out.replace("][", ",").strip()
    data = json.loads(chunks)
    return [r["ref"].removeprefix("refs/tags/") for r in data]


def fetch_our_release_tags() -> set[str]:
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    out = subprocess.check_output(
        ["gh", "release", "list", "--repo", repo, "--limit", "1000", "--json", "tagName"],
        text=True,
    )
    return {r["tagName"] for r in json.loads(out)}


def classify(tag: str) -> tuple[str, str] | None:
    for vehicle, pat in VEHICLE_PATTERNS.items():
        m = pat.match(tag)
        if m:
            return vehicle, m.group(1)
    return None


def main() -> int:
    upstream = fetch_upstream_tags()
    ours = fetch_our_release_tags()

    missing: list[dict] = []
    for tag in upstream:
        if tag in ours:
            continue
        c = classify(tag)
        if c is None:
            continue
        vehicle, version = c
        v = parse_version(version)
        if v is None or v < MIN_VERSION:
            continue
        missing.append({"vehicle": vehicle, "version": version, "ardupilotTag": tag})

    json.dump(missing, sys.stdout, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
