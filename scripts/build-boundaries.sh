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

OUTPUT="${1:-boundaries.pmtiles}"

SHP_URL="https://data.humdata.org/dataset/26fa506b-0727-4d9d-a590-d2abee21ee22/resource/ed94d52e-349e-41be-80cb-62dc0435bd34/download/mdg_adm_bngrc_ocha_20181031_shp.zip"
SHP_BASENAME="mdg_admbndl_all_BNGRC_OCHA_20181031"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Downloading BNGRC/OCHA admin boundaries..."
curl -fL -o "$WORKDIR/mdg_adm_shp.zip" "$SHP_URL"
unzip -q "$WORKDIR/mdg_adm_shp.zip" -d "$WORKDIR/extracted"

echo "Converting to GeoJSON..."
ogr2ogr -f GeoJSON -t_srs EPSG:4326 \
  "$WORKDIR/boundaries.geojson" \
  "$WORKDIR/extracted/${SHP_BASENAME}.shp"

echo "Assigning per-level minzoom (coarser levels visible from further out)..."
python3 - "$WORKDIR/boundaries.geojson" "$WORKDIR/boundaries_zoomed.geojson" <<'PYEOF'
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
