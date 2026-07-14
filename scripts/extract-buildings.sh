#!/usr/bin/env bash
set -euo pipefail

# Usage: extract-buildings.sh <output> [bounds] [maxzoom]
#   output:  output .pmtiles filename
#   bounds:  optional "lon_min,lat_min,lon_max,lat_max" to clip to a sub-region (omit for national)
#   maxzoom: optional max zoom level (default: 13) -- no Z14/Detailed tier
#
# Extracts a region/zoom subset directly from VIDA's pre-tiled, pre-deduplicated
# building footprints (Google Open Buildings v3 + Microsoft GlobalMLBuildingFootprints +
# OSM, prioritized in that order) via HTTP range requests — no local download of the
# full ~1.1GB national archive required.
# Source: https://source.coop/vida/google-microsoft-osm-open-buildings (ODbL)
#
# The upstream server intermittently returns transient HTTP 500s near the end of a
# transfer (observed ~5 times across 21 extractions in testing) — retried below since
# a bare failure would otherwise fail the whole quarterly release for a server blip.

SOURCE_URL="https://data.source.coop/vida/google-microsoft-osm-open-buildings/pmtiles/by_country/country_iso=MDG/MDG.pmtiles"

OUTPUT="${1:?output is required}"
BOUNDS="${2:-}"
MAXZOOM="${3:-13}"

CMD=(pmtiles extract "$SOURCE_URL" "$OUTPUT" --maxzoom="$MAXZOOM")

if [ -n "$BOUNDS" ]; then
  CMD+=(--bbox="$BOUNDS")
fi

echo "Running: ${CMD[*]}"

for attempt in 1 2 3 4 5; do
  if "${CMD[@]}"; then
    sha256sum "$OUTPUT" > "${OUTPUT}.sha256"
    echo "Extracted $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
    exit 0
  fi
  echo "Attempt $attempt failed, retrying..." >&2
  rm -f "$OUTPUT"
  sleep 3
done

echo "error: failed to extract $OUTPUT after 5 attempts" >&2
exit 1
