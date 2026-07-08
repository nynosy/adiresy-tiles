# adiresy-tiles

Off-device build pipeline that produces Madagascar `.pmtiles` (national and per-province, each in three quality tiers, plus a buildings overlay and an administrative boundaries overlay) and a `manifest.json`, published as GitHub Release assets on a quarterly schedule.

## Quality tiers

Each region (national and every province) is built at three zoom levels, so users can pick download size vs. map detail. Each tier also has a matching **buildings overlay** — a separate `.pmtiles` file with denser building footprint data (see below) — roughly tripling the download if included:

| Tier | Maxzoom | National base map | + buildings overlay |
|---|---|---|---|
| **Overview** | Z12 | 43 MB | +153 MB |
| **Standard** | Z13 | 102 MB | +327 MB |
| **Detailed** | Z14 | 302 MB | +694 MB |

(Sizes measured directly from a local build/extract of the national extent; province tiers are proportionally smaller — e.g. Antananarivo's Detailed tier is 71.5 MB base + 188 MB buildings, Mahajanga's is 21.9 MB + 82 MB.)

## Administrative boundaries overlay

A single small `boundaries.pmtiles` (**13.3 MB**, not split by region or tier — the whole country fits comfortably in one file) carries region/district/commune/fokontany boundary lines, matching what the live [adiresy.mg](https://adiresy.mg/) site renders. Sourced from BNGRC/OCHA's COD-AB dataset (see below), built with `tippecanoe` from the official Shapefile — there's no pre-tiled version like VIDA provides for buildings, so this repo does the conversion itself (`scripts/build-boundaries.sh`).

Consumed by the `adiresy-mobile` Android app via `TileDownloadWorker`, which downloads the national or per-province bundle and quality tier the user picks and verifies it against the manifest's SHA-256 before use.

This repository contains no application code — only pipeline configuration and scripts. See `docs/TileGen-Implementation-Spec.md` for the concrete implementation spec these files are built from.

## Data sources & licences

- **Map data:** OpenStreetMap contributors, via [Geofabrik](https://download.geofabrik.de/)'s Madagascar extract. Licensed under the [Open Database License (ODbL)](https://opendatacommons.org/licenses/odbl/). The OSM `building` layer is deliberately excluded from these base tiles (see below).
- **Vector tile schema:** [OpenMapTiles](https://github.com/openmaptiles/openmaptiles), licensed CC-BY. **Required credit** (from Planetiler's own build output, not optional): the app must display, somewhere the user sees it —
  > © OpenMapTiles © OpenStreetMap contributors
- **Buildings overlay:** [Google Open Buildings v3](https://sites.research.google/gr/open-buildings/), Microsoft [GlobalMLBuildingFootprints](https://github.com/microsoft/GlobalMLBuildingFootprints), and OSM — merged and deduplicated (Google, then Microsoft, then OSM, in priority order) by [VIDA](https://source.coop/vida/google-microsoft-osm-open-buildings), licensed ODbL. This is why our base tiles above exclude the OSM `building` layer: it would otherwise duplicate footprints already covered by this overlay, which is far denser (OSM building tagging in Madagascar is sparse; this dataset adds ML-detected buildings from satellite imagery). Matches the building data source used by the live [adiresy.mg](https://adiresy.mg/) site.
- **Administrative boundaries overlay:** Madagascar National Disaster Management Office (BNGRC), via OCHA Field Information Services Section (FISS)'s HDX [COD-AB Madagascar dataset](https://data.humdata.org/dataset/cod-ab-mdg) ("Madagascar - Subnational Administrative Boundaries"), licensed **CC BY-IGO 3.0** (not ODbL — a different license from everything else in this repo). **Required credit** (per the license's §4(b) attribution terms — source org, work title, and license URI, confirmed via HDX's CKAN API since the HTML page blocks non-browser fetches):
  > Administrative boundaries: Madagascar National Disaster Management Office (BNGRC), via OCHA Field Information Services Section — "Madagascar - Subnational Administrative Boundaries," Creative Commons Attribution for Intergovernmental Organisations (CC BY-IGO 3.0) — http://creativecommons.org/licenses/by/3.0/igo/

  Covers region (ADM1), district (ADM2), commune (ADM3), and fokontany (ADM4) boundary lines. Matches the boundary data source used by adiresy.mg, though note: HDX's indexed file reports 22 regions/119 districts/1,579 communes/17,465 fokontany, while the live site states 24/114/1,707/17,465 — same fokontany count, different region/district/commune counts. Unresolved; the site may be using a newer BNGRC release not yet indexed on HDX.

## Repository structure

```
adiresy-tiles/
├─ .github/workflows/build-tiles.yml   # Scheduled + manual CI build/publish
├─ config/planetiler-mg.yml            # Documents the Planetiler flags used (not read by any tool)
├─ scripts/build.sh                    # Local dev build wrapper (base map tiles), also used by CI
├─ scripts/extract-buildings.sh        # Extracts the buildings overlay from VIDA's remote PMTiles
├─ scripts/build-boundaries.sh         # Downloads + tiles the BNGRC/OCHA admin boundaries overlay
├─ scripts/generate-manifest.py        # Produces manifest.json from build outputs
└─ docs/                               # Implementation spec
```

## Running locally

Requires JDK 21, roughly 4 GB of free memory, the [`pmtiles` CLI](https://github.com/protomaps/go-pmtiles) (`brew install pmtiles` on macOS) for the buildings overlay, and `gdal` + `tippecanoe` (`brew install gdal tippecanoe`) for the admin boundaries overlay.

```bash
# National tiles, one call per quality tier
bash scripts/build.sh madagascar "" madagascar-z12.pmtiles 12
bash scripts/build.sh madagascar "" madagascar-z13.pmtiles 13
bash scripts/build.sh madagascar "" madagascar-z14.pmtiles 14

# A single province + tier (bounds from the implementation spec's province table)
bash scripts/build.sh madagascar "44.8,-20.4,48.0,-17.3" province-antananarivo-z13.pmtiles 13

# Buildings overlay, national and a single province, one call per tier
bash scripts/extract-buildings.sh buildings-madagascar-z13.pmtiles "" 13
bash scripts/extract-buildings.sh buildings-province-antananarivo-z13.pmtiles "44.8,-20.4,48.0,-17.3" 13

# Admin boundaries overlay -- single file, no tiers/provinces
bash scripts/build-boundaries.sh boundaries.pmtiles

# Manifest (after building whichever region/tier files you want to include)
python3 scripts/generate-manifest.py \
  --tag data-2026-Q3 \
  --owner OWNER \
  --osm-extract-date 2026-06-28
```

The first `build.sh` run downloads `planetiler.jar` and the Geofabrik Madagascar extract into the working directory; subsequent runs in the same directory reuse both, so building all three tiers only pays the download cost once. `extract-buildings.sh` pulls directly from VIDA's remote archive via HTTP range requests — no full-archive download needed, but each region/tier extraction does transfer its own share (see the size table above). `build-boundaries.sh` downloads the ~63 MB BNGRC/OCHA shapefile fresh each run (it's small and the source is effectively static, so this isn't worth caching).

> **macOS note:** the workflow's province-loop step (`.github/workflows/build-tiles.yml`) uses a bash associative array, which needs bash 4+. macOS ships bash 3.2 as `/bin/bash`/`bash` (a licensing artifact, not a bug) — if you want to run that exact loop locally rather than calling `build.sh` directly per province as shown above, install a newer bash (`brew install bash`) and invoke the script with it explicitly. GitHub Actions' `ubuntu-latest` runners are unaffected.

## Release process

Releases are built and published automatically by `.github/workflows/build-tiles.yml` on a quarterly schedule (1 Jan/Apr/Jul/Oct), or on demand via the workflow's manual trigger. Each release is tagged `data-{YYYY}-Q{N}` and contains the national and six province `.pmtiles` files in all three quality tiers, a matching buildings overlay `.pmtiles` for each of those 21 region/tier combinations (42 tile files total), a single `boundaries.pmtiles`, their `.sha256` checksums, and `manifest.json`. The app always fetches the manifest from the release's `/releases/latest/download/` URL, so it never needs a hardcoded tag.
