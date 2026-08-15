#!/usr/bin/env bash
set -euo pipefail

# Usage: build-boundaries.sh [output]
#   output: output .pmtiles filename (default: boundaries.pmtiles)
#
# Downloads BNGRC/OCHA's administrative boundary lines for Madagascar (region,
# district, commune, fokontany — matches what adiresy.mg renders) from HDX's
# COD-AB dataset and tiles them with tippecanoe. Requires `ogr2ogr` (GDAL) and
# `tippecanoe` on PATH.
# Source: https://data.humdata.org/dataset/cod-ab-mdg (CC BY-IGO)
#
# HDX republished this dataset 2026-08-13, replacing the 2018-10-31 vintage
# (previously a single combined mdg_admbndl_all_BNGRC_OCHA_20181031.shp) with
# a per-level layout (mdg_admin0..4.shp polygons + mdg_adminlines.shp for
# boundary lines) and renumbered pcodes (field names admLevel/ADM2_L/ADM2_R
# -> adm_level/left_pcod/right_pcod). Confirmed directly with ogrinfo: the new
# data already reflects Madagascar's current 24-region split natively (e.g.
# Vatovavy/Fitovinany and Ambatosoa are already separate ADM1 regions), so the
# region-split corrections below are gone. Antananarivo-Renivohitra's 6
# arrondissements are still miscoded as separate ADM2 "districts", just under
# new pcodes -- that correction remains, updated.

OUTPUT="${1:-boundaries.pmtiles}"

SHP_URL="https://data.humdata.org/dataset/26fa506b-0727-4d9d-a590-d2abee21ee22/resource/d5ede998-21e3-437b-9157-dc16593b44eb/download/mdg_admin_boundaries.shp.zip"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Downloading BNGRC/OCHA admin boundaries..."
curl -fL -o "$WORKDIR/mdg_adm_shp.zip" "$SHP_URL"
unzip -q "$WORKDIR/mdg_adm_shp.zip" -d "$WORKDIR/extracted"

echo "Converting to GeoJSON..."
ogr2ogr -f GeoJSON -t_srs EPSG:4326 \
  "$WORKDIR/boundaries.geojson" \
  "$WORKDIR/extracted/mdg_adminlines.shp"

echo "Correcting district admLevel drift (resolves GH issue #2 item 1)..."
python3 - "$WORKDIR/boundaries.geojson" "$WORKDIR/boundaries_corrected.geojson" <<'PYEOF'
import json
import sys

# As of the 2026-08-13 HDX republish, the source data already reflects
# Madagascar's current 24-region split natively (Vatovavy, Fitovinany, and
# Ambatosoa are already separate ADM1 regions) -- the region-level drift
# this correction used to fix (issue #2 items 2-3) is resolved upstream.
#
# One issue remains: Antananarivo-Renivohitra's 6 arrondissements are still
# coded as 6 separate ADM2 "districts" (pcodes MG11118..MG11123, renumbered
# from the pre-2026-08 pcodes but the same underlying data quirk). A district
# inside a district breaks the Region > District > Commune > Fokontany
# hierarchy adiresy.mg renders, so the boundaries between them are downgraded
# from admLevel 2 (district) to 3 (commune), matching how adiresy.mg treats
# them. No geometry is wrong -- only which level these existing line segments
# should be classified at. See https://github.com/nynosy/adiresy-tiles/issues/2.
ANTANANARIVO_RENIVOHITRA_ARRONDISSEMENTS = {
    "MG11118", "MG11119", "MG11120",
    "MG11121", "MG11122", "MG11123",
}
#
# This brings the tileset's effective district count down by 6, matching
# adiresy.mg and https://en.wikipedia.org/wiki/Districts_of_Madagascar.
# Fokontany/commune-level (ADM3/ADM4) drift is tracked separately, unresolved
# (issue #2 item 3).

def corrected_adm_level(props):
    level = props.get("adm_level")
    if level != 2:
        # Only district-level (adm_level 2) lines are affected by the rule
        # above. Skip everything else -- in particular, fokontany-level
        # (adm_level 4) lines *inside* a single arrondissement also truncate
        # to that arrondissement's pcode on both sides (a subset of
        # ANTANANARIVO_RENIVOHITRA_ARRONDISSEMENTS too), but must stay at 4.
        return level
    # left_pcod/right_pcod always carry the finest (fokontany-level) pcode on
    # each side of the line, regardless of the line's own adm_level -- not
    # the district-level pcode directly. Truncating to the first 7 chars
    # (MG + 2-digit region + 3-digit district) recovers the district pcode,
    # confirmed against the adm2 layer's own pcode format (e.g. "MG11118").
    left = str(props.get("left_pcod") or "")[:7]
    right = str(props.get("right_pcod") or "")[:7]
    if {left, right} <= ANTANANARIVO_RENIVOHITRA_ARRONDISSEMENTS:
        return 3
    return level

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    data = json.load(f)

for feature in data["features"]:
    # Output key stays "admLevel" (not adm_level) -- adiresy-mobile's
    # StyleLoader matches on this property name in the tiled output.
    feature["properties"]["admLevel"] = corrected_adm_level(feature["properties"])

with open(dst, "w") as f:
    json.dump(data, f)
PYEOF

echo "Assigning per-level minzoom (coarser levels visible from further out)..."
python3 - "$WORKDIR/boundaries_corrected.geojson" "$WORKDIR/boundaries_zoomed.geojson" <<'PYEOF'
import json
import sys

# admLevel: 1=region, 2=district, 3=commune, 4=fokontany, 99=coastline/external.
# The "tippecanoe" key must be a top-level sibling of "properties", not nested
# inside it -- that's the only place tippecanoe recognizes it as a control key.
MINZOOM_BY_LEVEL = {1: 0, 2: 4, 3: 7, 4: 9, 99: 0}

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    data = json.load(f)

for feature in data["features"]:
    level = feature["properties"].get("admLevel")
    feature["tippecanoe"] = {"minzoom": MINZOOM_BY_LEVEL.get(level, 0)}

with open(dst, "w") as f:
    json.dump(data, f)
PYEOF

echo "Tiling with tippecanoe..."
tippecanoe -o "$OUTPUT" -l boundaries \
  -n "Madagascar administrative boundaries (BNGRC/OCHA)" \
  -Z0 -z12 --force \
  "$WORKDIR/boundaries_zoomed.geojson"

sha256sum "$OUTPUT" > "${OUTPUT}.sha256"
echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
