# Carolina HighGround: Project Brief for Presentation Planning

> **How to use this file:** it is a complete, self-contained summary of our Carolina Data Challenge 2026 project, written to be uploaded into a Claude chat so we can plan the presentation (story, slides, script, visuals). Every number here comes from our rendered final report (`outs/report/final_analysis_deliverable.html`) unless marked otherwise. Items marked **[confirm]** still need a team decision or check.

---

## 1. One-sentence pitch

**Carolina HighGround uses public data and machine learning to show which storm events in North Carolina become deadly or very costly, and what about the surrounding landscape and community makes them so, so that Western North Carolina can prepare for the next Helene before it arrives.**

- **Theme:** AI and data for social good. The focus is on people, not just property.
- **Event:** Carolina Data Challenge 2026 (hackathon).
- **Team:** Kent Lee, Matthew Martin, Aaron Chen, Minh Nguyen. Kent built the data pipeline and the R/Quarto report; Minh built the Python models, the calibration and SHAP analysis, and the interactive explorer. [confirm] Matthew's and Aaron's roles.

---

## 2. The hook: Hurricane Helene in Western North Carolina

In late September 2024, Helene's remnants stalled over the Blue Ridge. NOAA's own records for our **11 study counties** (Buncombe, Henderson, Haywood, Madison, McDowell, Transylvania, Yancey, Avery, Watauga, Jackson, Swain) show:

| Metric (study counties, Sept 24–30, 2024) | Value |
|---|---|
| Deaths recorded by NOAA | **75** |
| Reported property + crop damage | **$1.7 billion** |
| Storm events logged that week | 50 (35 flood-related) |
| Share of all storm **deaths** in these counties, 2016–2026 | **85%** |
| Share of all reported **damage** in these counties, 2016–2026 | **88%** |

**Thesis line:** *"In the mountains, a rare event can outweigh a decade of ordinary storms."* That's why we study the **places** that make an event deadly, not just the storms themselves.

---

## 3. The human side: our interview

We interviewed **two friends who attended Asheville High School during Hurricane Helene** (8 min 43 s video, with their consent). In the report they are referred to generically; the video itself contains their names. Their themes map directly onto what the project measures:

| Theme | Quote (timestamp in video) | Connects to |
|---|---|---|
| No one expected it here | "Hurricane[s] never impacted our region at all ever, you know. So like we heard that there was a hurricane, but nobody thought it was bad at all." (5:43) | Why advance risk identification matters |
| No one expected it here | "If there's further warning ... we definitely could have prepared." (5:59) | Early warning / preparedness |
| Weeks without the basics | "We didn't have water or power for about two weeks and then we got water, but it was not potable for about a month and a half." (2:16) | Community impact beyond damage dollars |
| Neighbors helping neighbors | "Even though they were all on wells, they had no generators. So I remember, like, [carrying] water to them..." (2:43) | Social vulnerability |
| Learning interrupted | "We were out of school for about a month, a little bit over a month." (2:53); "Nobody had internet. So like there was no work that you could do." (3:19) | Human cost to students |
| The river in the valley | "The village lies in a valley with the [Swannanoa] River going between..." (6:29); "...all I could see were the tops of buildings." (7:05, Biltmore Village) | Stream proximity, valley terrain |
| What would have helped | "A lot of the roads were blocked for a little bit too long ... better resource management would have helped." (4:20) | Road crossings / infrastructure (NCDOT) |

Quotes come from an automatic local Whisper transcript; words in [brackets] are corrections. **[confirm] Check each quote against the video before putting it on a slide.**

---

## 4. Research question and approach

> **Which storm events in North Carolina become high-consequence (deadly or very costly), and what features of the landscape and built environment around them (steep terrain, nearby streams, road crossings, paved surfaces) help explain it?**

Pipeline (R for data, Python for models, combined in one Quarto document via `reticulate`):

1. **NOAA storm records** → one clean row per event (15,889 events, 2016–2026).
2. **Landscape and infrastructure layers** (streams, terrain, road crossings, paved surface, soils).
3. **Spatial features measured around each event point** (distances, counts within 250 m / 1 km, raster means).
4. **ML-ready table** with leakage-safe labels and a chronological split.
5. **Models** (logistic regression, random forest, gradient boosting), calibration, and explanation (SHAP).
6. **Interactive risk explorer** for scenario exploration.

---

## 5. Data sources

