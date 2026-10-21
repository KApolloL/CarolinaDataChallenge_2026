# Graph Report - CarolinaDataChallenge_2026  (2026-10-21)

## Corpus Check
- 25 files · ~168,859 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 59 file(s) not represented in the graph (top: .csv 45, .parquet 8, (none) 2)

## Summary
- 260 nodes · 470 edges · 12 communities (10 shown, 2 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 31 edges (avg confidence: 0.83)
- Token cost: 268,184 input · 0 output

## Community Hubs (Navigation)
- ML Modeling and Evaluation
- Report Body and Data Sources
- Findings and Leakage Rules
- README and Project Brief
- Spatial Feature Engine
- Explorer Export
- Optional Data Downloads
- NOAA Event Table
- Targets and ML Export
- Explorer and Model Findings
- Hydrology Rasters
- Explorer Grid

## God Nodes (most connected - your core abstractions)
1. `Analysis Body (shared Quarto child)` - 57 edges
2. `_modeling.qmd (Modeling and Results section)` - 26 edges
3. `run_all()` - 17 edges
4. `Spatial features measured around each event` - 15 edges
5. `build_spatial_features()` - 14 edges
6. `main()` - 13 edges
7. `Machine-learning handoff files (data/ml_ready)` - 12 edges
8. `fit_holdout()` - 10 edges
9. `try_download()` - 9 edges
10. `download_all_missing()` - 9 edges

## Surprising Connections (you probably didn't know these)
- `high_consequence target and chronological split` --semantically_similar_to--> `Leakage-safe high_consequence target (train-years threshold $200,000)`  [INFERRED] [semantically similar]
  outs/presentation/carolina_highground_project_brief.md → README.md
- `FEMA National Risk Index v1.20` --semantically_similar_to--> `FEMA National Risk Index county table (SOVI, population density)`  [INFERRED] [semantically similar]
  README.md → src/_modeling.qmd
- `Asheville High School student interview themes` --semantically_similar_to--> `Asheville student interview and Whisper transcript`  [INFERRED] [semantically similar]
  outs/presentation/carolina_highground_project_brief.md → README.md
- `Helene dominates holdout (66% of positives)` --semantically_similar_to--> `Helene sensitivity check (holdout with and without Helene week)`  [INFERRED] [semantically similar]
  outs/presentation/carolina_highground_project_brief.md → src/_modeling.qmd
- `In-bag calibration bug` --semantically_similar_to--> `Helene dominates holdout (66% of positives)`  [INFERRED] [semantically similar]
  src/_modeling.qmd → outs/presentation/carolina_highground_project_brief.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Targets, split, leakage rules and export for ML handoff** — src__analysis_body_targets, src__analysis_body_chronological_split, src__analysis_body_leakage_rules, src__analysis_body_feature_dictionary, src__analysis_body_ml_ready_export [EXTRACTED 0.85]
- **Datasets combined into per-event spatial features** — src__analysis_body_usgs_nhd, src__analysis_body_terrain_3dep, src__analysis_body_ncdot_crossings, src__analysis_body_nlcd_imperviousness, src__analysis_body_gridmet_rainfall, src__analysis_body_hydrology_hand, src__analysis_body_cdc_svi, src__analysis_body_spatial_features [EXTRACTED 0.95]
- **Supporting datasets feeding the ML feature table** — readme_noaa_storm_events, readme_nhd_wbd, readme_dem_terrain, readme_nlcd_impervious, readme_fema_nri, readme_gridmet_precipitation, readme_cdc_svi, readme_hand_hydrology, readme_ncdot_structures [EXTRACTED 1.00]
- **Three renderings of the same report body** — src_final_analysis_deliverable, src_analysis, src_analysis_quick [EXTRACTED 1.00]
- **Leakage-safe modeling validation pipeline** — readme_leakage_safe_target, src__modeling_grouped_cross_validation, src__modeling_platt_calibration, src__modeling_holdout_test, src__modeling_helene_sensitivity [INFERRED 0.85]

## Communities (12 total, 2 thin omitted)

### Community 0 - "ML Modeling and Evaluation"
Cohesion: 0.06
Nodes (33): _modeling.qmd (Modeling and Results section), compute_claims(), best_model(), build_model_frame(), calibrate(), calibration_check(), capture_metrics(), compare_models() (+25 more)

### Community 1 - "Report Body and Data Sources"
Cohesion: 0.07
Nodes (53): Analysis Body (shared Quarto child), CDC/ATSDR Social Vulnerability Index (tract), Chronological train/validation/test split, Common CRS and geometry cleaning (st_zm, st_make_valid, st_transform), Event-level table (one row per EVENT_ID), Feature dictionary, gridMET daily precipitation, Hurricane Helene Western NC case (+45 more)

### Community 2 - "Findings and Leakage Rules"
Cohesion: 0.07
Nodes (24): Helene dominates holdout (66% of positives), high_consequence target and chronological split, Project limitations (reporting record, modest skill, explanatory), Finding: rainfall explains more than terrain or vulnerability, Region assignment for county and forecast-zone records, CDC/ATSDR SVI tract data, DEM terrain (elevatr, EPSG:32119), FEMA National Risk Index v1.20 (+16 more)

### Community 3 - "README and Project Brief"
Cohesion: 0.15
Nodes (17): Carolina HighGround project brief for presentation, Hurricane Helene impact in 11 WNC counties (75 deaths, $1.7B), Asheville High School student interview themes, Suggested presentation arc, Research question: which storm events become high-consequence, README.md (Carolina HighGround), AI assistance disclosure (Claude, Claude Code), Carolina HighGround project (+9 more)

### Community 4 - "Spatial Feature Engine"
Cohesion: 0.19
Nodes (14): build_spatial_features(), cached_spatial_features(), count_within_m(), describe_vector_layer(), extract_raster_features(), feature_column_names(), load_nhd_flowlines(), load_point_layer() (+6 more)

### Community 5 - "Explorer Export"
Cohesion: 0.23
Nodes (11): build_grid(), build_points(), edit_prose(), find_const(), fit_logistic(), fmt_pct(), main(), model_prob() (+3 more)

### Community 6 - "Optional Data Downloads"
Cohesion: 0.32
Nodes (15): download_all_missing(), download_arcgis_layer(), download_dem_terrain(), download_nc_counties(), download_ncdot(), download_nhd_state(), download_nlcd_impervious(), download_noaa_storm_events() (+7 more)

### Community 7 - "NOAA Event Table"
Cohesion: 0.24
Nodes (10): assign_nc_region(), assign_one(), build_event_level(), duplication_check(), list_noaa_files(), load_noaa_tables(), nc_county_lookup(), parse_noaa_damage() (+2 more)

### Community 8 - "Targets and ML Export"
Cohesion: 0.22
Nodes (6): add_targets(), assign_split(), build_feature_dictionary(), column_roles(), export_ml_tables(), write_outputs()

### Community 9 - "Explorer and Model Findings"
Cohesion: 0.33
Nodes (5): Interactive risk explorer (HighGround), Mountain season inversion, SHAP feature drivers (random forest), Logistic regression, random forest, histogram gradient boosting, is_tropical_event constant flag (dead feature)

## Knowledge Gaps
- **19 isolated node(s):** `USGS NHD High Resolution and WBD hydrography`, `NCDOT structures and culverts`, `Annual NLCD imperviousness`, `USDA SSURGO soils`, `CDC/ATSDR SVI tract data` (+14 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 82 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `_modeling.qmd (Modeling and Results section)` connect `ML Modeling and Evaluation` to `Explorer and Model Findings`, `Findings and Leakage Rules`, `README and Project Brief`, `Report Body and Data Sources`?**
  _High betweenness centrality (0.465) - this node is a cross-community bridge._
- **Are the 4 inferred relationships involving `Analysis Body (shared Quarto child)` (e.g. with `Appendix (shared Quarto child)` and `Conclusion (shared Quarto child)`) actually correct?**
  _`Analysis Body (shared Quarto child)` has 4 INFERRED edges - model-reasoned connections that need verification._
- **What connects `USGS NHD High Resolution and WBD hydrography`, `NCDOT structures and culverts`, `Annual NLCD imperviousness` to the rest of the system?**
  _19 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `ML Modeling and Evaluation` be split into smaller, more focused modules?**
  _Cohesion score 0.06009615384615385 - nodes in this community are weakly interconnected._
- **Why does `Analysis Body (shared Quarto child)` connect `Report Body and Data Sources` to `Targets and ML Export`, `README and Project Brief`, `Spatial Feature Engine`, `NOAA Event Table`?**
  _High betweenness centrality (0.437) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `Spatial features measured around each event` (e.g. with `USDA SSURGO soils` and `Input inventory`) actually correct?**
  _`Spatial features measured around each event` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Should `Report Body and Data Sources` be split into smaller, more focused modules?**
  _Cohesion score 0.06896551724137931 - nodes in this community are weakly interconnected._