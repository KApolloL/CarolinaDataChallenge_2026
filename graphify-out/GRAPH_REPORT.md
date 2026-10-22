# Graph Report - CarolinaDataChallenge_2026  (2026-10-22)

## Corpus Check
- 0 files · ~0 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 305 nodes · 546 edges · 19 communities (16 shown, 3 thin omitted)
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 31 edges (avg confidence: 0.83)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Analysis Body (shared Quarto child)
- Machine-learning handoff files (data/ml_
- build_explorer()
- _modeling.qmd (Modeling and Results sect
- _fit_predict()
- highground_ml.py
- README.md (Carolina HighGround)
- create_spatial_features.R
- fit_holdout()
- download_data.R
- prepare_noaa.R
- export_ml_tables.R
- helene_sensitivity()
- Explorer data contract
- Logistic regression, random forest, hist
- validation_summary()
- build_hydro_rasters()
- build_explorer_data()
- build_explorer_grid()

## God Nodes (most connected - your core abstractions)
1. `Analysis Body (shared Quarto child)` - 57 edges
2. `_modeling.qmd (Modeling and Results section)` - 26 edges
3. `build_explorer()` - 22 edges
4. `run_all()` - 19 edges
5. `Spatial features measured around each event` - 15 edges
6. `build_spatial_features()` - 14 edges
7. `Machine-learning handoff files (data/ml_ready)` - 12 edges
8. `fit_holdout()` - 10 edges
9. `download_all_missing()` - 9 edges
10. `try_download()` - 9 edges

## Surprising Connections (you probably didn't know these)
- `Helene dominates holdout (66% of positives)` --semantically_similar_to--> `In-bag calibration bug`  [INFERRED] [semantically similar]
  outs/presentation/carolina_highground_project_brief.md → src/_modeling.qmd
- `Helene dominates holdout (66% of positives)` --semantically_similar_to--> `Helene sensitivity check (holdout with and without Helene week)`  [INFERRED] [semantically similar]
  outs/presentation/carolina_highground_project_brief.md → src/_modeling.qmd
- `high_consequence target and chronological split` --semantically_similar_to--> `Leakage-safe high_consequence target (train-years threshold $200,000)`  [INFERRED] [semantically similar]
  outs/presentation/carolina_highground_project_brief.md → README.md
- `Project limitations (reporting record, modest skill, explanatory)` --semantically_similar_to--> `Modeling limitations (few severe events, Helene dominance, explanatory not predictive)`  [INFERRED] [semantically similar]
  outs/presentation/carolina_highground_project_brief.md → src/_modeling.qmd
- `FEMA National Risk Index v1.20` --semantically_similar_to--> `FEMA National Risk Index county table (SOVI, population density)`  [INFERRED] [semantically similar]
  README.md → src/_modeling.qmd

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Targets, split, leakage rules and export for ML handoff** — src__analysis_body_targets, src__analysis_body_chronological_split, src__analysis_body_leakage_rules, src__analysis_body_feature_dictionary, src__analysis_body_ml_ready_export [EXTRACTED 0.85]
- **Datasets combined into per-event spatial features** — src__analysis_body_usgs_nhd, src__analysis_body_terrain_3dep, src__analysis_body_ncdot_crossings, src__analysis_body_nlcd_imperviousness, src__analysis_body_gridmet_rainfall, src__analysis_body_hydrology_hand, src__analysis_body_cdc_svi, src__analysis_body_spatial_features [EXTRACTED 0.95]
- **Supporting datasets feeding the ML feature table** — readme_noaa_storm_events, readme_nhd_wbd, readme_dem_terrain, readme_nlcd_impervious, readme_fema_nri, readme_gridmet_precipitation, readme_cdc_svi, readme_hand_hydrology, readme_ncdot_structures [EXTRACTED 1.00]
- **Three renderings of the same report body** — src_final_analysis_deliverable, src_analysis, src_analysis_quick [EXTRACTED 1.00]
- **Leakage-safe modeling validation pipeline** — readme_leakage_safe_target, src__modeling_grouped_cross_validation, src__modeling_platt_calibration, src__modeling_holdout_test, src__modeling_helene_sensitivity [INFERRED 0.85]

## Communities (19 total, 3 thin omitted)

### Community 0 - "Analysis Body (shared Quarto child)"
Cohesion: 0.07
Nodes (53): Analysis Body (shared Quarto child), CDC/ATSDR Social Vulnerability Index (tract), Chronological train/validation/test split, Common CRS and geometry cleaning (st_zm, st_make_valid, st_transform), Event-level table (one row per EVENT_ID), Feature dictionary, gridMET daily precipitation, Hurricane Helene Western NC case (+45 more)

### Community 1 - "Machine-learning handoff files (data/ml_"
Cohesion: 0.07
Nodes (24): Helene dominates holdout (66% of positives), high_consequence target and chronological split, Project limitations (reporting record, modest skill, explanatory), Finding: rainfall explains more than terrain or vulnerability, Region assignment for county and forecast-zone records, CDC/ATSDR SVI tract data, DEM terrain (elevatr, EPSG:32119), FEMA National Risk Index v1.20 (+16 more)

### Community 2 - "build_explorer()"
Cohesion: 0.14
Nodes (15): build_cities(), build_counties(), build_events(), build_explorer(), build_features_block(), build_grid(), build_scenarios(), build_validation() (+7 more)

### Community 3 - "_modeling.qmd (Modeling and Results sect"
Cohesion: 0.12
Nodes (11): _modeling.qmd (Modeling and Results section), best_model(), build_model_frame(), feature_availability(), primary_features(), run_all(), season_inversion(), shap_values() (+3 more)

### Community 4 - "_fit_predict()"
Cohesion: 0.12
Nodes (11): calibration_deciles(), county_blocked_cv(), _fit_predict(), make_group_folds(), permutation_test(), score(), region_holdout(), rolling_origin() (+3 more)

### Community 5 - "highground_ml.py"
Cohesion: 0.14
Nodes (10): ablation_sets(), ablation_study(), compare_models(), _cv_cached(), feature_ladder(), load_flood_table(), main(), _paired() (+2 more)

### Community 6 - "README.md (Carolina HighGround)"
Cohesion: 0.15
Nodes (17): Carolina HighGround project brief for presentation, Hurricane Helene impact in 11 WNC counties (75 deaths, $1.7B), Asheville High School student interview themes, Suggested presentation arc, Research question: which storm events become high-consequence, README.md (Carolina HighGround), AI assistance disclosure (Claude, Claude Code), Carolina HighGround project (+9 more)

### Community 7 - "create_spatial_features.R"
Cohesion: 0.19
Nodes (14): build_spatial_features(), cached_spatial_features(), count_within_m(), describe_vector_layer(), extract_raster_features(), feature_column_names(), load_nhd_flowlines(), load_point_layer() (+6 more)

### Community 8 - "fit_holdout()"
Cohesion: 0.16
Nodes (8): calibrate(), calibration_check(), fit_holdout(), logit(), make_model(), needs_scaling(), platt(), repeated_group_cv()

### Community 9 - "download_data.R"
Cohesion: 0.32
Nodes (15): download_all_missing(), download_arcgis_layer(), download_dem_terrain(), download_nc_counties(), download_ncdot(), download_nhd_state(), download_nlcd_impervious(), download_noaa_storm_events() (+7 more)

### Community 10 - "prepare_noaa.R"
Cohesion: 0.24
Nodes (10): assign_nc_region(), assign_one(), build_event_level(), duplication_check(), list_noaa_files(), load_noaa_tables(), nc_county_lookup(), parse_noaa_damage() (+2 more)

### Community 11 - "export_ml_tables.R"
Cohesion: 0.22
Nodes (6): add_targets(), assign_split(), build_feature_dictionary(), column_roles(), export_ml_tables(), write_outputs()

### Community 12 - "helene_sensitivity()"
Cohesion: 0.25
Nodes (4): capture_metrics(), helene_sensitivity(), holdout_bootstrap(), score_metrics()

### Community 13 - "Explorer data contract"
Cohesion: 0.29
Nodes (6): DATA layout, Design rules, Explorer data contract, Feature keys (the 14 model features), Model (must match the report exactly), What the explorer shows

### Community 14 - "Logistic regression, random forest, hist"
Cohesion: 0.33
Nodes (5): Interactive risk explorer (HighGround), Mountain season inversion, SHAP feature drivers (random forest), Logistic regression, random forest, histogram gradient boosting, is_tropical_event constant flag (dead feature)

### Community 15 - "validation_summary()"
Cohesion: 0.50
Nodes (3): _json_clean(), _records(), validation_summary()

## Knowledge Gaps
- **19 isolated node(s):** `Configuration summary`, `Audiences who could use this`, `high_consequence target and chronological split`, `Project limitations (reporting record, modest skill, explanatory)`, `Region assignment for county and forecast-zone records` (+14 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 107 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `_modeling.qmd (Modeling and Results section)` connect `_modeling.qmd (Modeling and Results sect` to `Analysis Body (shared Quarto child)`, `Machine-learning handoff files (data/ml_`, `_fit_predict()`, `highground_ml.py`, `README.md (Carolina HighGround)`, `fit_holdout()`, `helene_sensitivity()`, `Logistic regression, random forest, hist`?**
  _High betweenness centrality (0.452) - this node is a cross-community bridge._
- **Are the 4 inferred relationships involving `Analysis Body (shared Quarto child)` (e.g. with `Appendix (shared Quarto child)` and `Conclusion (shared Quarto child)`) actually correct?**
  _`Analysis Body (shared Quarto child)` has 4 INFERRED edges - model-reasoned connections that need verification._
- **What connects `Configuration summary`, `Audiences who could use this`, `high_consequence target and chronological split` to the rest of the system?**
  _19 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Analysis Body (shared Quarto child)` be split into smaller, more focused modules?**
  _Cohesion score 0.06896551724137931 - nodes in this community are weakly interconnected._
- **Why does `Analysis Body (shared Quarto child)` connect `Analysis Body (shared Quarto child)` to `prepare_noaa.R`, `export_ml_tables.R`, `README.md (Carolina HighGround)`, `create_spatial_features.R`?**
  _High betweenness centrality (0.372) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `Spatial features measured around each event` (e.g. with `USDA SSURGO soils` and `Input inventory`) actually correct?**
  _`Spatial features measured around each event` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Should `Machine-learning handoff files (data/ml_` be split into smaller, more focused modules?**
  _Cohesion score 0.07142857142857142 - nodes in this community are weakly interconnected._