| Dataset | Source | What it gives us | Caveat |
|---|---|---|---|
| **NOAA Storm Events** (primary) | NOAA NCEI bulk CSVs, 2016–2026 (33 files: details, fatalities, locations) | What happened, where, deaths, injuries, damage | Damage is estimated in nominal dollars; 2026 is partial (through June 30, 2026) |
| **USGS NHD High Resolution + WBD** | USGS National Map, NC state extract | Streams/rivers; HUC12 subwatersheds | Point/buffer proximity only; no upstream drainage area |
| **Terrain (3DEP-derived)** | `elevatr` AWS Terrain Tiles (USGS 3DEP in the US), ~62 m cells | Elevation, slope, roughness; 5 km local relief | Coarser than native 3DEP |
| **NCDOT Structures** | NCDOT ArcGIS service | 14,318 bridges/structures + 3,062 culverts | Inventory may be incomplete |
| **USGS Annual NLCD** | Fractional impervious surface, 2023 | % paved surface around each event | Single 2023 layer (post-dates most events) |
| **USDA SSURGO** | Soil Data Access | Hydrologic soil group, drainage class | Tabular only, not mapped to events |
| **FEMA National Risk Index** | NRI county table v1.20 (Dec 2025) | Social Vulnerability score (SOVI), population density | County-level (same value for every event in a county) |
| **Census county boundaries** | 2023 cartographic file (tigris) | Maps only | |

**Added Oct 2026:**

| Dataset | Source | What it gives us |
|---|---|---|
| gridMET daily precipitation | 4 km grid, 2016-2026 | event-window rain, wettest day, prior 7 days |
| DEM hydrology | WhiteboxTools on our DEM | HAND and upstream drainage area (checked against USGS gages: French Broad at Asheville within 0.1%) |
| CDC/ATSDR SVI | NC tracts, 2016/2018/2020/2022 | tract vulnerability percentiles |

Annual NLCD is now year-matched for 2016-2023.

**Still missing (roadmap):** hourly rainfall (Stage IV), direct impact records (USGS high-water marks, FEMA claims, NCDOT closures).

---

## 6. Data processing highlights (the "we did it right" points)

- **One row per event.** NOAA's three tables can't be naively joined: fatalities has up to 150 rows per event and locations up to 8. Impacts are collapsed with `max()`, never `sum()`, so deaths and damage are not double-counted. Validation: 15,889 rows = 15,889 unique event IDs.
- **Region assignment for county *and* forecast-zone records.** Zone names such as "BURKE MOUNTAINS", "INLAND PENDER" and "HATTERAS ISLAND" are matched to counties by rule. **Every record matched; zero fell through to "unmatched."** Events by region: central 6,710 · coastal 5,626 · mountains 3,553.
- **Honest about gaps.** 26.9% of all events have no coordinates (mostly zone records), but **97.6% of flood-related events do**. Missing values are never filled with zero, and no centroid coordinates are invented.
- **One coordinate system** (NC State Plane, EPSG:32119) for all distances. Geometry is cleaned before every spatial operation; NHD lines are 3D-measured and would crash GEOS otherwise.
- **Leakage-safe target.** `high_consequence` = death **or** damage above the 90th percentile of positive damage **computed from training years only** (= **$200,000**).
  - Overall: 576 positive events (3.6%).
  - Flood-related: 201 of 2,720 (7.4%).
  - Secondary label `high_human_impact` (any death or injury): 272 events.
- **Chronological split:** train 2016–2021 · validation 2022–2023 · test 2024–2026. Cross-validation folds are grouped by storm episode.
- **Statewide scale:** 295 deaths, 218 injuries, and $6.5B reported damage across 2016–2026. The top damage types are flash flood ($2.37B, 105 deaths), hurricane ($1.47B), and flood ($1.42B).

---

## 7. Modeling (updated Oct 21, 2026, after the judges' feedback)

> Judges' only written comment was "overstated model performance." The numbers below come from the rebuilt pipeline: a feature ladder with paired comparisons, bootstrap intervals, and a with/without-Helene check. Use these, not the hackathon numbers.

**Data:** flood-related events with coordinates. Development is 1,957 events from 2016-2023 (153 high-consequence, base rate 7.8%). The holdout is 697 events from 2024-2026 (47 high-consequence).

**21 features in 7 groups:**

| Group | Features |
|---|---|
| Season | event month, Aug-Oct flag |
| Place | slope, elevation, 5 km relief, distance to stream, % impervious within 250 m (year-matched NLCD) |
| People (county) | FEMA NRI SOVI, population density |
| History | earlier minor / severe floods within 25 km, past 3 years |
| Rainfall | gridMET event-window total, wettest day, prior 7 days |
| Hydrology | height above nearest stream (HAND), upstream drainage area |
| Tract SVI | CDC/ATSDR overall + 4 themes |

### Headline: cross-validated PR-AUC (5 x 5 grouped folds)

| Model | PR-AUC (mean +/- SD) | ROC-AUC |
|---|---|---|
| **Logistic regression** | **0.299 +/- 0.126** | 0.769 |
| Random forest | 0.243 +/- 0.113 | 0.749 |
| Gradient boosting | 0.213 +/- 0.054 | 0.709 |
| Season only (logistic) | 0.186 | 0.692 |
| No-skill base rate | 0.078 | 0.500 |

