# Carolina HighGround

Carolina Data Challenge 2026. This project looks at storm and flood events in North Carolina that caused deaths or heavy damage, with a focus on Western North Carolina after Hurricane Helene. It combines NOAA Storm Events with hydrography, terrain, infrastructure, and imperviousness data, an interview with two Asheville students who lived through Helene, and a machine-learning handoff for the Python modeling workflow.

## Render the reports

From the project root:

```bash
quarto render src/final_analysis_deliverable.qmd   # FINAL deliverable (R + Python) -> outs/report/final_analysis_deliverable.html
quarto render src/analysis.qmd                     # data-pipeline report (R only)   -> outs/report/analysis.html
quarto render src/analysis_quick.qmd               # ~2 min preview on a data subset -> outs/report/analysis_quick.html
```

The HTML reports are fully self-contained (interview video and, in the final report, the interactive explorer are embedded), so each is a single shareable file. The first full render computes spatial features for about 11,600 events (a few minutes); later renders reuse the cache in `data/derived/`.

Change any setting without editing files:

```bash
quarto render src/final_analysis_deliverable.qmd -P cv_repeats:10 -P relief_radius_m:3000
```

### Python setup (final report only)

The modeling section runs Python inside the Quarto document through the R package `reticulate`, using a dedicated conda environment:

```bash
conda create -n highground -c conda-forge --override-channels python=3.12 pandas numpy scikit-learn matplotlib shap pyarrow
```

The report selects it with the `python_env: "highground"` parameter. R's spatial packages and scikit-learn each load their own OpenMP runtime, and two runtimes in one process crash gradient boosting. The modeling section therefore sets `OMP_NUM_THREADS=1` and `KMP_DUPLICATE_LIB_OK=TRUE` before Python starts.

## Layout

```text
README.md
src/                              code
  final_analysis_deliverable.qmd  FINAL report: settings only (YAML params); R + Python
  analysis.qmd                    data-pipeline report: settings only; R only
  analysis_quick.qmd              subset preview: same code, subset settings
  _analysis_body.qmd              sections 1-6 (story, NOAA, datasets, integration, figures, ML data): edit here
  _modeling.qmd                   section 7 for the final report: R -> Python modeling via reticulate
  _model_placeholder.qmd          section 7 placeholder used by analysis.qmd
  _appendix.qmd                   appendix used by all reports
  _quarto.yml                     sends rendered HTML to outs/report/
  styles.css                      report styling
  content/interview_highlights.csv  curated interview quotes with timestamps
  content/highground_explorer.html  interactive risk explorer (built by Minh), embedded in the final report
  R/
    utils.R                       paths, package checks, input validation, run log, geometry cleaning
    prepare_noaa.R                NOAA loading, one row per EVENT_ID, region assignment
    create_spatial_features.R     NHD / WBD / NCDOT / DEM / NLCD event features (+ cache)
    export_ml_tables.R            targets, split, column roles, feature dictionary, exports
    download_data.R               optional downloads (only when download_data: true)
  legacy/                         earlier notebooks and scripts (superseded, kept for reference)
    minh/                         Minh's original model scripts and slide outline
data/
  raw/                            inputs, treated as read-only
    noaa/                         StormEvents_{details,fatalities,locations}-*.csv.gz
    nhd/                          NHD_H_North_Carolina_State_Shape.zip + extracted/
    ncdot/  dem_3dep/  nlcd/  usda_soils/
    reference/nc_counties.gpkg    county boundaries (maps only)
    nri/NRI_Table_Counties.csv    FEMA National Risk Index v1.20 (SOVI, population), used by the models
    media/Interview.mp4           original interview recording
  derived/                        pipeline caches (spatial features, web video, transcript)
  ml_ready/                       Python handoff files
outs/
  report/                         rendered HTML reports
  presentation/                   project brief for planning the presentation
  figures/                        every report figure as PNG
  tables/                         every report table as CSV
  legacy/                         outputs from the earlier notebooks (minh/: Minh's original model figures)
```

## Report structure (final report)

1. **Why Carolina HighGround**: the problem, the interview (video, quotes, full transcript), our question and approach
2. **NOAA Storm Events**: the dataset, preprocessing (one row per event, region assignment), visualizations, and why more data is needed
3. **Supporting datasets**: NHD/WBD, terrain, NCDOT, NLCD, SSURGO, each with a summary card and a visualization
4. **Bringing the data together**: CRS and geometry cleaning, feature extraction, validation, assembly
5. **What the combined data shows**: target rates, feature comparisons, correlation, maps, interactive map
6. **Machine-learning-ready data**: targets, leakage rules, split, feature dictionary, exported files
7. **Modeling and results** (R -> Python): 5 km relief (R), FEMA NRI join and flood history (Python), 3 models with repeated grouped CV, holdout test, calibration, SHAP, lessons from development, and the embedded interactive explorer (`analysis.qmd` shows a placeholder here)
8. **Appendix**: downloads (tables and ML files), limitations, configuration, input inventory, pipeline log

Code is folded by default. Use the `</> Code` menu (top right) to expand all of it. Every table has Copy/CSV/Excel buttons, and every figure has a download link.

## Safeguards

* Raw files in `data/raw/` are never modified.
* The ML export is **skipped** (and the report shows a red warning) if an enabled feature group comes out entirely missing, which usually means input paths are wrong. This prevents overwriting good files in `data/ml_ready/` with degraded ones. Override with `allow_degraded_export: true`.
* The target uses a leakage-safe threshold computed from training years only (`target_threshold_basis: "train_split"`, currently $200,000).

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

Rules: split by the `split` column; group CV folds by `episode_id`; the exported `high_consequence` already uses the training-years-only threshold ($200,000); never use outcome columns as predictors; keep spatial NAs as missing.

## AI assistance

We used **Claude** (Anthropic's AI assistant, via claude.ai) and **Claude Code** to help write the code in this repository: the R data pipeline (`src/R/`), the Quarto reports (`src/*.qmd`), the Python modeling code, and the interactive risk explorer. The team directed the analysis, chose the data sources and methods, and reviewed the code and results. All data comes from the public sources listed below, and every number in the reports is computed from that data by the code in this repository.

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
| FEMA National Risk Index (county table v1.20, Dec 2025) | https://www.fema.gov/about/reports-and-data/openfema/nri/v120/NRI_Table_Counties.zip |
