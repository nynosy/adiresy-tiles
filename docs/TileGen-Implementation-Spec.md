# Tile Generation Repository — Implementation Specification

**Status:** Draft.
**Purpose of this document:** define concrete, ready-to-implement artifacts (exact file contents, schemas, and CI job design) so the repo can be built directly from this spec, organized into milestones (T0–T5). Where a decision is open, this spec makes a concrete choice and calls it out explicitly rather than silently picking one.

---

## 1. Repository layout (final)

```
adiresy-tiles/
├─ .github/
│   └─ workflows/
│       └─ build-tiles.yml
├─ config/
│   ├─ planetiler-mg.yml          # documentation only — see §3 note
│   └─ poi-overlay.yml            # custom Planetiler schema, low-zoom POI overlay — see §6
├─ scripts/
│   ├─ build.sh                   # base map tiles (OSM via Planetiler)
│   ├─ extract-buildings.sh       # buildings overlay (VIDA, via pmtiles extract)
│   ├─ build-poi-overlay.sh       # low-zoom POI overlay (custom Planetiler schema)
│   ├─ build-boundaries.sh        # admin boundaries overlay (BNGRC/OCHA, via tippecanoe)
│   ├─ generate-province-polygons.sh  # exact province-split geometry (BNGRC/OCHA ADM1, resolves TG-16)
│   └─ generate-manifest.py
├─ .gitignore
└─ README.md
```

## 2. `.gitignore`

```gitignore
*.pmtiles
*.pmtiles.sha256
*.osm.pbf
graph-cache/
data/
planetiler.jar
manifest.json
```

`manifest.json` is a build output (like the tiles), not source — it's generated fresh on every run, so it's excluded rather than committed.

## 3. Planetiler configuration & quality tiers

**Decision (resolves TG-2):** rather than picking one fixed maxzoom, the pipeline builds **three quality tiers** per region (national and each province), so the app can offer users a size/detail tradeoff instead of a single fixed download:

| Tier | Maxzoom | National size (measured) | Detail |
|---|---|---|---|
| **Overview** | Z12 | 43,073,104 bytes (~43 MB) | Main roads and towns — coarse detail |
| **Standard** | Z13 | 102,044,208 bytes (~102 MB) | Block-level detail — recommended default |
| **Detailed** | Z14 | 301,805,319 bytes (~302 MB) | Street-level detail — best for walking navigation in dense areas |

These are real measurements from a local build of the national extract, not estimates. Province tiers will be proportionally smaller. An experiment restricting Planetiler's `--languages` flag (to cut down the ~90 default name-translation languages) was also tried and made a negligible difference (301.8 MB → 301.4 MB, ~0.1%) — geometry, not name text, dominates file size, so that lever isn't worth pursuing.

**Decision:** `build.sh` passes `--exclude_layers=building` to Planetiler. OSM's `building` layer is dropped from these base tiles because §5 (`extract-buildings.sh`) provides a separate, much denser buildings overlay (Google Open Buildings + Microsoft + OSM, deduplicated). Rendering both would duplicate footprints, since the overlay already includes OSM's buildings as its lowest-priority fallback.

Planetiler's CLI does not read a YAML config file for the plain area/bounds/zoom flags used here (that's only true for full custom profile definitions). `config/planetiler-mg.yml` is kept as **human-readable documentation of the flags**, not a file consumed by any tool. The actual invocation lives in `scripts/build.sh`, which is the single source of truth.

```yaml
# config/planetiler-mg.yml — documentation of the flags used in scripts/build.sh.
# Not read by Planetiler directly; the invocation in scripts/build.sh is the
# single source of truth.
area: madagascar
minzoom: 0
maxzoom: 14        # Z14: street-level nav detail vs. file size. Validate before locking in — see TG-2.
download: true      # Fetches the Geofabrik extract automatically; cached under sources/
```

## 4. `scripts/build.sh`

Reusable for national and province builds, and for any of the three quality tiers — `maxzoom` is now a parameter rather than hardcoded. Reruns within the same working directory reuse the cached Geofabrik download instead of re-fetching it, so building all three tiers for a region only pays the download cost once. The `bounds` argument accepts either a bbox string or a `.poly` polygon path (from `scripts/generate-province-polygons.sh`, §7 — resolves TG-8/TG-16), clipping with Planetiler's `--polygon=` in the latter case for exact province geometry instead of an approximate bbox. **Note:** `--polygon=` takes the Osmosis polygon filter text format, not GeoJSON — confirmed the hard way (§4 testing note below) after first assuming GeoJSON would work.

**Decision (resolves TG-3):** Planetiler is pinned to `v0.10.2` rather than tracking `latest` — every local and CI build so far has been validated against this exact version, and pinning avoids a future Planetiler release silently changing output (schema, sizes, flag behavior) between quarterly runs. `scripts/build-poi-overlay.sh` pins the same version, since it downloads the same jar.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Usage: build.sh <area> [bounds] [output] [maxzoom]
#   area:    Geofabrik area name (e.g. madagascar)
#   bounds:  optional sub-region clip, either "lon_min,lat_min,lon_max,lat_max" (bbox)
#            or a path to a .poly file, Osmosis polygon filter format -- NOT GeoJSON,
#            Planetiler's --polygon= doesn't accept that (see scripts/generate-province-polygons.sh,
#            resolves TG-16 — exact province geometry instead of a hand-drawn bbox)
#   output:  output .pmtiles filename (default: <area>.pmtiles)
#   maxzoom: optional max zoom level (default: 14). See the quality tier table above.
#
# OSM's building layer is excluded here — scripts/extract-buildings.sh provides a denser,
# deduplicated buildings overlay (Google Open Buildings + Microsoft + OSM, via VIDA) instead.