**How to say it:** "Our best model scores 0.30 PR-AUC where random guessing scores 0.08 and a season-only model 0.19. That is modest: most events it flags are still not high-consequence."

### What each group adds (gain over the previous group, logistic regression; approximate 95% interval)

| Group | Gain | Clear? |
|---|---|---|
| Place | -0.002 (-0.025 to +0.022) | no |
| People (county) | -0.007 (-0.015 to +0.001) | no |
| History | +0.023 (+0.008 to +0.037) | yes |
| **Rainfall** | **+0.092 (+0.056 to +0.128)** | **yes** |
| Hydrology | +0.005 (-0.005 to +0.015) | no |
| Tract SVI | +0.002 (-0.006 to +0.010) | no |

For the random forest, only Place clearly helps (+0.024, +0.008 to +0.039). **The honest finding: how much rain fell explains far more than where it fell.** With 153 severe events, the data cannot detect small effects from terrain, hydrology, or vulnerability. That is "not shown," not "irrelevant."

### Holdout 2024-2026 (episode-cluster bootstrap, 2,000 resamples)

| Model | PR-AUC [95% CI] | Top 10% catches [95% CI] |
|---|---|---|
| Logistic regression | 0.447 [0.062-0.570] | 66% [21%-86%] |
| Random forest | 0.291 [0.063-0.525] | 55% [25%-85%] |
| Gradient boosting | 0.370 [0.076-0.474] | 55% [25%-71%] |

**Helene caveat (say it):** 66% of test positives are from the Helene week. Excluding that week, logistic PR-AUC drops from 0.447 to 0.080 (base rate 2.6%). The holdout mostly measures recognizing one storm. The intervals overlap, so the holdout cannot pick a best model.

### Calibration (bug found and fixed, recomputed)

| Random forest Platt fit | Mean predicted risk (test) | Highest |
|---|---|---|
| In-bag (bug) | 2.6% | 53.3% |
| Out-of-fold (used) | 5.6% | 37.5% |
| Observed rate | 6.7% | |

### Top drivers (random forest mean SHAP; direction from logistic regression)

1. Event month (raises).
2. Wettest single day of rain (raises).
3. Event-window rain total (raises).
4. % impervious (lowers; may partly reflect how urban vs rural events get reported).
5. Peak-season flag (raises).
6. Rain in the prior 7 days (raises).
7. Earlier minor floods nearby (lowers).

The SVI theme coefficients are collinear (overall plus 4 themes), so their individual signs should not be interpreted.

### Corrections to the hackathon story (all recomputed)

- **"Dead feature":** `is_tropical_event` is 0 for every flood event, so it is constant; no tree can use a constant. It was never a model bug.
- **Mountain inversion:** on 535 real mountain events the random forest scores a September storm below a July one 27% of the time; logistic regression 0%. The old 82% / 85.6% came from the explorer grid and an older model.
- **Calibration:** in-bag calibration pulled mean risk to 2.6% vs 5.6% out-of-fold (observed 6.7%).

### Interactive explorer

The UI is Minh's. It is now regenerated from our own 11-feature logistic model every render, and its in-page text uses computed numbers. The original is archived in `src/legacy/minh/`.

## 8. Limitations (say these out loud; they read as rigor)

- **The outcome is a reporting record.** NOAA damage and deaths depend on who reports, where, and how carefully; the event point is where it was reported, not where the water was. Some patterns (e.g., "paved surface lowers risk") may partly reflect reporting differences.
- **Modest skill.** PR-AUC 0.30 vs 0.19 for season alone. Most of what the model flags is still not high-consequence.
- **Rainfall is the one clear gain; terrain, hydrology, tract SVI, and county vulnerability add nothing we can measure** with 153 severe events. "Not shown" is not "irrelevant."
- **One storm dominates the holdout.** 66% of 2024-2026 test positives are Helene; without it, holdout PR-AUC is about 0.08.
- **Explanatory, not predictive.** Rainfall describes the storm itself, so the model explains severity given a flood-related event; it does not forecast floods.
- **Daily 4 km rainfall** smooths short intense bursts. A 62 m DEM blurs narrow valleys, and basins that start outside NC are truncated at the state line (flagged).
- 4,279 events without coordinates are excluded from spatial features (never given a fake location).
- NCDOT and NHD are current snapshots applied to 2016-2026 events; imperviousness is year-matched through 2023 (later events use 2023).
- 2026 is a partial year.

---

## 9. Figures available (all in `outs/figures/`, PNG)

