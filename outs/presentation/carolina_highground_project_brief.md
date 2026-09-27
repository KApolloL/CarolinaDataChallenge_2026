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

**Not included (roadmap):** rainfall totals (e.g., Stage IV / gridMET) and a tract-level vulnerability index.

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

## 7. Modeling

**Data:** flood-related events with coordinates.
- Development: **1,957 events from 2016–2023** (153 high-consequence).
- Holdout test: **697 events from 2024–2026** (47 high-consequence; includes Helene).

**11 features:**

| Group | Features |
|---|---|
| Terrain | slope, elevation, 5 km local relief (max − min elevation, computed from the DEM) |
| Water | distance to nearest stream |
| Development | % impervious within 250 m |
| People | county SOVI score, population density (FEMA NRI) |
| History | earlier *minor* and *severe* floods within 25 km in the past 3 years (past events only) |
| Season | event month, peak-hurricane-season flag (Aug–Oct) |

**Three models:** logistic regression (fully explainable), random forest (captures feature combinations), histogram gradient boosting (comparison).

**Training recipe:** leakage-safe labels · class weighting (positives are rare) · grouped cross-validation by storm episode · imputation fit inside folds · Platt calibration fit on out-of-fold predictions.

### Results: repeated grouped 5×5 cross-validation (the headline numbers)

| Model | PR-AUC | ROC-AUC | Lift over chance (PR-AUC) |
|---|---|---|---|
| Logistic regression | 0.200 ± 0.061 | 0.731 ± 0.058 | 2.6× |
| **Random forest** | **0.221 ± 0.089** | **0.740 ± 0.092** | **2.8×** |
| Gradient boosting | 0.211 ± 0.082 | 0.712 ± 0.093 | 2.7× |
| No-skill baseline | 0.078 | 0.500 | 1.0× |

**Talking point:** PR-AUC is the metric that matters because high-consequence events are rare. A model can look fine on ROC-AUC while being poor at finding the few events that matter. Our best model is about **2.8× better than chance** at ranking them.

### Holdout test, 2024–2026 (illustrative; small sample, dominated by Helene)

| Model | PR-AUC | ROC-AUC |
|---|---|---|
| Logistic regression | 0.339 | 0.808 |
| Random forest | 0.175 | 0.781 |
| Gradient boosting | 0.204 | 0.752 |

The simpler logistic model generalized best to the Helene-heavy test years; the random forest was strongest in cross-validation. **[confirm] which model to feature as "primary"** (Minh's explorer calls the random forest primary; the holdout favors logistic regression).

### Calibration (a real bug found and fixed)

Platt scaling fit on the forest's own training ("in-bag") predictions made it underconfident. Fitting on out-of-fold predictions fixed it (test years):

| Random forest calibration | Mean predicted risk | Highest predicted risk |
|---|---|---|
| In-bag (buggy) | 2.5% | 48.9% |
| Out-of-fold (used) | 4.8% | 33.8% |
| Observed test rate | 6.7% | — |

### What drives predictions (SHAP on the random forest + logistic-regression signs)

| Rank | Feature | Direction | Trees using it (of 100) |
|---|---|---|---|
| 1 | event month | raises risk | 100 |
| 2 | % impervious (250 m) | **lowers** risk | 100 |
| 3 | peak hurricane season | raises risk | 82 |
| 4 | earlier *minor* floods nearby | **lowers** risk | 99 |
| 5 | elevation | lowers risk | 98 |
| 6 | slope | raises risk | 98 |
| 7 | 5 km local relief | raises risk | 96 |
| 8 | population density | raises risk | 95 |
| 9 | SOVI (social vulnerability) | raises risk | 94 |
| 10 | distance to stream | raises risk (weak) | 95 |
| 11 | earlier *severe* floods nearby | raises risk (weak) | 68 |

**Story-worthy findings:**
- **Paved places are *less* likely to see high-consequence floods.** Urban flood reports are often minor nuisance flooding, while the deadliest events hit rural, steep terrain. This is counterintuitive and good for a slide.
- **Flood history cuts both ways:** earlier *minor* floods lower risk (adaptation/preparedness), while earlier *severe* floods raise it (compounding vulnerability).
- **Season dominates**, which matches Helene: the hurricane-season flag is used by 82 of 100 trees.
- **Vulnerability matters:** higher SOVI and population density raise predicted risk. This is the social-good link.

### Lessons from development (from Minh's testing; not recomputed in the report)

- **Dead feature / mountain inversion:** an early `is_tropical_event` flag was used by 0 of 100 trees. In 82% of 90 tested mountain grid cells, a hurricane scenario scored as *less* risky than a typical storm. Adding `peak_hurricane_season` improved CV PR-AUC (0.208 → 0.220) but did not fully fix the inversion (85.6% still inverted), because there are only ~150 severe training examples. The logistic model cannot invert this way.
- **Calibration bug:** in-bag calibration capped the most extreme scenario at 2.6% risk; out-of-fold calibration raised it to 7.9%.

### Interactive risk explorer (built by Minh; embedded in the final report)

A browser app with three views: a historical event map (filter by region/year/high-consequence), a structural risk surface with storm-scenario buttons ("Mountain flash flood", "Urban Piedmont flash flood", "Extreme (Helene-like)"), and a scenario calculator with a plain-English "describe a scenario" box. It runs offline and is explicitly **not an operational flood warning**. Its embedded models come from an earlier training run, so its numbers can differ slightly from the tables above.

---

## 8. Limitations (say these out loud; they read as rigor)

- Point/buffer features only: no upstream drainage area, flow accumulation, or HAND.
- 4,279 events without coordinates are excluded from spatial features (never given a fake location).
- Static layers (2023 imperviousness, current NCDOT/NHD) are applied to 2016–2026 events.
- No rainfall data, so this explains *impact severity given an event*, not *whether* it floods. It is not a forecast.
- Vulnerability is county-level; small number of severe events means wide CV spread; the holdout is dominated by one storm (Helene).
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
6. **Models and results:** three models; PR-AUC 0.221 (2.8× chance); why PR-AUC.
7. **What drives risk:** SHAP, with the counterintuitive impervious finding, flood history both ways, and vulnerability.
8. **We found and fixed real bugs:** calibration + dead feature.
9. **Explorer demo:** Helene-like scenario in the mountains.
10. **Limitations and roadmap:** rainfall, tract-level vulnerability, upstream drainage.
11. **Social-good close:** tie back to the interview: prepare places and people before the next storm.

---

## 12. Open questions for the presentation chat

- Which model is the "headline" model: random forest (best CV) or logistic regression (best holdout, fully explainable, used in the explorer)?
- Live explorer demo or screenshots (demo risk)?
- Which 1–2 interview clips, and do the interviewees approve being shown by name on a slide?
- Minh's outline cites a "published Texas flash-flood benchmark (PR-AUC 0.127)". We have **no source for it**, so it is left out of the report. Include it only if we can cite the paper.
- Should we show statewide results or keep the focus on the 11 WNC counties?
