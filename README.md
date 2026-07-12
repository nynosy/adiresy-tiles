# adiresy-tiles

Off-device build pipeline that produces Madagascar `.pmtiles` (national and per-province, each in three quality tiers, plus a buildings overlay, a POI overlay, and an administrative boundaries overlay) and a `manifest.json`, published as GitHub Release assets on a quarterly schedule.

## Quality tiers

Each region (national and every province) is built at three zoom levels, so users can pick download size vs. map detail. Each tier also has a matching **buildings overlay** — a separate `.pmtiles` file with denser building footprint data (see below) — roughly tripling the download if included, and a **POI overlay** (schools, hospitals, shops, etc. — see below) that adds only a few hundred KB to MB:

| Tier | Maxzoom | National base map | + buildings overlay | + POI overlay |
|---|---|---|---|---|
| **Overview** | Z12 | 43 MB | +153 MB | +0.6 MB |
| **Standard** | Z13 | 102 MB | +327 MB | +2.0 MB |
| **Detailed** | Z14 | 302 MB | +694 MB | +3.0 MB |

(Sizes measured directly from a local build/extract of the national extent; province tiers are proportionally smaller — e.g. Antananarivo's Detailed tier is 71.5 MB base + 188 MB buildings, Mahajanga's is 21.9 MB + 82 MB.)

## POI overlay

OpenMapTiles' built-in `poi` layer (used by the base map) gates most POI categories — schools, hospitals, pharmacies, shops, offices — to zoom 14, leaving the Overview and Standard tiers with almost no points of interest (confirmed directly: a small test area had 9,152 POI features at Z14 but only 14 at Z13, none of them schools or hospitals). Since Planetiler has no supported way to override that built-in schema's zoom thresholds short of forking `openmaptiles/planetiler-openmaptiles`, this repo instead builds a small separate overlay (`config/poi-overlay.yml`, a custom Planetiler schema; `scripts/build-poi-overlay.sh`) covering the same real-world categories at a fixed `min_zoom: 12`, so they're visible starting at the Overview tier.

## Administrative boundaries overlay

