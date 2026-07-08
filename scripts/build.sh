#!/usr/bin/env bash
set -euo pipefail

# Usage: build.sh <area> [bounds] [output] [maxzoom]
#   area:    Geofabrik area name (e.g. madagascar)
#   bounds:  optional sub-region clip, either "lon_min,lat_min,lon_max,lat_max" (bbox)
#            or a path to a .poly file, Osmosis polygon filter format -- NOT GeoJSON,
#            Planetiler's --polygon= doesn't accept that (see scripts/generate-province-polygons.sh,
#            resolves TG-16 — exact province geometry instead of a hand-drawn bbox)
#   output:  output .pmtiles filename (default: <area>.pmtiles)
#   maxzoom: optional max zoom level (default: 14). See docs/TileGen-Implementation-Spec.md
#            for the Overview(12)/Standard(13)/Detailed(14) quality tiers.
#
# OSM's building layer is excluded here — scripts/extract-buildings.sh provides a denser,
# deduplicated buildings overlay (Google Open Buildings + Microsoft + OSM, via VIDA) instead.

AREA="${1:?area is required}"
BOUNDS="${2:-}"
OUTPUT="${3:-${AREA}.pmtiles}"
MAXZOOM="${4:-14}"

MINZOOM=0
PLANETILER_JAR="planetiler.jar"

if [ ! -f "$PLANETILER_JAR" ]; then
  echo "Downloading Planetiler..."
  curl -fL -o "$PLANETILER_JAR" \
    https://github.com/onthegomap/planetiler/releases/latest/download/planetiler.jar
fi

CMD=(java -Xmx4g -jar "$PLANETILER_JAR"
     --area="$AREA" --download
     --output="$OUTPUT"
     --minzoom="$MINZOOM" --maxzoom="$MAXZOOM"
     --exclude_layers=building)

if [[ "$BOUNDS" == *.poly ]]; then
  CMD+=(--polygon="$BOUNDS")
elif [ -n "$BOUNDS" ]; then
  CMD+=(--bounds="$BOUNDS")
fi

echo "Running: ${CMD[*]}"
"${CMD[@]}"

sha256sum "$OUTPUT" > "${OUTPUT}.sha256"
echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
