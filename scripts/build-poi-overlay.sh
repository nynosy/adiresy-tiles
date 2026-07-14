#!/usr/bin/env bash
set -euo pipefail

# Usage: build-poi-overlay.sh <area> [bounds] [output] [maxzoom]
#   area:    Geofabrik area name (e.g. madagascar)
#   bounds:  optional sub-region clip, either "lon_min,lat_min,lon_max,lat_max" (bbox)
#            or a path to a .poly file. Not used by the current national-only
#            pipeline (no region/province split), kept generic since build-tiles.yml
#            always calls this with bounds="".
#   output:  output .pmtiles filename (default: <area>-poi.pmtiles)
#   maxzoom: optional max zoom level (default: 13). See the quality tier table in
#            docs/TileGen-Implementation-Spec.md -- no Z14/Detailed tier.
#
# Extracts POI points (schools, hospitals, shops, offices, etc.) via a custom
# Planetiler schema (config/poi-overlay.yml) at a fixed min_zoom=12, bypassing
# OpenMapTiles' built-in poi layer, which gates most POI categories to z14 --
# confirmed empirically to leave the base map with almost no POIs at the
# Overview/Standard tiers otherwise. Uses the same planetiler.jar as build.sh
# (shares its download-once-per-directory cache) but via a different entry
# point (ConfiguredMapMain, not the default OpenMapTilesMain), since Planetiler
# has no supported way to override the built-in profile's zoom thresholds.

AREA="${1:?area is required}"
BOUNDS="${2:-}"
OUTPUT="${3:-${AREA}-poi.pmtiles}"
MAXZOOM="${4:-13}"

SCHEMA="$(dirname "$0")/../config/poi-overlay.yml"
PLANETILER_VERSION="v0.10.2"   # pinned -- matches build.sh, see there for why
PLANETILER_JAR="planetiler.jar"

if [ ! -f "$PLANETILER_JAR" ]; then
  echo "Downloading Planetiler $PLANETILER_VERSION..."
  curl -fL -o "$PLANETILER_JAR" \
    "https://github.com/onthegomap/planetiler/releases/download/${PLANETILER_VERSION}/planetiler.jar"
fi

CMD=(java -Xmx4g -cp "$PLANETILER_JAR" com.onthegomap.planetiler.custommap.ConfiguredMapMain
     --schema="$SCHEMA"
     --area="$AREA" --download
     --output="$OUTPUT"
     --maxzoom="$MAXZOOM"
     --force)

if [[ "$BOUNDS" == *.poly ]]; then
  CMD+=(--polygon="$BOUNDS")
elif [ -n "$BOUNDS" ]; then
  CMD+=(--bounds="$BOUNDS")
fi

echo "Running: ${CMD[*]}"
"${CMD[@]}"

sha256sum "$OUTPUT" > "${OUTPUT}.sha256"
echo "Built $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
