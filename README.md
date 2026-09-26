# Blue Ridge FloodWatch

Carolina Data Challenge 2026. This project looks at storm and flood events in North Carolina that caused deaths or heavy damage, with a focus on Western North Carolina after Hurricane Helene. It combines NOAA Storm Events with hydrography, terrain, infrastructure, and imperviousness data, an interview with two Asheville students who lived through Helene, and a machine-learning handoff for the Python modeling workflow.

## Render the report

From the project root:

```bash
quarto render src/analysis.qmd          # deliverable -> outs/report/analysis.html
quarto render src/analysis_quick.qmd    # ~2 min preview on a data subset -> outs/report/analysis_quick.html
```

`analysis.html` is fully self-contained, including the interview video, so you can share that single file. The first full render computes spatial features for about 11,600 events (a few minutes); later renders reuse the cache in `data/derived/`.

Change any setting without editing files:

```bash
quarto render src/analysis.qmd -P event_buffer_m:500 -P feature_event_scope:flood
```

## Layout

```text
README.md
src/                              code
  analysis.qmd                    full report: settings only (YAML params)
  analysis_quick.qmd              subset report: same code, subset settings
  _analysis_body.qmd              all report content and analysis code (edit here)
  _quarto.yml                     sends rendered HTML to outs/report/
  styles.css                      report styling
  content/interview_highlights.csv  curated interview quotes with timestamps
  R/
    utils.R                       paths, package checks, input validation, run log, geometry cleaning
    prepare_noaa.R                NOAA loading, one row per EVENT_ID, region assignment
    create_spatial_features.R     NHD / WBD / NCDOT / DEM / NLCD event features (+ cache)
    export_ml_tables.R            targets, split, column roles, feature dictionary, exports
    download_data.R               optional downloads (only when download_data: true)
  legacy/                         earlier notebooks and scripts (superseded, kept for reference)
data/
  raw/                            inputs, treated as read-only
    noaa/                         StormEvents_{details,fatalities,locations}-*.csv.gz
    nhd/                          NHD_H_North_Carolina_State_Shape.zip + extracted/
    ncdot/  dem_3dep/  nlcd/  usda_soils/
    reference/nc_counties.gpkg    county boundaries (maps only)
    media/Interview.mp4           original interview recording
  derived/                        pipeline caches (spatial features, web video, transcript)
  ml_ready/                       Python handoff files
outs/
  report/                         rendered HTML reports
  figures/                        every report figure as PNG
  tables/                         every report table as CSV
  legacy/                         outputs from the earlier notebooks
```

## Report structure

1. **Why Blue Ridge FloodWatch**: the problem, the interview (video, quotes, full transcript), our question and approach
2. **NOAA Storm Events**: the dataset, preprocessing (one row per event, region assignment), visualizations, and why more data is needed
3. **Supporting datasets**: NHD/WBD, terrain, NCDOT, NLCD, SSURGO, each with a summary card and a visualization
4. **Bringing the data together**: CRS and geometry cleaning, feature extraction, validation, assembly
5. **What the combined data shows**: target rates, feature comparisons, correlation, maps, interactive map
6. **Machine-learning-ready data**: targets, leakage rules, split, feature dictionary, exported files
7. **Model results**: placeholder for the Python model
8. **Appendix**: downloads (all figures, tables, and ML files), limitations, configuration, input inventory, pipeline log

Code is folded by default. Use the `</> Code` menu (top right) to expand all of it. Every table has Copy/CSV/Excel buttons, and every figure has a download link.

## Interview media

The original recording (`data/raw/media/Interview.mp4`, 369 MB) is never modified. The pipeline uses two derived files:

* `data/derived/media/interview_web.mp4`: a 720p web copy (about 34 MB) that is embedded in the report.
* `data/derived/media/interview_audio.*`: an automatic transcript (OpenAI Whisper `small`, run locally).

The quotes shown in the report are in `src/content/interview_highlights.csv`. Transcription errors are corrected in [brackets]; check them against the video before presenting. The interviewees gave consent; the report refers to them generically, and their names are replaced with [name] in the displayed transcript.

To regenerate the derived media:

```bash
ffmpeg -i data/raw/media/Interview.mp4 -vf scale=-2:720 -c:v libx264 -crf 30 -preset slow -c:a aac -b:a 96k -ac 1 -movflags +faststart data/derived/media/interview_web.mp4
```

```bash
whisper data/derived/media/interview_audio.wav --model small --language en --output_format all --output_dir data/derived/media
```

## Machine-learning handoff (`data/ml_ready/`)

| File | Contents |
|---|---|
| `nc_flood_event_model_table.parquet` | Flood-related events: the main modeling table |
| `nc_storm_event_model_table.parquet` | All events |
| `nc_storm_predictors_only.parquet`, `nc_storm_targets.parquet` | The same data split into X and y |
| `feature_dictionary.csv` | Role, units, source, and leakage note for every column |
| `target_definitions.csv`, `target_config.json` | Target rules, threshold, recompute formula |
| `split_recommendation.csv` | Events and positives per year and split |
| `nc_storm_event_features.gpkg` | Events as map points |
| `run_manifest.json` | Parameters, data vintages, and pipeline log for the run |

Rules: split by the `split` column; group CV folds by `episode_id`; recompute the damage threshold on training rows only; never use outcome columns as predictors; keep spatial NAs as missing.

## Data sources

| Dataset | Source |
|---|---|
| NOAA Storm Events | https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles/ |
| NHD High Resolution + WBD | https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/NHD/State/Shape/NHD_H_North_Carolina_State_Shape.zip |
| NCDOT structures / culverts | NCDOT_Structures ArcGIS MapServer (layers 0 and 2) |
| DEM, slope, roughness | `elevatr` AWS terrain tiles (zoom 10), reprojected to EPSG:32119 |
| Annual NLCD imperviousness (2023) | USGS Annual NLCD ImageServer |
| USDA SSURGO | Soil Data Access via `soilDB` (tabular) |
| County boundaries | U.S. Census cartographic boundary file 2023 via `tigris` |