A single small `boundaries.pmtiles` (**13.3 MB**, not split by region or tier — the whole country fits comfortably in one file) carries region/district/commune/fokontany boundary lines, matching what the live [adiresy.mg](https://adiresy.mg/) site renders. Sourced from BNGRC/OCHA's COD-AB dataset (see below), built with `tippecanoe` from the official Shapefile — there's no pre-tiled version like VIDA provides for buildings, so this repo does the conversion itself (`scripts/build-boundaries.sh`).

Consumed by the `adiresy-mobile` Android app via `TileDownloadWorker`, which downloads the national or per-province bundle and quality tier the user picks and verifies it against the manifest's SHA-256 before use.

This repository contains no application code — only pipeline configuration and scripts. See `docs/TileGen-Implementation-Spec.md` for the concrete implementation spec these files are built from.

## License

This repo's **code** (scripts, configs, CI workflow) is licensed under **GPL-3.0** — see [`LICENSE`](LICENSE), matching the companion [`adiresy-mobile`](https://github.com/nynosy/adiresy-mobile) app.

The **released data** (`.pmtiles`/`manifest.json` GitHub Release assets) is *not* covered by that license — it's bound by its upstream sources' own licenses instead (ODbL, CC-BY, CC BY-IGO 3.0, depending on the file). See [`LICENSE-DATA.md`](LICENSE-DATA.md) for exactly what applies to which file and what it permits/requires; the section below covers the same sources with more build-process context.

## Data sources & licences

- **Map data:** OpenStreetMap contributors, via [Geofabrik](https://download.geofabrik.de/)'s Madagascar extract. Licensed under the [Open Database License (ODbL)](https://opendatacommons.org/licenses/odbl/). The OSM `building` layer is deliberately excluded from these base tiles (see below).
- **Vector tile schema:** [OpenMapTiles](https://github.com/openmaptiles/openmaptiles), licensed CC-BY. **Required credit** (from Planetiler's own build output, not optional): the app must display, somewhere the user sees it —
  > © OpenMapTiles © OpenStreetMap contributors
- **Buildings overlay:** [Google Open Buildings v3](https://sites.research.google/gr/open-buildings/), Microsoft [GlobalMLBuildingFootprints](https://github.com/microsoft/GlobalMLBuildingFootprints), and OSM — merged and deduplicated (Google, then Microsoft, then OSM, in priority order) by [VIDA](https://source.coop/vida/google-microsoft-osm-open-buildings), licensed ODbL. This is why our base tiles above exclude the OSM `building` layer: it would otherwise duplicate footprints already covered by this overlay, which is far denser (OSM building tagging in Madagascar is sparse; this dataset adds ML-detected buildings from satellite imagery). Matches the building data source used by the live [adiresy.mg](https://adiresy.mg/) site.
- **POI overlay:** same OpenStreetMap contributors / Geofabrik source and ODbL license as the base map above — no separate attribution needed. Built with a custom Planetiler schema (`config/poi-overlay.yml`) rather than OpenMapTiles' bundled profile, purely to change *which zoom levels* the same underlying OSM data appears at (see "POI overlay" above).
- **Administrative boundaries overlay:** Madagascar National Disaster Management Office (BNGRC), via OCHA Field Information Services Section (FISS)'s HDX [COD-AB Madagascar dataset](https://data.humdata.org/dataset/cod-ab-mdg) ("Madagascar - Subnational Administrative Boundaries"), licensed **CC BY-IGO 3.0** (not ODbL — a different license from everything else in this repo). **Required credit** (per the license's §4(b) attribution terms — source org, work title, and license URI, confirmed via HDX's CKAN API since the HTML page blocks non-browser fetches):
  > Administrative boundaries: Madagascar National Disaster Management Office (BNGRC), via OCHA Field Information Services Section — "Madagascar - Subnational Administrative Boundaries," Creative Commons Attribution for Intergovernmental Organisations (CC BY-IGO 3.0) — http://creativecommons.org/licenses/by/3.0/igo/

  Covers region (ADM1), district (ADM2), commune (ADM3), and fokontany (ADM4) boundary lines. Matches the boundary data source used by adiresy.mg, though note: HDX's indexed file reports 22 regions/119 districts/1,579 communes/17,465 fokontany, while the live site states 24/114/1,707/17,465 — same fokontany count, different region/district/commune counts. Root cause (per [issue #2](https://github.com/nynosy/adiresy-tiles/issues/2)): the HDX shapefile (2018-10-31) is frozen at Madagascar's 2004 admin split and never picked up two later legal changes — [Vatovavy-Fitovinany region split into Vatovavy and Fitovinany](https://www.assemblee-nationale.mg/wp-content/uploads/2021/07/LOI-n%C2%B02021-012-CTD.pdf) (2021) and Ambatosoa region carved out of northern Analanjirofo (law 2023, inaugurated 2025) — plus the shapefile's own data quirk of coding Antananarivo-Renivohitra's 6 arrondissements as separate ADM2 "districts" nested inside a district. No geometry is wrong, only classification: `scripts/build-boundaries.sh` now reclassifies the affected boundary lines' `admLevel` (region ↔ district ↔ commune) to match, bringing the tileset's effective region/district counts to 24/114. Commune-level drift (1,579 vs 1,707) is unresolved and, unlike region/district, not mechanically fixable from public sources: the decree cited in issue #2 ([D2015-592](https://cnlegis.gov.mg/uploads/D2015-592-Classement_COMMUNE_URBAINE_et_RURALE.pdf), text-extractable, not scanned) has its own recap tables giving 1,693 communes / 18,251 fokontany nationally — a *third* number, matching neither HDX (1,579 / 17,465) nor adiresy.mg (1,707 / 17,465). It's an independent 2015 snapshot, not the missing link between the other two. Reconciling it would mean guessing at name-matches between three disagreeing sources rather than applying a verifiable rule, so it hasn't been attempted — see issue #2 for the request to adiresy.mg for their actual commune/fokontany crosswalk.

## Repository structure

```
adiresy-tiles/
├─ .github/workflows/build-tiles.yml   # Scheduled + manual CI build/publish
├─ config/planetiler-mg.yml            # Documents the Planetiler flags used (not read by any tool)
├─ config/poi-overlay.yml              # Custom Planetiler schema for the low-zoom POI overlay
├─ scripts/build.sh                    # Local dev build wrapper (base map tiles), also used by CI
├─ scripts/extract-buildings.sh        # Extracts the buildings overlay from VIDA's remote PMTiles
├─ scripts/build-poi-overlay.sh        # Builds the low-zoom POI overlay (config/poi-overlay.yml)
├─ scripts/build-boundaries.sh         # Downloads + tiles the BNGRC/OCHA admin boundaries overlay
├─ scripts/generate-province-polygons.sh  # Exact province-split geometry (BNGRC/OCHA ADM1)
├─ scripts/generate-manifest.py        # Produces manifest.json from build outputs
└─ docs/                               # Implementation spec
```

## Running locally

Requires JDK 21, roughly 4 GB of free memory, the [`pmtiles` CLI](https://github.com/protomaps/go-pmtiles) (`brew install pmtiles` on macOS) for the buildings overlay, and `gdal` + `tippecanoe` (`brew install gdal tippecanoe`) for the admin boundaries and province-geometry steps.

```bash
# National tiles, one call per quality tier
bash scripts/build.sh madagascar "" madagascar-z12.pmtiles 12
bash scripts/build.sh madagascar "" madagascar-z13.pmtiles 13
bash scripts/build.sh madagascar "" madagascar-z14.pmtiles 14

# Exact province geometry (.poly files + bboxes), needed for the province examples below
bash scripts/generate-province-polygons.sh

# A single province + tier, clipped to its exact BNGRC/OCHA boundary
bash scripts/build.sh madagascar province-antananarivo.poly province-antananarivo-z13.pmtiles 13

# Buildings overlay, national and a single province, one call per tier
bash scripts/extract-buildings.sh buildings-madagascar-z13.pmtiles "" 13
bash scripts/extract-buildings.sh buildings-province-antananarivo-z13.pmtiles "$(jq -r .antananarivo province-bounds.json)" 13

# POI overlay, national and a single province, one call per tier -- fixed min_zoom=12,
# visible starting at the Overview tier (see "POI overlay" above)
bash scripts/build-poi-overlay.sh madagascar "" poi-madagascar-z13.pmtiles 13
bash scripts/build-poi-overlay.sh madagascar province-antananarivo.poly poi-province-antananarivo-z13.pmtiles 13

# Admin boundaries overlay -- single file, no tiers/provinces
bash scripts/build-boundaries.sh boundaries.pmtiles

# Manifest (after building whichever region/tier files you want to include)
python3 scripts/generate-manifest.py \
  --tag data-2026-Q3 \
  --owner OWNER \
  --osm-extract-date 2026-06-28
```

The first `build.sh` run downloads `planetiler.jar` and the Geofabrik Madagascar extract into the working directory; subsequent runs in the same directory reuse both, so building all three tiers only pays the download cost once. `build-poi-overlay.sh` reuses the same `planetiler.jar`, just via a different entry point (a custom schema, not the default OpenMapTiles profile), so it doesn't re-download anything either. `extract-buildings.sh` pulls directly from VIDA's remote archive via HTTP range requests — no full-archive download needed, but each region/tier extraction does transfer its own share (see the size table above). `build-boundaries.sh` and `generate-province-polygons.sh` both download the ~63 MB BNGRC/OCHA shapefile fresh each run (it's small and the source is effectively static, so this isn't worth caching).

> **macOS note:** the workflow's province-loop step (`.github/workflows/build-tiles.yml`) uses a bash associative array, which needs bash 4+. macOS ships bash 3.2 as `/bin/bash`/`bash` (a licensing artifact, not a bug) — if you want to run that exact loop locally rather than calling `build.sh` directly per province as shown above, install a newer bash (`brew install bash`) and invoke the script with it explicitly. GitHub Actions' `ubuntu-latest` runners are unaffected.

## Release process

Releases are built and published automatically by `.github/workflows/build-tiles.yml` on a quarterly schedule (1 Jan/Apr/Jul/Oct), or on demand via the workflow's manual trigger. Each release is tagged `data-{YYYY}-Q{N}` and contains the national and six province `.pmtiles` files in all three quality tiers, a matching buildings overlay and POI overlay `.pmtiles` for each of those 21 region/tier combinations (63 tile files total), a single `boundaries.pmtiles`, their `.sha256` checksums, and `manifest.json`. The app always fetches the manifest from the release's `/releases/latest/download/` URL, so it never needs a hardcoded tag.
