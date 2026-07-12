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

echo "Correcting region/district admLevel drift (resolves GH issue #2)..."
python3 - "$WORKDIR/boundaries.geojson" "$WORKDIR/boundaries_corrected.geojson" <<'PYEOF'
import json
import sys

# HDX's 2018-10-31 shapefile is frozen at Madagascar's 2004 admin split (22
# regions / 119 "districts") and doesn't reflect two legal changes since, so
# its admLevel classification drifts from the real Region > District >
# Commune > Fokontany hierarchy adiresy.mg renders. No geometry is wrong --
# only which level these existing line segments should be classified at.
# See https://github.com/nynosy/adiresy-tiles/issues/2.
#
# 1. Antananarivo-Renivohitra's 6 arrondissements are coded as 6 separate
#    ADM2 "districts" (pcodes MG11101001A..MG11101006A) -- the shapefile's
#    own NOTES field admits this: "Previous district name is Antananarivo
#    Renivohitra (MDG11101)". A district inside a district breaks the
#    hierarchy, so the boundaries between them are downgraded from admLevel
#    2 (district) to 3 (commune), matching how adiresy.mg treats them.
ANTANANARIVO_RENIVOHITRA_ARRONDISSEMENTS = {
    "MG11101001A", "MG11101002A", "MG11101003A",
    "MG11101004A", "MG11101005A", "MG11101006A",
}

# 2. "Vatovavy Fitovinany" region (MG23) was split into Vatovavy and
#    Fitovinany regions by LOI n° 2021-012 (2021-06-24). Its 6 districts
#    split 3/3, so the boundary between the two groups is now a region
#    boundary (admLevel 2 -> 1), not an internal district boundary.
VATOVAVY_DISTRICTS = {"MG23206", "MG23207", "MG23209"}      # Ifanadiana, Nosy-Varika, Mananjary
FITOVINANY_DISTRICTS = {"MG23210", "MG23211", "MG23212"}    # Manakara Atsimo, Ikongo, Vohipeno

# 3. Ambatosoa region was carved out of northern Analanjirofo (MG32) by a
#    2023 law, inaugurated 2025 -- taking 2 of its 6 districts. Same fix:
#    admLevel 2 -> 1 on the boundary between the two groups.
AMBATOSOA_DISTRICTS = {"MG32303", "MG32304"}                        # Maroantsetra, Mananara-Avaratra
ANALANJIROFO_DISTRICTS = {"MG32302", "MG32305", "MG32315", "MG32318"}  # Sainte Marie, Fenerive Est, Vavatenina, Soanierana Ivongo
#
# Together this brings the tileset's effective counts from 22 regions / 119
# districts to 24 / 114, matching adiresy.mg and https://en.wikipedia.org/
# wiki/Districts_of_Madagascar. Fokontany/commune-level (ADM3/ADM4) drift is
# tracked separately, unresolved (issue #2 item 3).

def corrected_adm_level(props):
    level = props.get("admLevel")
    if level != 2:
        # Only district-level (admLevel 2) lines are affected by the three
        # rules above. Skip everything else -- in particular, fokontany-level
        # (admLevel 4) lines *inside* a single arrondissement also have both
        # ADM2_L and ADM2_R equal to that arrondissement's pcode (a subset of
        # ANTANANARIVO_RENIVOHITRA_ARRONDISSEMENTS too), but must stay at 4.
        return level
    sides = {props.get("ADM2_L"), props.get("ADM2_R")}
    if sides <= ANTANANARIVO_RENIVOHITRA_ARRONDISSEMENTS:
        return 3
    if (sides & VATOVAVY_DISTRICTS) and (sides & FITOVINANY_DISTRICTS):
        return 1
    if (sides & AMBATOSOA_DISTRICTS) and (sides & ANALANJIROFO_DISTRICTS):
        return 1
    return level

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    data = json.load(f)

for feature in data["features"]:
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