| File | Shows | Good for |
|---|---|---|
| 01_region_map | NC regions + 11 study counties outlined | Setting / study area |
| 02_events_by_year_region | Storm events per year by region | Data scale |
| 03_flood_calendar | Flood events by month × year heatmap (Sept 2024 stands out) | Seasonality → season features |
| 04_top_event_types_by_region | Most frequent event types per region | Context |
| 05_impacts_by_event_type | Damage + deaths/injuries by event type | "Floods are the killers" |
| 06_study_area_damage_timeline | Monthly damage in study counties; Helene spike | **Hook slide** |
| 07_nhd_study_area_streams | Dense stream network of the study counties | Data layer visual |
| 08_wbd_huc12 | Statewide subwatersheds | Data layer visual |
| 09_terrain | Statewide elevation + study-area slope | Why the mountains are different |
| 10_ncdot_assets | Statewide bridges and culverts | Infrastructure |
| 11_nlcd_impervious_study_area | Paved surface in study counties (Asheville visible) | Development |
| 12_ssurgo_summary | Soil groups, study vs. rest of NC | Soils |
| 13_predictor_missingness | Missing share per predictor | Data honesty |
| 14_high_consequence_rate | High-consequence rate by year and region | Target |
| 15_features_by_target | Feature distributions, high-consequence vs. other | EDA → ML bridge |
| 16_feature_correlation | Feature correlation matrix | Feature engineering |
| 17_map_statewide_flood_events | Where flood events became high-consequence | Map slide |
| 18_map_study_area | Study area: events, streams, crossings | Map slide |
| 19_model_pr_curve | Precision-recall, holdout | Results |
| 20_model_calibration | Calibration raw vs. calibrated | Bug-fix slide |
| 21_model_shap_summary | SHAP summary (random forest) | What drives risk |
| 22_model_feature_ladder | PR-AUC by feature group vs season and base rate | **Honest-results slide** |
| 11b_helene_rainfall | Rain that fell during Helene week, study counties | Hazard visual |
| 11c_hand_study_area | Height above nearest stream, study counties | Flood physics |
| 11d_svi_study_area | Tract SVI 2022, study counties | Who lives there |

Also: the interview video (`data/derived/media/interview_web.mp4`, 34 MB web copy; poster frame `interview_poster.jpg`), and interactive tables in the report.

---

## 10. Deliverables

| Deliverable | Location |
|---|---|
| **Final report** (R + Python, self-contained HTML with video and explorer) | `outs/report/final_analysis_deliverable.html` (~75 MB) |
| Data-pipeline report (R only) | `outs/report/analysis.html` |
| Report source | `src/final_analysis_deliverable.qmd` (+ `_analysis_body.qmd`, `_modeling.qmd`, `_appendix.qmd`) |
| ML-ready data | `data/ml_ready/` (Parquet/CSV, feature dictionary, target config) |
| Interactive explorer | `src/content/highground_explorer.html` |
| Figures / tables | `outs/figures/`, `outs/tables/` |
| Minh's original model scripts and slide outline | `src/legacy/minh/` |

---

## 11. Suggested presentation arc (starting point)

Adapted from Minh's technical outline plus the interview. **[confirm] time limit, number of slides, judging criteria, and audience (technical vs. general)** before finalizing.

1. **Hook:** Helene numbers (75 deaths, $1.7B, 85% of a decade's deaths in one week) + damage timeline figure.
2. **Human story:** a 30–60 s interview clip (suggested moments: 5:43 "never impacted our region", 7:05 "tops of buildings", 4:20 "roads blocked").
3. **Question:** which storms become deadly, and why there?
4. **Data:** NOAA + 6 supporting datasets; "why NOAA alone isn't enough."
5. **Pipeline rigor:** one-row-per-event, region matching, leakage-safe labels, grouped CV.
6. **Models and results:** three models; PR-AUC 0.30 vs 0.08 chance and 0.19 season-only; why PR-AUC; the feature ladder (rainfall is the big gain).
7. **What drives risk:** rainfall and season first; the impervious finding with its reporting caveat; local flood history.
8. **We checked our own claims:** calibration fix, the constant "dead feature", the Helene-excluded holdout.
9. **Explorer demo:** Helene-like scenario in the mountains.
10. **Limitations and roadmap:** hourly rainfall, direct impact records (USGS high-water marks, FEMA claims, NCDOT closures), a partner to validate with.
11. **Social-good close:** tie back to the interview: prepare places and people before the next storm.

---

## 12. Open questions for the presentation chat

- Which model is the "headline" model? Logistic regression now leads both cross-validation and holdout, is fully explainable, and is what the explorer runs.
- Live explorer demo or screenshots (demo risk)?
- Which 1–2 interview clips, and do the interviewees approve being shown by name on a slide?
- Minh's outline cites a "published Texas flash-flood benchmark (PR-AUC 0.127)". We have **no source for it**, so it is left out of the report. Include it only if we can cite the paper.
- Should we show statewide results or keep the focus on the 11 WNC counties?
