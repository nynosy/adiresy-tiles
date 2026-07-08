#!/usr/bin/env python3
"""Generate manifest.json from build outputs in the current directory."""
import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

PROVINCES = [
    "antananarivo", "fianarantsoa", "toamasina",
    "mahajanga", "toliara", "antsiranana",
]

# Quality tiers, see docs/TileGen-Implementation-Spec.md for the size/detail tradeoff.
TIERS = ["z12", "z13", "z14"]

# Both overlays are static upstream snapshots, not refreshed on our quarterly cadence
# the way OSM is (see TG-12/TG-14) -- hardcoded here until VIDA/HDX publish updates.
BUILDINGS_DATASET_DATE = "2024-08-27"   # VIDA MDG.pmtiles Last-Modified header
BOUNDARIES_DATASET_DATE = "2018-10-31"  # HDX COD-AB shapefile date


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_entry(path: str, url: str) -> dict:
    return {
        "filename": os.path.basename(path),
        "url": url,
        "size_bytes": os.path.getsize(path),
        "sha256": sha256_of(path),
    }


def region_tiers(filename_for_tier, base_url: str) -> dict:
    tiers = {}
    for tier in TIERS:
        path = filename_for_tier(tier)
        if os.path.exists(path):
            tiers[tier] = file_entry(path, f"{base_url}/{path}")
    return tiers


def provinces_tiers(filename_for, base_url: str) -> dict:
    provinces = {}
    for name in PROVINCES:
        tiers = region_tiers(lambda t, name=name: filename_for(name, t), base_url)
        if tiers:
            provinces[name] = tiers
    return provinces


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True, help="Release tag, e.g. data-2026-Q3")
    parser.add_argument("--owner", required=True, help="GitHub owner/org")
    parser.add_argument("--repo", default="adiresy-tiles")
    parser.add_argument("--osm-extract-date", required=True,
                         help="YYYY-MM-DD, parsed from Geofabrik's replication state.txt (see workflow)")
    parser.add_argument("--output", default="manifest.json")
    args = parser.parse_args()

    base_url = f"https://github.com/{args.owner}/{args.repo}/releases/download/{args.tag}"

    manifest = {
        "version": args.tag.removeprefix("data-"),
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "osm_extract_date": args.osm_extract_date,
        "files": {},
    }

    national_tiers = region_tiers(lambda t: f"madagascar-{t}.pmtiles", base_url)
    if not national_tiers:
        sys.exit("error: no madagascar-z{12,13,14}.pmtiles found")
    manifest["files"]["national"] = national_tiers

    provinces = provinces_tiers(lambda name, t: f"province-{name}-{t}.pmtiles", base_url)
    if provinces:
        manifest["provinces"] = provinces

    # Buildings overlay: Google Open Buildings v3 + Microsoft + OSM, merged and
    # deduplicated by VIDA (https://source.coop/vida/google-microsoft-osm-open-buildings).
    buildings = {}
    buildings_national = region_tiers(lambda t: f"buildings-madagascar-{t}.pmtiles", base_url)
    if buildings_national:
        buildings["national"] = buildings_national
    buildings_provinces = provinces_tiers(lambda name, t: f"buildings-province-{name}-{t}.pmtiles", base_url)
    if buildings_provinces:
        buildings["provinces"] = buildings_provinces
    if buildings:
        buildings["dataset_date"] = BUILDINGS_DATASET_DATE
        manifest["buildings"] = buildings

    # Admin boundaries overlay: region/district/commune/fokontany lines from
    # BNGRC/OCHA (see scripts/build-boundaries.sh). Single small national file,
    # not split by tier or province -- there's no size reason to.
    boundaries_path = "boundaries.pmtiles"
    if os.path.exists(boundaries_path):
        manifest["boundaries"] = file_entry(boundaries_path, f"{base_url}/{boundaries_path}")
        manifest["boundaries"]["dataset_date"] = BOUNDARIES_DATASET_DATE

    with open(args.output, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
