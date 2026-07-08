#!/usr/bin/env bash
set -euo pipefail

# Usage: generate-province-polygons.sh [outdir]
# Dissolves BNGRC/OCHA's ADM1 polygons by OLD_PROVIN into the 6 legacy
# provinces (resolves TG-16). Writes province-<name>.poly (Osmosis polygon
# filter format, for Planetiler's build.sh --polygon= -- Planetiler does NOT
# accept GeoJSON there) and province-bounds.json (for extract-buildings.sh
# --bbox=, since pmtiles extract has no polygon clip). Requires ogr2ogr.

OUTDIR="${1:-.}"
mkdir -p "$OUTDIR"

SHP_URL="https://data.humdata.org/dataset/26fa506b-0727-4d9d-a590-d2abee21ee22/resource/ed94d52e-349e-41be-80cb-62dc0435bd34/download/mdg_adm_bngrc_ocha_20181031_shp.zip"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Downloading BNGRC/OCHA admin boundaries..."
curl -fL -o "$WORKDIR/mdg_adm_shp.zip" "$SHP_URL"
unzip -q "$WORKDIR/mdg_adm_shp.zip" -d "$WORKDIR/extracted"

ADM1_SHP=$(find "$WORKDIR/extracted" -iname "*admbnda*adm1*.shp" | head -1)
if [ -z "$ADM1_SHP" ]; then
  echo "error: no ADM1 polygon shapefile (*admbnda*adm1*.shp) found in the archive" >&2
  find "$WORKDIR/extracted" -iname "*.shp" >&2
  exit 1
fi
LAYER=$(basename "$ADM1_SHP" .shp)

echo "Dissolving ADM1 polygons by OLD_PROVIN..."
ogr2ogr -f GeoJSON -t_srs EPSG:4326 -nlt PROMOTE_TO_MULTI \
  -dialect sqlite -sql "SELECT OLD_PROVIN, ST_Union(geometry) AS geometry FROM \"$LAYER\" GROUP BY OLD_PROVIN" \
  "$WORKDIR/dissolved.geojson" "$ADM1_SHP"

echo "Splitting into per-province .poly files + computing bboxes..."
python3 - "$WORKDIR/dissolved.geojson" "$OUTDIR" <<'PYEOF'
import json
import sys

src, outdir = sys.argv[1], sys.argv[2]
names = {
    "Antananarivo": "antananarivo",
    "Fianarantsoa": "fianarantsoa",
    "Toamasina": "toamasina",
    "Mahajanga": "mahajanga",
    "Toliary": "toliara",  # sic -- BNGRC/OCHA's OLD_PROVIN spells it "Toliary", not "Toliara"
    "Antsiranana": "antsiranana",
}

with open(src) as f:
    data = json.load(f)

def walk_coords(geom):
    if isinstance(geom, (list, tuple)):
        if geom and isinstance(geom[0], (int, float)):
            yield geom
        else:
            for g in geom:
                yield from walk_coords(g)

def polygons_of(geometry):
    # Normalizes Polygon/MultiPolygon coordinates to a list of polygons,
    # each a list of rings (first ring outer, rest holes).
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"]]
    return geometry["coordinates"]

def write_poly(path, name, geometry):
    with open(path, "w") as f:
        f.write(f"{name}\n")
        ring_id = 0
        for polygon in polygons_of(geometry):
            for i, ring in enumerate(polygon):
                ring_id += 1
                tag = f"!{ring_id}" if i > 0 else str(ring_id)
                f.write(f"{tag}\n")
                for lon, lat in ring:
                    f.write(f"    {lon:.7f}    {lat:.7f}\n")
                f.write("END\n")
        f.write("END\n")

bounds = {}
found = set()
for feature in data["features"]:
    old_provin = feature["properties"].get("OLD_PROVIN")
    name = names.get(old_provin)
    if name is None:
        continue
    found.add(name)

    lons = [c[0] for c in walk_coords(feature["geometry"]["coordinates"])]
    lats = [c[1] for c in walk_coords(feature["geometry"]["coordinates"])]
    bounds[name] = f"{min(lons)},{min(lats)},{max(lons)},{max(lats)}"

    write_poly(f"{outdir}/province-{name}.poly", name, feature["geometry"])

missing = set(names.values()) - found
if missing:
    sys.exit(f"error: OLD_PROVIN values not found for: {sorted(missing)}")

with open(f"{outdir}/province-bounds.json", "w") as f:
    json.dump(bounds, f, indent=2)
PYEOF

echo "Wrote province-<name>.poly (x6) and province-bounds.json to $OUTDIR"
