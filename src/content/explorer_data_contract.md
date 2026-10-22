# Explorer data contract

The explorer (`src/content/explorer_template.html`) is one self-contained HTML file. The build script (`src/python/export_explorer.py`) replaces the single placeholder line `/*__EXPLORER_DATA__*/` in the template with `const DATA = {...};`. This file defines `DATA`. Every section marked *optional* may be missing or null, and the UI must degrade gracefully.

## What the explorer shows

A what-if map of **how severe a flood-related storm event would be at each place**, from a logistic regression. Risk means: *the estimated chance that a flood-related NOAA event reported at this place is high-consequence (at least one death, or reported damage above $200,000), given the scenario.* It is explanatory, not a forecast. It does not predict whether a flood happens.

## Model (must match the report exactly)

`p = sigmoid(intercept + sum_j coef_j * (x_j - mean_j) / std_j)`, with no clipping. Platt calibration is already folded into `coef` and `intercept`. Missing feature values are replaced by `median_j` before scoring.

## DATA layout

```
DATA = {
  meta: {
    title, subtitle, generated,                    // strings
    hc_definition,                                 // plain-language target definition
    n_events, n_dev, n_test, base_rate_dev, base_rate_test,
    model: { name, n_features, cv_pr_auc, cv_pr_auc_sd, cv_base_rate, season_only_pr_auc,
             holdout_pr_auc, holdout_pr_lo, holdout_pr_hi, holdout_top10_capture, holdout_top10_lo,
             holdout_top10_hi, holdout_n, holdout_positives,
             holdout_excl_helene_pr_auc, holdout_excl_helene_positives, helene_share_of_test_positives },
    helene: { label, start, end, rain_window_note, n_events, n_deaths, damage },   // storm-level replay window
    grid:   { dlon, dlat, west, east, south, north, n },                           // cell size in degrees
    sources: [ { name, note } ],
    limitations: [ string ]
  },
  features: [ { key, label, group, unit, display_unit, display_scale,   // shown = value * display_scale
                min, max, step,                                         // slider range in DISPLAY units (null if not a slider)
                scenario: true|false,                                   // true if the user sets it directly
                description } ],
  groups: [ { key, label } ],                                           // Season, Place, People, History, Rainfall
  model: { features: [key], coef: {key:v}, intercept, mean: {key:v}, std: {key:v}, median: {key:v} },
  scenario: { presets: [ { id, label, description, values: { rain_event_total_mm, rain_max_1day_mm,
                                                            rain_antecedent_7d_mm, event_month } } ],
              ratio_max1day_to_total, antecedent_default_mm },            // basic slider derives the other two rain inputs
  grid: {                                                                  // columnar; null = missing; row k = one cell
    lon:[], lat:[], county:[],                                             // county = index into countyStats
    elevation_m:[], slope_degrees:[], impervious_mean_250m:[], distance_to_stream_m:[], local_relief_5km:[],
    population_density:[], SOVI_SCORE:[],                                  // county values (from FEMA NRI)
    nearby_minor_flood_count_25km:[], nearby_severe_flood_count_25km:[],   // events in the 3 years before the end of the data
    hand_m:[], drainage_area_km2_max_250m:[], svi_rpl_themes:[],           // context for the place card (not in the model)
    helene_rain_total_mm:[], helene_rain_max_1day_mm:[], helene_rain_antecedent_7d_mm:[]
  },
  counties: <GeoJSON FeatureCollection>,                                   // properties: idx, name, fips3, region, study
  countyStats: [ { idx, name, fips3, region, study, population_density, SOVI_SCORE,
                   events, hc_events, deaths, damage,                      // flood-related NOAA events 2016-2026
                   helene_events, helene_hc_events, helene_deaths, helene_damage } ],
  events: [ { id, date, type, county, lat, lon, deaths, damage, hc, split, p, rain_total_mm, helene } ],
  cities: [ { name, lat, lon, size } ],                                    // size 1 (big) to 3 (small)
  hillshade: { uri, west, east, south, north },                            // grayscale PNG data URI, EPSG:4326 bounds
  validation: {                                                            // optional
    ladder:   [ { group, model, gain, lo, hi } ],                          // paired PR-AUC gain from adding the group
    spatial:  [ { scheme, model, pr_auc, pr_sd, roc_auc } ],
    temporal: [ { year, model, n, positives, base_rate, pr_auc, roc_auc } ],
    permutation: { observed, null_mean, null_p95, p_value, n_perm }
  }
}
```

## Feature keys (the 14 model features)

Season: `event_month`, `peak_hurricane_season` (1 for months 8-10; always derived from the month).
Place: `slope_degrees`, `elevation_m`, `impervious_mean_250m`, `distance_to_stream_m`, `local_relief_5km`.
People: `population_density`, `SOVI_SCORE` (county values).
History: `nearby_minor_flood_count_25km`, `nearby_severe_flood_count_25km`.
Rainfall: `rain_event_total_mm`, `rain_max_1day_mm`, `rain_antecedent_7d_mm`.

Context-only (shown on the place card, not model inputs): `hand_m`, `drainage_area_km2_max_250m`, `svi_rpl_themes`.

## Design rules

- Single HTML file. No network at run time: no CDN, no map tiles, no web fonts.
- Match the report: navy `#12344d`, teal `#1b7a8c`, river `#4a9cc9`, alert `#b2182b`, sand `#f5f1e8`, ink `#1f2a33`, muted `#5b6770`. Cards have a 4 px colored top border, 10 px radius, and a soft shadow. Pills have a 1 px teal border and 14 px radius.
- Rain is stored in mm and shown in inches.
- The risk legend uses an absolute scale (0 to 50% by default) with a "relative to this map" toggle.