AREA="${1:?area is required}"
BOUNDS="${2:-}"
OUTPUT="${3:-${AREA}.pmtiles}"
MAXZOOM="${4:-14}"

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
```

**Verified locally:** national Z12 (`madagascar-z12.pmtiles`, 42M — matches §3's ~43MB) and a province Z12 build using `--polygon=province-mahajanga.poly` (6.5M, valid `pmtiles show`, bounds exactly matching `province-bounds.json`) both ran end-to-end. This caught a real bug: Planetiler's `--polygon=` takes the Osmosis polygon filter (`.poly`) text format, not GeoJSON — the first attempt with a `.geojson` path failed with `FileFormatException: File ends before end of polygon`. `generate-province-polygons.sh` (§7) now emits `.poly` directly instead.

## 5. Buildings overlay: Google Open Buildings via VIDA

**Decision (resolves the "adiresy.mg parity" question):** the live [adiresy.mg](https://adiresy.mg/) site sources its buildings from **Google Open Buildings**, not OSM (confirmed from the site's own attribution: "Bâtiments [Google Open Buildings]"). OSM building tagging in Madagascar is sparse compared to Google's ML-detected footprints, so relying on OSM alone (as §3/§4 do for the base map) would make the offline app's map noticeably sparser than the live site.

Rather than writing a custom Planetiler Java profile to ingest Google's raw Open Buildings CSVs (7.8 GB/file, split by S2 cell, no per-country filtering), [VIDA](https://source.coop/vida/google-microsoft-osm-open-buildings) publishes a pre-merged, pre-deduplicated, **pre-tiled** combination of Google Open Buildings v3 + Microsoft GlobalMLBuildingFootprints + OSM (priority in that order — Google wins where it has data, falling back to Microsoft then OSM), as PMTiles, licensed ODbL. Madagascar's full-country file:

```
https://data.source.coop/vida/google-microsoft-osm-open-buildings/pmtiles/by_country/country_iso=MDG/MDG.pmtiles
```

Confirmed via `pmtiles show` on the remote URL (works directly over HTTP range requests, no download needed to inspect): spec v3, zoom 0–15, `type: overlay`, `name: google_microsoft_osm_building_footprints_mdg`, generated by VIDA's tippecanoe pipeline. This file is **1.14 GB** for the whole country at native resolution — too big to bundle as-is.

The `pmtiles extract` CLI (`brew install pmtiles`, or `go-pmtiles` on Linux CI) can pull exactly the region/zoom subset we need directly from that remote URL, transferring only the required tiles (confirmed — see the size table below, measured via `--dry-run` and then for real). No Java/custom Planetiler profile needed; this is the same tiling infrastructure (PMTiles) we already use for the base map.

**Measured sizes** (this is the real cost, not an estimate — roughly triples every download compared to the base map alone):

| Region | Tier | Base map | + Buildings overlay | Total |
|---|---|---|---|---|
| National | Z12 | 43 MB | +153 MB | 196 MB |
| National | Z13 | 102 MB | +327 MB | 429 MB |
| National | Z14 | 302 MB | +694 MB | 996 MB |
| Antananarivo (largest province) | Z14 | 71.5 MB | +188 MB | 259.5 MB |
| Mahajanga (smallest province) | Z14 | 21.9 MB | +82 MB | 103.9 MB |

Given this cost, the decision was to ship the buildings overlay at **all three quality tiers** for national and all six provinces (21 buildings files, matching the 21 base-map files — 42 tile files total per release), rather than restricting it to the Detailed tier only. This was a deliberate choice given the size tradeoff, not a default — revisit if release size or CI bandwidth becomes a problem (see TG-12).

**File naming convention:** `buildings-madagascar-{tier}.pmtiles` for national, `buildings-province-{name}-{tier}.pmtiles` for provinces — mirrors the base map's `madagascar-{tier}.pmtiles` / `province-{name}-{tier}.pmtiles` but with a `buildings-` prefix, so release-asset globs stay disjoint (see §9).

**`scripts/extract-buildings.sh`:**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Usage: extract-buildings.sh <output> [bounds] [maxzoom]
#   output:  output .pmtiles filename
#   bounds:  optional "lon_min,lat_min,lon_max,lat_max" to clip to a sub-region (omit for national)
#   maxzoom: optional max zoom level (default: 14)
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
MAXZOOM="${3:-14}"

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
```

**Full 21-file matrix built and verified locally:** all national + province × tier combinations extracted, `pmtiles show` valid, all `.sha256` checksums verified, combined with the 21 base-map files into a complete manifest (42 file entries). Total local disk usage: 3.6 GB (base map ~1.0 GB + buildings ~2.6 GB) — resolves TG-13.

The transient-500 retry logic above isn't precautionary — it was needed for real. The first unattended run of all 21 extractions failed twice (once on Antananarivo Z12, once on Toliara Z12), both times with a `HTTP error: 500` from the upstream server at ~99% of the transfer, leaving a truncated/corrupt output file (`pmtiles show` failed with "magic number not detected" until the corrupt file was deleted and the extraction retried). A subsequent run with retry logic hit **5 more transient failures** across the remaining files, all recovered within 1–2 retries. This confirms TG-11 (VIDA as an external dependency) is a real, recurring reliability concern, not theoretical — roughly a ~25% per-file failure rate was observed in this testing session.

## 6. POI overlay: low-zoom points of interest

