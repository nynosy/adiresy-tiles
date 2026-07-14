#!/usr/bin/env bash
set -euo pipefail

# Usage: build.sh <area> [bounds] [output] [maxzoom]
#   area:    Geofabrik area name (e.g. madagascar)
#   bounds:  optional sub-region clip, either "lon_min,lat_min,lon_max,lat_max" (bbox)
#            or a path to a .poly file, Osmosis polygon filter format -- NOT GeoJSON.
#            Not used by the current national-only pipeline (no region/province split,
#            see docs/National-Only-Simplification-Implementation-Spec.md in adiresy-mobile),
#            kept generic since build-tiles.yml always calls this with bounds="".
#   output:  output .pmtiles filename (default: <area>.pmtiles)
#   maxzoom: optional max zoom level (default: 13). See docs/TileGen-Implementation-Spec.md
#            for the Overview(12)/Standard(13) quality tiers -- no Z14/Detailed tier.
#
# OSM's building layer is excluded here — scripts/extract-buildings.sh provides a denser,
# deduplicated buildings overlay (Google Open Buildings + Microsoft + OSM, via VIDA) instead.

AREA="${1:?area is required}"
BOUNDS="${2:-}"
OUTPUT="${3:-${AREA}.pmtiles}"
MAXZOOM="${4:-13}"

MINZOOM=0
PLANETILER_VERSION="v0.10.2"   # pinned -- this is the version all local/CI builds have been validated against
PLANETILER_JAR="planetiler.jar"

if [ ! -f "$PLANETILER_JAR" ]; then
  echo "Downloading Planetiler $PLANETILER_VERSION..."
  curl -fL -o "$PLANETILER_JAR" \
    "https://github.com/onthegomap/planetiler/releases/download/${PLANETILER_VERSION}/planetiler.jar"
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
