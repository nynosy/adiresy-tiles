#!/usr/bin/env python3
"""Generate manifest.json from build outputs in the current directory."""
import argparse
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

# Quality tiers, see docs/TileGen-Implementation-Spec.md for the size/detail tradeoff.
TIERS = ["z12", "z13"]

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


def national_tiers(filename_for_tier, base_url: str) -> dict:
    tiers = {}
    for tier in TIERS:
        path = filename_for_tier(tier)
        if os.path.exists(path):
            tiers[tier] = file_entry(path, f"{base_url}/{path}")
    return tiers


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

    files_national = national_tiers(lambda t: f"madagascar-{t}.pmtiles", base_url)
    if not files_national:
        sys.exit("error: no madagascar-z{12,13}.pmtiles found")
    manifest["files"]["national"] = files_national

    # Buildings overlay: Google Open Buildings v3 + Microsoft + OSM, merged and
    # deduplicated by VIDA (https://source.coop/vida/google-microsoft-osm-open-buildings).
    buildings_national = national_tiers(lambda t: f"buildings-madagascar-{t}.pmtiles", base_url)
    if buildings_national:
        manifest["buildings"] = {
            "national": buildings_national,
            "dataset_date": BUILDINGS_DATASET_DATE,
        }

    # POI overlay: schools, hospitals, shops, etc. at min_zoom=12 (config/poi-overlay.yml),
    # bypassing OpenMapTiles' built-in poi layer, which gates most categories to z14.
    # Derived from the same Geofabrik extract as the base map, so no separate
    # dataset_date -- osm_extract_date already covers it.
    poi_national = national_tiers(lambda t: f"poi-madagascar-{t}.pmtiles", base_url)
    if poi_national:
        manifest["poi"] = {"national": poi_national}

    # Admin boundaries overlay: region/district/commune/fokontany lines from
    # BNGRC/OCHA (see scripts/build-boundaries.sh). Single small national file,
    # not split by tier -- there's no size reason to.
    boundaries_path = "boundaries.pmtiles"
    if os.path.exists(boundaries_path):
        manifest["boundaries"] = file_entry(boundaries_path, f"{base_url}/{boundaries_path}")
        manifest["boundaries"]["dataset_date"] = BOUNDARIES_DATASET_DATE

    with open(args.output, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