**Problem found:** a user report that schools/hospitals/POIs seemed "gone" from the map led to inspecting real generated tiles directly (`ogrinfo`/GDAL's PMTiles driver, plus `tippecanoe-decode` for raw MVT) rather than guessing. A small test build clipped to central Antananarivo, all three tiers, found the `poi` layer exists at every tier, but its feature count collapses at low zoom:

| Tier | Maxzoom | POI features (small test area) |
|---|---|---|
| Overview | Z12 | 17 (only major landmarks) |
| Standard | Z13 | 14 (only railway/ferry — zero schools or hospitals) |
| Detailed | Z14 | 9,152 (531 schools, 136 hospitals, 152 pharmacies, 77 doctors, plus shops, restaurants, offices, …) |

The underlying OSM data and Planetiler's extraction are both fine — this is OpenMapTiles' built-in vector-tile schema deliberately gating most POI classes to `min_zoom: 14` to control tile size/clutter, undocumented anywhere in this spec until now. Since §3 recommends the Standard (Z13) tier as the default, most users would see **no** schools, hospitals, pharmacies, or shops at all.

**Investigated: can OpenMapTiles' built-in minzoom be overridden?** No — confirmed via [a maintainer response in `onthegomap/planetiler` discussion #1485](https://github.com/onthegomap/planetiler/discussions/1485): there is no supported way to change per-class minzoom in the bundled OpenMapTiles profile short of forking and rebuilding `openmaptiles/planetiler-openmaptiles` from source. Not appropriate for this repo — that's a large upstream Java codebase we'd have to keep in sync with forever, for a config value.

**Decision: a separate low-zoom POI overlay**, matching this repo's existing pattern (buildings, boundaries are already separate overlay files, not modifications to the base map). Two implementation options were evaluated:

1. **Custom Java `Profile`** (Planetiler's general-purpose extension API) — full control, but requires a Maven project and Java build step in a repo that's otherwise pure bash/Python.
2. **Planetiler's native YAML custom-schema mode** (`com.onthegomap.planetiler.custommap.ConfiguredMapMain`, invoked via `--schema=file.yml`) — declarative tag-matching + fixed `min_zoom`, no Java/Maven needed, bundled in the same `planetiler.jar` already downloaded by `scripts/build.sh`.

Chose **(2)**, confirmed against the real jar (`java -cp planetiler.jar com.onthegomap.planetiler.custommap.ConfiguredMapMain --schema=...`) rather than trusting scraped documentation, after that exact caution paid off elsewhere in this spec (§4's `.poly`-not-GeoJSON bug). Verified empirically, in order:
- `--schema=` is real and works (`ConfiguredMapMain` exists in the downloaded jar; confirmed via `unzip -l` and a real invocation).
- The `min_zoom`/`include_when`/`attributes` YAML syntax shown in Planetiler's official `shortbread.yml` example schema (`planetiler-custommap/src/main/resources/samples/`) works as documented — tested with a 3-category schema against a small clipped area first.
- `type: match_key` / `type: match_value` attribute types (used for a `class`/`subclass` pair, mirroring OpenMapTiles' own convention) produce exactly the values inferred from the JSON schema (`planetiler.schema.json`) — e.g. for `amenity=school`, `class="amenity"`, `subclass="school"`.
- `--bounds=` and `--polygon=` (the same `.poly` files from `scripts/generate-province-polygons.sh`) both work identically to `scripts/build.sh`'s invocation, since both entry points share the same `PlanetilerConfig` argument parsing.
- **Tile-size risk at national scale, checked for real, not assumed:** the YAML DSL has no point-density/label-grid thinning option (that's Java-API-only, e.g. `setPointLabelGridSizeAndLimit`, not exposed declaratively) — a real concern given the project already hit a hard tile-size failure once before (tippecanoe's 500KB limit on the boundaries overlay, §7). Built the **actual full-country** overlay (not a clipped test) at `min_zoom=12`: 19,401 features nationwide, max tile 135kB (gzipped 60kB, over Antananarivo, the densest area) — comfortably safe, no size errors.

**`config/poi-overlay.yml`:** a curated set of `amenity`/`shop`/`healthcare`/`office`/`tourism`/`leisure`/`railway` tag values (chosen to cover the same real-world categories observed in the base map's own Z14 `poi` layer — healthcare, education, government/civic, food, shops, transit, lodging), all emitted to a single `poi` layer at a fixed `min_zoom: 12` — meaning they now appear starting at the *Overview* tier, the same as every other tier, resolving the original complaint directly. `class`/`subclass` attributes come from raw OSM tag key/value (not OpenMapTiles' internal normalized taxonomy — e.g. `subclass` may say `supermarket` where OpenMapTiles would say `grocery` — simpler and more transparent, at the cost of not being byte-for-byte identical to the base map's own category strings).

```yaml
schema_name: POI overlay (low-zoom)
schema_description: >
  Points of interest (schools, hospitals, shops, offices, etc.) visible starting
  well below OpenMapTiles' built-in poi layer, which gates most categories to z14.
attribution: <a href="https://www.openstreetmap.org/copyright" target="_blank">&copy; OpenStreetMap contributors</a>

args:
  area:
    description: Geofabrik area to download
    default: madagascar

sources:
  osm:
    type: osm
    url: '${ "geofabrik:" + args.area }'

layers:
  - id: poi
    features:
      - source: osm
        geometry: point
        min_zoom: 12
        include_when:
          amenity:
            - hospital
            - clinic
            - doctors
            - dentist
            - pharmacy
            - veterinary
            - school
            - college
            - university
            - library
            - police
            - fire_station
            - townhall
            - courthouse
            - post_office
            - embassy
            - community_centre
            - bank
            - atm
            - restaurant
            - cafe
            - bar
            - pub
            - fast_food
            - food_court
            - biergarten
            - marketplace
            - place_of_worship
            - cinema
            - theatre
            - arts_centre
            - fuel
            - parking
            - bus_station
            - ferry_terminal
            - nursing_home
            - prison
          shop:
            - supermarket
            - convenience
            - department_store
            - mall
            - bakery
            - butcher
            - greengrocer
            - alcohol
            - beverages
            - chemist
            - clothes
            - shoes
            - jewelry
            - books
            - stationery
            - computer
            - mobile_phone
            - electronics
            - hardware
            - doityourself
            - furniture
            - garden_centre
            - car
            - bicycle
            - hairdresser
            - beauty
            - laundry
            - optician
            - travel_agency
            - kiosk
          healthcare:
            - hospital
            - clinic
            - pharmacy
            - dentist
            - doctor
          office:
            - government
            - diplomatic
            - association
            - ngo
            - insurance
            - lawyer
            - estate_agent
          tourism:
            - hotel
            - motel
            - hostel
            - guest_house
            - bed_and_breakfast
            - museum
            - gallery
            - information
            - zoo
            - theme_park
            - attraction
          leisure:
            - park
            - garden
            - pitch
            - sports_centre
            - stadium
            - swimming_pool
            - golf_course
            - playground
          railway:
            - station
            - halt
        attributes:
          - key: class
            type: match_key
          - key: subclass
            type: match_value
          - key: name
            tag_value: name
          - key: name_fr
            tag_value: name:fr
```

**`scripts/build-poi-overlay.sh`:**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Usage: build-poi-overlay.sh <area> [bounds] [output] [maxzoom]
#   area:    Geofabrik area name (e.g. madagascar)
#   bounds:  optional sub-region clip, either "lon_min,lat_min,lon_max,lat_max" (bbox)
#            or a path to a .poly file (see scripts/generate-province-polygons.sh)
#   output:  output .pmtiles filename (default: <area>-poi.pmtiles)
#   maxzoom: optional max zoom level (default: 14). See the quality tier table in
#            docs/TileGen-Implementation-Spec.md.
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
MAXZOOM="${4:-14}"

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
```

**Verified locally:** the real committed script (not just scratch experiments) built successfully — national, all 3 tiers (644K/2.0M/3.0M, tiny relative to the base map's 43–302MB), a `--polygon=`-clipped province test (Mahajanga, matching class distribution: 5,478 amenity / 2,588 shop / 973 office / 711 tourism / 75 leisure / 50 railway / 4 healthcare), all valid `pmtiles show` output, `.sha256` checksums generated. `generate-manifest.py`'s new `poi` section (see §9) tested with a dry run and produces the expected nested structure.

**File naming convention:** `poi-madagascar-{tier}.pmtiles` / `poi-province-{name}-{tier}.pmtiles` — same `poi-` prefix pattern as `buildings-`, keeping release-asset globs disjoint (see §10).

**Not a separate dataset needing its own freshness field** (unlike buildings/boundaries, §9's `dataset_date`) — this overlay is derived from the same Geofabrik OSM extract as the base map on every build, so `osm_extract_date` already covers its freshness.

## 7. Administrative boundaries overlay: BNGRC/OCHA

**Decision:** the live [adiresy.mg](https://adiresy.mg/) site renders administrative boundary lines for all 4 official levels of Madagascar's territorial hierarchy — region → district → commune → fokontany — credited to BNGRC (Madagascar's national disaster management office) via OCHA. Our tiles had no equivalent: the OSM-derived `boundary` layer in the base map only carries whatever admin boundaries OSM happens to have tagged, which — like buildings — thins out fast below the region/district level.

Unlike buildings, there's no pre-tiled version of this dataset available anywhere — VIDA did that packaging work for buildings, nobody has for Madagascar's admin boundaries. So this one requires an actual conversion step: Shapefile → GeoJSON → PMTiles, using `ogr2ogr` (GDAL) and `tippecanoe`.

**Source:** [HDX's COD-AB Madagascar dataset](https://data.humdata.org/dataset/cod-ab-mdg) (queried via HDX's CKAN API, `https://data.humdata.org/api/3/action/package_show?id=cod-ab-mdg` — the HTML page blocks non-browser fetches). Licensed **CC BY-IGO** — a different license from ODbL (OSM/buildings) or CC-BY (OpenMapTiles), needs its own attribution line.

The zip (`mdg_adm_bngrc_ocha_20181031_shp.zip`, 66 MB) contains one shapefile per admin level (adm0–adm4, polygons) plus a combined `mdg_admbndl_all_BNGRC_OCHA_20181031.shp` — **boundary lines**, not polygons, with each shared border stored once (not duplicated per adjacent polygon) and an `admLevel` attribute (1=region, 2=district, 3=commune, 4=fokontany, 99=coastline/external) plus P-codes for both sides of each segment. This is the ideal single source for a borders-only overlay — used directly rather than deriving lines from the polygon layers ourselves.

**Discrepancy found:** HDX's indexed shapefile reports 22 regions / 119 districts / 1,579 communes / 17,465 fokontany (confirmed via `ogrinfo`, matches the HDX API's dataset description exactly). The live site states 24 / 114 / 1,707 / 17,465. Fokontany matches exactly; region/district/commune don't.

**Root cause (resolves region/district — [GH issue #2](https://github.com/nynosy/adiresy-tiles/issues/2)):** not a newer BNGRC release — the HDX file (2018-10-31) is genuinely the current geometry, just frozen at Madagascar's 2004 admin split for classification purposes. Two legal changes since then were never reflected in its `admLevel`/pcode scheme, and the file has one internal inconsistency:
- [Vatovavy Fitovinany region (MG23) split into Vatovavy and Fitovinany](https://www.assemblee-nationale.mg/wp-content/uploads/2021/07/LOI-n%C2%B02021-012-CTD.pdf) by LOI n° 2021-012 (2021-06-24) — its 6 districts split 3/3 (Ifanadiana/Nosy-Varika/Mananjary → Vatovavy; Manakara Atsimo/Ikongo/Vohipeno → Fitovinany).
- Ambatosoa region carved from northern Analanjirofo (MG32) by a 2023 law, inaugurated 2025 — taking 2 of its 6 districts (Maroantsetra, Mananara-Avaratra).
- Antananarivo-Renivohitra's 6 arrondissements (pcodes `MG11101001A`..`MG11101006A`) are coded as 6 separate ADM2 "districts" — confirmed by the shapefile's own `NOTES` field: *"Previous district name is Antananarivo Renivohitra (MDG11101)"*. A district nested inside a district breaks the Region > District > Commune > Fokontany hierarchy, and doesn't match [Wikipedia's 114-district list](https://en.wikipedia.org/wiki/Districts_of_Madagascar) (which lists Antananarivo-Renivohitra as a single, single-commune district, same treatment as Antsirabe I/Fianarantsoa I/etc).

All verified directly against the shapefile: `ogrinfo` on the ADM1/ADM2 polygon layers confirms 22 regions / 119 districts, with exactly those 6 arrondissement pcodes under `ADM1_PCODE=MG11` and exactly those district groupings under `MG23`/`MG32`. No geometry is wrong anywhere — only classification. `scripts/build-boundaries.sh` now reclassifies affected line segments' `admLevel` accordingly (109 records total, all currently admLevel 2: 85 arrondissement-boundary lines → 3, 66 Vatovavy/Fitovinany + Ambatosoa/Analanjirofo boundary lines → 1 — see the updated script below), bringing the tileset's effective counts to 24 regions / 114 districts, matching adiresy.mg and Wikipedia exactly.

**Commune-level discrepancy (1,579 vs 1,707) investigated, not pursued.** Issue #2 points at [D2015-592](https://cnlegis.gov.mg/uploads/D2015-592-Classement_COMMUNE_URBAINE_et_RURALE.pdf), the decree classifying every commune as urban or rural. Downloaded and checked directly (`pdftotext`/`pdfplumber`): it's genuine extractable text (Word → doPDF, not a scan), 371 pages, structured Province → Region → District → Commune (Hors catégorie / 1ère / 2ème catégorie, urban and rural annexes separately) → Fokontany, with real table borders `pdfplumber` can parse into cells (merged region/district cells need forward-fill logic across page breaks to associate correctly, but that's a solved problem, not a blocker).

The blocker is the data itself: the decree's own recap tables (last 2 pages) give **1,693 communes / 18,251 fokontany** nationally — a *third* number, matching neither HDX's 1,579 / 17,465 nor adiresy.mg's 1,707 / 17,465. It's an independent 2015-04-01 snapshot, not the missing link between the other two; closer to adiresy.mg's count than HDX's, but still off by 14 communes and ~800 fokontany. Unlike the region/district fix above, there's no verifiable rule here (no dated law closing an exact count gap, no shared pcode scheme to key off) — using this decree to relabel HDX's communes would mean fuzzy name-matching across three disagreeing sources, which risks introducing incorrect district/commune associations with no way to verify them (the boundaries overlay is lines-only, no name/label fields, so a bad match wouldn't even be visually catchable). Not attempted for that reason. Tracked as issue #2's remaining item — the actual fix requires adiresy.mg's own commune/fokontany crosswalk, which isn't public; asked for it in the issue.

**Bonus finding:** every level in this dataset carries an `OLD_PROVIN` field mapping it to one of the 6 legacy "faritany" provinces — and the values match our T5 province table exactly (verified via `ogrinfo`: e.g. Analamanga/Vakinankaratra/Itasy/Bongolava all map to `OLD_PROVIN=Antananarivo`, matching the plan's table). This means TG-8 (our province download-split bounding boxes are hand-eyeballed approximations) could be fixed by dissolving this dataset's ADM1 polygons by `OLD_PROVIN` and clipping Planetiler with the exact geometry (`--polygon=`) instead of a bbox — not implemented here, tracked as TG-16, since it would require re-running every previously-built base-map and buildings-overlay file.

**`scripts/build-boundaries.sh`:**

```bash
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
```

**Non-obvious bug hit and fixed during testing:** tippecanoe's per-feature zoom-override key (`"tippecanoe": {"minzoom": N, ...}`) only takes effect as a **top-level sibling of `"properties"`** on each GeoJSON Feature object — not nested inside `"properties"` itself. Nesting it inside `properties` silently does nothing (tippecanoe just serializes it through as a regular string-valued attribute); there's no warning or error, so this is easy to miss. Confirmed with a minimal 2-feature reproduction before fixing the real conversion. Without per-level minzoom at all, tippecanoe fails outright: cramming all 48,713 line segments (including 29,299 fokontany-level segments) into low-zoom tiles exceeds its 500KB internal tile-size limit and it refuses to produce those tiles ("could not make tile ... small enough").

**Non-obvious bug hit and fixed while building the admLevel correction (this repo, issue #2):** the first version of `corrected_adm_level` checked only "are both sides of this line inside the arrondissement pcode set" without also requiring `admLevel == 2`. That silently also matched fokontany-level (admLevel 4) lines that happen to sit *entirely inside* a single arrondissement — there, `ADM2_L` and `ADM2_R` are equal (both that arrondissement's pcode), and a set of one repeated pcode is trivially a subset of the 6-pcode arrondissement set too. First run reclassified 436 fokontany lines down to commune level by mistake alongside the intended 85 district lines. Caught by diffing before/after `admLevel` histograms against the hand-verified SQL counts (`ogrinfo -dialect sqlite`) before trusting the output — fixed by gating the whole function on `level != 2`.

**Zoom scheme used:** region (level 1) and the coastline/external layer (level 99) from z0; district (level 2) from z4; commune (level 3) from z7; fokontany (level 4) from z9. Tileset built z0–z12 (matches the Overview/Standard tier ceiling; MapLibre will overzoom these simple line tiles fine beyond z12 for the Detailed tier, same as any raster/vector source displayed past its native maxzoom).

**Built and verified locally:** 13.3 MB (`boundaries.pmtiles`, unchanged from before the admLevel fix — this only reclassifies existing lines, doesn't add/remove geometry), valid PMTiles v3, `pmtiles show` reports correct bounds/zoom range. Verified the correction itself by diffing admLevel histograms before/after against hand-written `ogrinfo -dialect sqlite` queries on the raw shapefile: exactly 85 lines move district→commune (Antananarivo-Renivohitra's internal arrondissement boundaries) and 66 move district→region (48 Vatovavy/Fitovinany + 18 Ambatosoa/Analanjirofo), admLevel 4 (29,299 fokontany lines) untouched. Full pipeline re-run end-to-end against the real BNGRC/OCHA zip, exits 0.

**`scripts/generate-province-polygons.sh` (resolves TG-16):** province splits for the base map (§4) and buildings overlay (§5) originally used hand-drawn bounding boxes (approximate — see TG-8). This dataset's ADM1 polygons carry an `OLD_PROVIN` attribute mapping exactly onto our 6 legacy-province split (verified via `ogrinfo`, see TG-16 below), so this script downloads the same BNGRC/OCHA zip, dissolves the ADM1 polygons by `OLD_PROVIN` (`ogr2ogr … -dialect sqlite -sql "SELECT OLD_PROVIN, ST_Union(geometry) … GROUP BY OLD_PROVIN"`), and writes one `province-<name>.poly` per province (Osmosis polygon filter format — see the §4 testing note on why not GeoJSON) plus a `province-bounds.json` of each polygon's bbox (still needed for `extract-buildings.sh`, since `pmtiles extract` has no polygon-clip option — only `--bbox=`). `scripts/build.sh` now accepts either a bbox string or a `.poly` path in its `bounds` argument, passing `--polygon=` to Planetiler for the latter (see §4).

**Verified locally, real bugs found and fixed:**
1. `-nlt PROMOTE_TO_MULTIPOLYGON` isn't a valid GDAL geometry-type name (`ERROR 1: -nlt PROMOTE_TO_MULTIPOLYGON: type not recognised`) — the correct flag is `-nlt PROMOTE_TO_MULTI`.
2. BNGRC/OCHA's `OLD_PROVIN` attribute spells the sixth province **"Toliary"**, not "Toliara" — the initial `names` mapping used the latter, which would have silently dropped that province's polygon (caught by the script's own `missing` check, which exits with an error rather than dropping silently — but still wrong until fixed).
3. Planetiler's `--polygon=` does not accept GeoJSON (see §4) — this script now emits `.poly` directly instead of `.geojson`.

All three fixed, then re-run end-to-end against the real BNGRC/OCHA zip: produced 6 valid `.poly` files and `province-bounds.json`; the `mahajanga` entry's computed bbox (`43.929388,-19.314842,49.478643,-13.873601`) exactly matched the bounds reported by `pmtiles show` on both the `--polygon=`-clipped base-map build and the `--bbox=`-clipped buildings extraction for that province (§4/§5 testing notes). Bboxes for all 6 provinces are in the same ballpark as the old hand-drawn ones (confirms the fix targets the right regions) but meaningfully different (confirms it's not just reproducing the approximation — see TG-16).

```bash
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
```

## 8. `scripts/generate-manifest.py`

Scans the current directory for build outputs and writes `manifest.json`. File naming convention: `madagascar-{tier}.pmtiles` / `buildings-madagascar-{tier}.pmtiles` for national, `province-{name}-{tier}.pmtiles` / `buildings-province-{name}-{tier}.pmtiles` for provinces, where `tier` is `z12`/`z13`/`z14`.

```python
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

# Quality tiers, see §3 for the size/detail tradeoff.
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

    # POI overlay: schools, hospitals, shops, etc. at min_zoom=12 (config/poi-overlay.yml),
    # bypassing OpenMapTiles' built-in poi layer, which gates most categories to z14.
    # Derived from the same Geofabrik extract as the base map, so no separate
    # dataset_date -- osm_extract_date already covers it.
    poi = {}
    poi_national = region_tiers(lambda t: f"poi-madagascar-{t}.pmtiles", base_url)
    if poi_national:
        poi["national"] = poi_national
    poi_provinces = provinces_tiers(lambda name, t: f"poi-province-{name}-{t}.pmtiles", base_url)
    if poi_provinces:
        poi["provinces"] = poi_provinces
    if poi:
        manifest["poi"] = poi

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
```

**Decision (resolves an ambiguity in the plan):** the plan's T5 example showed a `"provinces"` key but didn't say whether it nests under `"files"` or sits alongside it. This spec places it as a **top-level sibling of `"files"`**, matching the plan's prose ("manifest.json extended with a `provinces` key"). Formal schema below.

## 9. `manifest.json` schema

Each region (`national` and each province) maps to an object keyed by quality tier (`z12`/`z13`/`z14`) instead of directly to a single file entry. `buildings` and `poi` mirror `files`'s `national`/`provinces` shape exactly, as top-level siblings. `buildings` and `boundaries` additionally carry a `dataset_date` — the upstream snapshot date, distinct from `osm_extract_date` since neither refreshes on our quarterly cadence (resolves TG-12/TG-14). `poi` does **not** — it's derived from the same OSM extract as the base map every build, so `osm_extract_date` already covers it (see §6).

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["version", "generated", "osm_extract_date", "files"],
  "properties": {
    "version": { "type": "string", "pattern": "^[0-9]{4}-Q[1-4]$" },
    "generated": { "type": "string", "format": "date-time" },
    "osm_extract_date": { "type": "string", "format": "date" },
    "files": {
      "type": "object",
      "required": ["national"],
      "properties": {
        "national": { "$ref": "#/$defs/tierMap" }
      }
    },
    "provinces": { "$ref": "#/$defs/provincesMap" },
    "buildings": {
      "type": "object",
      "properties": {
        "national": { "$ref": "#/$defs/tierMap" },
        "provinces": { "$ref": "#/$defs/provincesMap" },
        "dataset_date": { "type": "string", "format": "date" }
      }
    },
    "poi": {
      "type": "object",
      "properties": {
        "national": { "$ref": "#/$defs/tierMap" },
        "provinces": { "$ref": "#/$defs/provincesMap" }
      }
    },
    "boundaries": { "$ref": "#/$defs/boundariesEntry" }
  },
  "$defs": {
    "provincesMap": {
      "type": "object",
      "additionalProperties": { "$ref": "#/$defs/tierMap" }
    },
    "tierMap": {
      "type": "object",
      "minProperties": 1,
      "propertyNames": { "enum": ["z12", "z13", "z14"] },
      "additionalProperties": { "$ref": "#/$defs/fileEntry" }
    },
    "fileEntry": {
      "type": "object",
      "required": ["filename", "url", "size_bytes", "sha256"],
      "properties": {
        "filename": { "type": "string" },
        "url": { "type": "string", "format": "uri" },
        "size_bytes": { "type": "integer", "minimum": 1 },
        "sha256": { "type": "string", "pattern": "^[a-f0-9]{64}$" }
      }
    },
    "boundariesEntry": {
      "allOf": [{ "$ref": "#/$defs/fileEntry" }],
      "type": "object",
      "required": ["dataset_date"],
      "properties": {
        "dataset_date": { "type": "string", "format": "date" }
      }
    }
  }
}
```

Example `files.national` and `buildings.national` (real values, from a local build/extract):

```json
"national": {
  "z12": { "filename": "madagascar-z12.pmtiles", "url": "…", "size_bytes": 43073104, "sha256": "…" },
  "z13": { "filename": "madagascar-z13.pmtiles", "url": "…", "size_bytes": 102044208, "sha256": "…" },
  "z14": { "filename": "madagascar-z14.pmtiles", "url": "…", "size_bytes": 301805319, "sha256": "…" }
}
```

```json
"buildings": {
  "national": {
    "z12": { "filename": "buildings-madagascar-z12.pmtiles", "url": "…", "size_bytes": 152968008, "sha256": "…" }
  },
  "provinces": {
    "mahajanga": {
      "z12": { "filename": "buildings-province-mahajanga-z12.pmtiles", "url": "…", "size_bytes": 19307887, "sha256": "…" }
    }
  },
  "dataset_date": "2024-08-27"
}
```

Example `poi` (real values, from a local build/extract — note no `dataset_date`, see above):

```json
"poi": {
  "national": {
    "z12": { "filename": "poi-madagascar-z12.pmtiles", "url": "…", "size_bytes": 654000, "sha256": "…" }
  },
  "provinces": {
    "mahajanga": {
      "z12": { "filename": "poi-province-mahajanga-z12.pmtiles", "url": "…", "size_bytes": 320000, "sha256": "…" }
    }
  }
}
```

Example `boundaries` (real value):

```json
"boundaries": { "filename": "boundaries.pmtiles", "url": "…", "size_bytes": 13278117, "sha256": "…", "dataset_date": "2018-10-31" }
```

The Android app (`TileDownloadWorker`) should validate against this shape defensively (missing `national`, malformed `sha256`) before starting a download — the manifest is fetched over the network and shouldn't be trusted blindly. This is a **breaking schema change** from the single-file-per-region shape in an earlier draft of this spec — flag to the `adiresy-mobile` team if any client code was already written against that shape. `buildings`, `poi`, and `boundaries` are all **additive** changes on top of that — a manifest consumer that doesn't yet know about them can safely ignore those keys.

## 10. `.github/workflows/build-tiles.yml`

Single job, sequential builds — 3 quality tiers × (1 national + 6 provinces) = 21 base-map builds, plus 21 matching buildings-overlay extractions and 21 matching POI-overlay builds (63 tile-producing steps total) — reusing Planetiler's Geofabrik download cache across all base-map and POI-overlay builds within the same job, so the country extract is only downloaded once per run regardless of region or tier count. The buildings extractions pull directly from VIDA's remote archive instead (see §5).

```yaml
name: Build and publish tiles

on:
  schedule:
    - cron: '0 2 1 1,4,7,10 *'   # Quarterly: 1 Jan, 1 Apr, 1 Jul, 1 Oct at 02:00 UTC
  workflow_dispatch:              # Manual rerun overwrites that quarter's release — see the release step below

permissions:
  contents: write   # needed to create the release and upload assets

jobs:
  build:
    runs-on: ubuntu-latest   # 7 GB RAM — sufficient for Planetiler + Madagascar extract

    steps:
      - uses: actions/checkout@v4

      - name: Set up JDK 21
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '21'

      - name: Install pmtiles CLI, GDAL, and tippecanoe
        run: |
          # go-pmtiles release assets embed the version in the filename
          # (e.g. go-pmtiles_1.31.0_Linux_x86_64.tar.gz), so latest/download/
          # with a static name 404s -- resolve the tag first.
          PMTILES_VERSION=$(curl -fsSL https://api.github.com/repos/protomaps/go-pmtiles/releases/latest | jq -r .tag_name)
          curl -fL -o /tmp/go-pmtiles.tar.gz \
            "https://github.com/protomaps/go-pmtiles/releases/download/${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION#v}_Linux_x86_64.tar.gz"
          tar -xzf /tmp/go-pmtiles.tar.gz -C /usr/local/bin pmtiles
          sudo apt-get update
          sudo apt-get install -y gdal-bin tippecanoe

      - name: Build national tiles (all quality tiers)
        run: |
          for zoom in 12 13 14; do
            bash scripts/build.sh madagascar "" "madagascar-z${zoom}.pmtiles" "$zoom"
          done

      - name: Generate province boundary polygons
        run: bash scripts/generate-province-polygons.sh

      - name: Build province tiles + buildings + POI overlays (all quality tiers)
        run: |
          for province in antananarivo fianarantsoa toamasina mahajanga toliara antsiranana; do
            bbox=$(jq -r ".${province}" province-bounds.json)
            for zoom in 12 13 14; do
              bash scripts/build.sh madagascar "province-${province}.poly" "province-${province}-z${zoom}.pmtiles" "$zoom"
              bash scripts/extract-buildings.sh "buildings-province-${province}-z${zoom}.pmtiles" "$bbox" "$zoom"
              bash scripts/build-poi-overlay.sh madagascar "province-${province}.poly" "poi-province-${province}-z${zoom}.pmtiles" "$zoom"
            done
          done

      - name: Extract national buildings overlay (all quality tiers)
        run: |
          for zoom in 12 13 14; do
            bash scripts/extract-buildings.sh "buildings-madagascar-z${zoom}.pmtiles" "" "$zoom"
          done

      - name: Build national POI overlay (all quality tiers)
        run: |
          for zoom in 12 13 14; do
            bash scripts/build-poi-overlay.sh madagascar "" "poi-madagascar-z${zoom}.pmtiles" "$zoom"
          done

      - name: Build admin boundaries overlay
        run: bash scripts/build-boundaries.sh boundaries.pmtiles

      - name: Compute release tag
        id: tag
        run: |
          Q=$(( ($(date -u +%-m) - 1) / 3 + 1 ))
          TAG="data-$(date -u +%Y)-Q${Q}"
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"

      - name: Determine OSM extract date
        id: extract_date
        run: |
          # Geofabrik publishes a replication state file per extract giving the
          # exact "as of" timestamp of the data, independent of when the job runs.
          STATE=$(curl -fsSL https://download.geofabrik.de/africa/madagascar-updates/state.txt)
          TIMESTAMP=$(echo "$STATE" | grep '^timestamp=' | cut -d= -f2 | sed 's/\\:/:/g')
          DATE=$(date -u -d "$TIMESTAMP" +%Y-%m-%d)
          echo "date=$DATE" >> "$GITHUB_OUTPUT"

      - name: Generate manifest.json
        run: |
          python3 scripts/generate-manifest.py \
            --tag "${{ steps.tag.outputs.tag }}" \
            --owner "${{ github.repository_owner }}" \
            --osm-extract-date "${{ steps.extract_date.outputs.date }}"

      - name: Create GitHub Release and upload assets
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          TAG="${{ steps.tag.outputs.tag }}"
          if gh release view "$TAG" >/dev/null 2>&1; then
            echo "Release $TAG already exists — replacing it (manual rerun in the same quarter)."
            gh release delete "$TAG" --yes --cleanup-tag
          fi
          gh release create "$TAG" \
            --title "Map data $TAG" \
            --notes "Quarterly OSM + Google Open Buildings + BNGRC/OCHA admin boundaries Madagascar tile update. Source: Geofabrik, VIDA, HDX. Licence: ODbL, CC BY-IGO." \
            madagascar-z*.pmtiles madagascar-z*.pmtiles.sha256 \
            province-*.pmtiles province-*.pmtiles.sha256 \
            buildings-*.pmtiles buildings-*.pmtiles.sha256 \
            poi-*.pmtiles poi-*.pmtiles.sha256 \
            boundaries.pmtiles boundaries.pmtiles.sha256 \
            manifest.json
```

The glob prefixes (`madagascar-z*`, `province-*`, `buildings-*`, `poi-*`, plus the standalone `boundaries.pmtiles`) are disjoint by construction — buildings files are named `buildings-madagascar-*`/`buildings-province-*` and POI files `poi-madagascar-*`/`poi-province-*`, so each only matches its own glob, never the others.

## 11. Testing & validation checklist

- **Local (base map):** `bash scripts/build.sh madagascar "" madagascar-z13.pmtiles 13` (etc. per tier) produces a `.pmtiles` file matching the sizes in §3; open it with `pmtiles show` (or load in a MapLibre viewer) to sanity-check zoom levels and coverage.
- **Local (buildings):** `bash scripts/extract-buildings.sh buildings-madagascar-z13.pmtiles "" 13` produces a `.pmtiles` file matching the sizes in §5; `pmtiles show` should report `type: overlay` and the VIDA `name`/`description` metadata.
- **Local (POI overlay):** `bash scripts/build-poi-overlay.sh madagascar "" poi-madagascar-z13.pmtiles 13` produces a `.pmtiles` file; `ogrinfo`/GDAL's PMTiles driver should show a `poi` layer with `class`/`subclass` populated (e.g. `class=amenity`, `subclass=school`) starting at z12, unlike the base map's own `poi` layer at the same tier — see §6 for the empirical counts that motivated this.
- **Local (boundaries):** `bash scripts/build-boundaries.sh boundaries.pmtiles` produces a 13 MB file; `pmtiles show` should report the BNGRC/OCHA name. Spot-check that each admin level only appears at/above its assigned minzoom (decode a low-zoom and a high-zoom tile, check the `admLevel` property distribution — see §7 for the exact zoom scheme).
- **Manifest:** run `generate-manifest.py` locally and validate the output against the JSON Schema in §9 (e.g. with `check-jsonschema`). Tested locally against real national + Mahajanga-province files for base map, buildings, POI overlay, and boundaries — all nest/attach correctly.
- **CI dry run:** trigger `workflow_dispatch` once manually before relying on the cron schedule, to confirm the release is created correctly, all 64 tile-file asset URLs resolve, and the `pmtiles`/`gdal-bin`/`tippecanoe` install step works on `ubuntu-latest`.
- **Checksum path:** manually corrupt a downloaded file locally and confirm `TileDownloadWorker` (T4, app-side) detects the mismatch and retries.

## 12. Milestone → artifact mapping

| Milestone | Delivered by |
|---|---|
| T0 | §1 layout, §2 `.gitignore`, README outline (not drafted here — content is prose, not spec) |
| T1 | §3, §4 |
| T2 | §8, §9 |
| T3 | §10 |
| T4 | App-side, out of scope for this repo — tracked in `adiresy-mobile` |
| T5 | §10 province loop, §8 `PROVINCES` list |
| Quality tiers (resolves TG-2) | §3 table, §4 `maxzoom` param, §8/§9 tier-keyed schema, §10 tier loops |
| Buildings overlay (adiresy.mg parity) | §5, §8/§9 `buildings` schema, §10 extraction steps |
| POI overlay (schools/hospitals/shops visible below z14) | §6, §8/§9 `poi` schema, §10 build steps |
| Admin boundaries overlay (adiresy.mg parity) | §7, §8/§9 `boundaries` schema, §10 build step |
| Region/district admLevel correction (resolves GH issue #2 items 1–2) | §7 discrepancy/root-cause/fix writeup, `scripts/build-boundaries.sh` |

---
