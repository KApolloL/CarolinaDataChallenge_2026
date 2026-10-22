"""Build the interactive explorer from the project's own model and data.

Usage (from anywhere):

    python src/python/export_explorer.py --project-dir <project root>

What it does
------------
1. Fits the explorer's model with `highground_ml`: logistic regression on the
   "+ Rainfall" feature set (season, place, people, history, rainfall; 14
   features), with out-of-fold Platt calibration folded into the coefficients.
2. Assembles the `DATA` object described in `src/content/explorer_data_contract.md`
   from: the fitted model, the 4 km grid built by `src/R/explorer_data.R`
   (data/derived/explorer/), the flood-event table in data/ml_ready/, FEMA NRI, and the
   validation tables from highground_ml.
3. Injects `const DATA = {...};` into `src/content/explorer_template.html` at the single
   `/*__EXPLORER_DATA__*/` line and writes `src/content/highground_explorer.html`.

Every number the explorer shows is computed here from the data; nothing is typed in.

The model formula the explorer uses (identical to the report's logistic regression):

    p = sigmoid(intercept + sum_j coef_j * (x_j - mean_j) / std_j)

with Platt scaling folded into coef (coef * scale) and intercept (intercept * scale + shift).
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import re
import sys
import time
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.neighbors import BallTree

sys.path.insert(0, str(Path(__file__).resolve().parent))
import highground_ml as hg  # noqa: E402

MODEL_NAME = "Logistic regression"
MODEL_RUNG = "+ Rainfall"
PLACEHOLDER = "/*__EXPLORER_DATA__*/"
HELENE_RAIN_WINDOW = "2024-09-24 to 2024-09-28 (prior-week rain: 2024-09-17 to 2024-09-23)"
HC_DEFINITION = ("a death, or reported damage above ${thr:,.0f} (the 90th percentile of positive damage in "
                 "the training years)")

GROUPS = [("season", "Season"), ("place", "Place"), ("people", "People (county)"),
          ("history", "Local flood history"), ("rainfall", "Rainfall")]

# key -> (label, group, unit, display_unit, display_scale, min, max, step, scenario, description)
FEATURES = [
    ("event_month", "Month of the storm", "season", "month", "", 1, 1, 12, 1, True,
     "Calendar month the storm begins."),
    ("peak_hurricane_season", "Peak hurricane season (Aug-Oct)", "season", "flag", "", 1, None, None, None, False,
     "1 when the month is August, September or October. Set from the month."),
    ("slope_degrees", "Slope", "place", "degrees", "degrees", 1, None, None, None, False,
     "Terrain slope at the location (62 m DEM)."),
    ("elevation_m", "Elevation", "place", "m", "m", 1, None, None, None, False, "Height above sea level."),
    ("impervious_mean_250m", "Paved surface within 250 m", "place", "%", "%", 1, None, None, None, False,
     "Mean impervious surface (Annual NLCD) within 250 m."),
    ("distance_to_stream_m", "Distance to nearest stream", "place", "m", "m", 1, None, None, None, False,
     "Distance to the nearest NHD stream or river line."),
    ("local_relief_5km", "Relief within 5 km", "place", "m", "m", 1, None, None, None, False,
     "Highest minus lowest ground within 5 km."),
    ("population_density", "Population density (county)", "people", "people per sq. mile", "per sq. mi", 1,
     None, None, None, False, "County population divided by county area (FEMA NRI)."),
    ("SOVI_SCORE", "Social vulnerability (county SOVI)", "people", "score", "", 1, None, None, None, False,
     "FEMA NRI social vulnerability score for the county."),
    ("nearby_minor_flood_count_25km", "Earlier non-severe floods within 25 km", "history", "events", "", 1,
     None, None, None, False, "Flood-related events in the 3 years before the end of the data, not high-consequence."),
    ("nearby_severe_flood_count_25km", "Earlier severe floods within 25 km", "history", "events", "", 1,
     None, None, None, False, "High-consequence flood-related events in the same window."),
    ("rain_event_total_mm", "Storm rainfall", "rainfall", "mm", "in", 1 / 25.4, 0, 25, 0.25, True,
     "gridMET rain summed over the storm window (starts a day before the event, at most 8 days)."),
    ("rain_max_1day_mm", "Wettest single day", "rainfall", "mm", "in", 1 / 25.4, 0, 15, 0.25, True,
     "Largest one-day gridMET rainfall in the window."),
    ("rain_antecedent_7d_mm", "Rain in the prior 7 days", "rainfall", "mm", "in", 1 / 25.4, 0, 10, 0.25, True,
     "gridMET rain in the 7 days before the window (wet ground)."),
]

# Approximate positions, used only to place labels on the map.
WNC_TOWNS = [("Boone", 36.217, -81.675), ("Hendersonville", 35.319, -82.461), ("Hickory", 35.734, -81.341),
             ("Waynesville", 35.489, -82.989), ("Morganton", 35.745, -81.685)]

FALLBACK_CITIES = [
    ("Charlotte", 35.227, -80.843, 1), ("Raleigh", 35.780, -78.638, 1), ("Asheville", 35.595, -82.552, 1),
    ("Wilmington", 34.226, -77.945, 1), ("Greensboro", 36.073, -79.792, 2), ("Durham", 35.994, -78.899, 2),
    ("Winston-Salem", 36.100, -80.244, 2), ("Fayetteville", 35.053, -78.878, 2), ("Boone", 36.217, -81.675, 3),
    ("Hickory", 35.734, -81.341, 3), ("Greenville", 35.613, -77.366, 3), ("Hendersonville", 35.319, -82.461, 3),
]


# ---- helpers ------------------------------------------------------------------------
def to_py(x):
    """Recursively convert numpy/pandas values to JSON-safe Python (NaN -> None)."""
    if isinstance(x, dict):
        return {str(k): to_py(v) for k, v in x.items()}
    if isinstance(x, (list, tuple)):
        return [to_py(v) for v in x]
    if isinstance(x, (np.integer,)):
        return int(x)
    if isinstance(x, (np.floating, float)):
        return None if (isinstance(x, float) and not math.isfinite(x)) or (
            isinstance(x, np.floating) and not np.isfinite(x)) else float(x)
    if isinstance(x, (np.bool_,)):
        return bool(x)
    if isinstance(x, (pd.Timestamp,)):
        return x.strftime("%Y-%m-%d")
    if x is pd.NA or x is pd.NaT:
        return None
    return x


def column(series, nd=3, as_int=False):
    """Series -> JSON list (None for missing), rounded."""
    out = []
    for v in pd.Series(series).to_numpy():
        if v is None or (isinstance(v, float) and not math.isfinite(v)) or pd.isna(v):
            out.append(None)
        elif as_int:
            out.append(int(v))
        else:
            out.append(round(float(v), nd))
    return out


def log(msg):
    print(msg, flush=True)


# ---- model --------------------------------------------------------------------------
def fit_explorer_model(devel, test, features):
    fit = hg.fit_holdout(devel, test, features, models=(MODEL_NAME,))
    scale, shift = fit["preds"][MODEL_NAME]["scale"], fit["preds"][MODEL_NAME]["shift"]
    lr = fit["fitted"][MODEL_NAME]
    model = {
        "features": list(features),
        "coef": {f: float(c * scale) for f, c in zip(features, lr.coef_[0])},
        "intercept": float(lr.intercept_[0] * scale + shift),
        "mean": {f: float(m) for f, m in zip(features, fit["scaler"].mean_)},
        "std": {f: float(s) for f, s in zip(features, fit["scaler"].scale_)},
        "median": {f: float(m) for f, m in zip(features, fit["imputer"].statistics_)},
    }
    return fit, model


def score_with_export(model, row):
    """Reference implementation of the explorer's formula (used for the self-check)."""
    z = model["intercept"]
    for f in model["features"]:
        v = row.get(f)
        if v is None or (isinstance(v, float) and not math.isfinite(v)):
            v = model["median"][f]
        z += model["coef"][f] * (v - model["mean"][f]) / model["std"][f]
    return 1 / (1 + math.exp(-z))


# ---- pieces of DATA ------------------------------------------------------------------
def build_features_block(model):
    rows = []
    for key, label, group, unit, disp_unit, scale, lo, hi, step, scenario, desc in FEATURES:
        rows.append({"key": key, "label": label, "group": group, "unit": unit, "display_unit": disp_unit,
                     "display_scale": scale, "min": lo, "max": hi, "step": step, "scenario": scenario,
                     "description": desc})
    keys = [r["key"] for r in rows]
    missing = [f for f in model["features"] if f not in keys]
    if missing:
        raise SystemExit(f"model features without explorer metadata: {missing}")
    return rows


def build_counties(explorer_dir, df, nri_path, hl_start, hl_end):
    gj = json.loads((explorer_dir / "counties.geojson").read_text(encoding="utf-8"))
    feats = gj["features"]
    for i, f in enumerate(feats):
        f["properties"]["idx"] = i
        f["properties"]["fips3"] = int(f["properties"]["fips3"])
        f["properties"]["study"] = bool(f["properties"].get("study", False))

    nri = pd.read_csv(nri_path, encoding="utf-8-sig",
                      usecols=["STCOFIPS", "STATEABBRV", "POPULATION", "AREA", "SOVI_SCORE"])
    nri = nri[nri["STATEABBRV"] == "NC"].copy()
    nri["fips3"] = (nri["STCOFIPS"] % 1000).astype(int)
    nri["population_density"] = nri["POPULATION"] / nri["AREA"]
    nri = nri.set_index("fips3")

    d = pd.to_datetime(df["event_date"])
    helene = (d >= pd.Timestamp(hl_start)) & (d <= pd.Timestamp(hl_end))
    by = df.groupby("county_fips3")
    agg = by.agg(events=("event_id", "size"), hc_events=("high_consequence", "sum"),
                 deaths=("total_deaths", "sum"), damage=("total_damage", "sum"))
    hag = df[helene].groupby("county_fips3").agg(helene_events=("event_id", "size"),
                                                 helene_hc_events=("high_consequence", "sum"),
                                                 helene_deaths=("total_deaths", "sum"),
                                                 helene_damage=("total_damage", "sum"))
    stats = []
    for f in feats:
        p = f["properties"]
        fp = p["fips3"]
        a = agg.loc[fp] if fp in agg.index else None
        h = hag.loc[fp] if fp in hag.index else None
        stats.append({
            "idx": p["idx"], "name": p["name"], "fips3": fp, "region": p.get("region"), "study": p["study"],
            "population_density": round(float(nri.loc[fp, "population_density"]), 1) if fp in nri.index else None,
            "SOVI_SCORE": round(float(nri.loc[fp, "SOVI_SCORE"]), 2) if fp in nri.index else None,
            "events": int(a["events"]) if a is not None else 0,
            "hc_events": int(a["hc_events"]) if a is not None else 0,
            "deaths": int(a["deaths"]) if a is not None else 0,
            "damage": round(float(a["damage"])) if a is not None else 0,
            "helene_events": int(h["helene_events"]) if h is not None else 0,
            "helene_hc_events": int(h["helene_hc_events"]) if h is not None else 0,
            "helene_deaths": int(h["helene_deaths"]) if h is not None else 0,
            "helene_damage": round(float(h["helene_damage"])) if h is not None else 0,
        })
    return gj, stats


def build_grid(explorer_dir, df, stats, hist_radius_km=25, hist_years=3, hl_start=None):
    g = pd.read_csv(explorer_dir / "grid.csv")
    idx_by_fips = {s["fips3"]: s["idx"] for s in stats}
    by_idx = {s["idx"]: s for s in stats}
    county = g["county_fips3"].map(idx_by_fips)
    pop = county.map(lambda i: by_idx[i]["population_density"] if pd.notna(i) else None)
    sovi = county.map(lambda i: by_idx[i]["SOVI_SCORE"] if pd.notna(i) else None)

    # Flood history as of the end of the data: events in the final 3 years, split by outcome.
    d = pd.to_datetime(df["event_date"])
    latest = d.max()
    recent = df[d >= latest - pd.Timedelta(days=365 * hist_years)]
    pts = np.radians(g[["lat", "lon"]].to_numpy(dtype=float))
    counts = {}
    for label, sub in (("severe", recent[recent["high_consequence"] == 1]),
                       ("minor", recent[recent["high_consequence"] == 0])):
        if len(sub) == 0:
            counts[label] = np.zeros(len(g), dtype=int)
            continue
        tree = BallTree(np.radians(sub[["latitude", "longitude"]].to_numpy(dtype=float)), metric="haversine")
        counts[label] = tree.query_radius(pts, r=hist_radius_km / 6371.0, count_only=True)

    pre = {}
    if hl_start is not None:
        h0 = pd.Timestamp(hl_start)
        prior = df[(d < h0) & (d >= h0 - pd.Timedelta(days=365 * hist_years))]
        for label, sub in (("severe", prior[prior["high_consequence"] == 1]), ("minor", prior[prior["high_consequence"] == 0])):
            if len(sub) == 0:
                pre[label] = np.zeros(len(g), dtype=int)
            else:
                tr = BallTree(np.radians(sub[["latitude", "longitude"]].to_numpy(dtype=float)), metric="haversine")
                pre[label] = tr.query_radius(pts, r=hist_radius_km / 6371.0, count_only=True)

    block = {
        "lon": column(g["lon"], 4), "lat": column(g["lat"], 4), "county": column(county, as_int=True),
        "elevation_m": column(g["elevation_m"], 1), "slope_degrees": column(g["slope_degrees"], 2),
        "impervious_mean_250m": column(g["impervious_mean_250m"], 1),
        "distance_to_stream_m": column(g["distance_to_stream_m"], 0),
        "local_relief_5km": column(g["local_relief_5km"], 0),
        "population_density": column(pop, 1), "SOVI_SCORE": column(sovi, 2),
        "nearby_minor_flood_count_25km": column(counts["minor"], as_int=True),
        "nearby_severe_flood_count_25km": column(counts["severe"], as_int=True),
        "hand_m": column(g["hand_m"], 1), "drainage_area_km2_max_250m": column(g["drainage_area_km2_max_250m"], 1),
        "svi_rpl_themes": column(g["svi_rpl_themes"], 3),
        "helene_rain_total_mm": column(g["helene_rain_total_mm"], 0),
        "helene_rain_max_1day_mm": column(g["helene_rain_max_1day_mm"], 0),
        "helene_rain_antecedent_7d_mm": column(g["helene_rain_antecedent_7d_mm"], 0),
    }
    if pre:
        block["pre_helene_minor_25km"] = column(pre["minor"], as_int=True)
        block["pre_helene_severe_25km"] = column(pre["severe"], as_int=True)
    return block, g, county, str(latest.date())


def build_scenarios(devel, grid_df, stats, county_idx):
    rain = devel[["rain_event_total_mm", "rain_max_1day_mm", "rain_antecedent_7d_mm"]].dropna()
    big = rain[rain["rain_event_total_mm"] > 5]
    ratio = float((big["rain_max_1day_mm"] / big["rain_event_total_mm"]).median())
    ante = float(rain["rain_antecedent_7d_mm"].median())

    def preset(pid, label, desc, total, month, max1=None, antecedent=None):
        return {"id": pid, "label": label, "description": desc,
                "values": {"rain_event_total_mm": round(float(total), 1),
                           "rain_max_1day_mm": round(float(max1 if max1 is not None else ratio * total), 1),
                           "rain_antecedent_7d_mm": round(float(antecedent if antecedent is not None else ante), 1),
                           "event_month": int(month)}}

    q = rain["rain_event_total_mm"].quantile
    study_idx = {s["idx"] for s in stats if s["study"]}
    in_study = county_idx.map(lambda i: pd.notna(i) and int(i) in study_idx)
    hel = grid_df.loc[in_study, ["helene_rain_total_mm", "helene_rain_max_1day_mm", "helene_rain_antecedent_7d_mm"]]
    presets = [
        preset("typical", "Typical flood-related storm", f"The median storm in 2016-2023 ({q(0.5) / 25.4:.1f} in).",
               q(0.5), 7),
        preset("heavy", "Heavy rain", f"A storm wetter than 90% of recorded events ({q(0.9) / 25.4:.1f} in).",
               q(0.9), 8),
        preset("very_heavy", "Very heavy rain", f"Wetter than 99% of recorded events ({q(0.99) / 25.4:.1f} in).",
               q(0.99), 9),
    ]
    if hel.notna().all(axis=1).any():
        m = hel.mean()
        presets.append(preset(
            "helene", "Helene-like rain, Western NC",
            f"Average Helene-week rain over the 11 study counties ({m['helene_rain_total_mm'] / 25.4:.1f} in), September.",
            m["helene_rain_total_mm"], 9, max1=m["helene_rain_max_1day_mm"], antecedent=m["helene_rain_antecedent_7d_mm"]))
    return {"presets": presets, "ratio_max1day_to_total": round(ratio, 3),
            "antecedent_default_mm": round(ante, 1)}


def build_events(df, fit, stats_by_fips, hl_start, hl_end):
    p = hg.predict_calibrated(fit, MODEL_NAME, df)
    d = pd.to_datetime(df["event_date"])
    helene = ((d >= pd.Timestamp(hl_start)) & (d <= pd.Timestamp(hl_end))).astype(int)
    out = []
    for r, pr, hl, dt in zip(df.to_dict("records"), p, helene, d):
        out.append({
            "id": int(r["event_id"]), "date": dt.strftime("%Y-%m-%d"), "type": r.get("event_type"),
            "county": stats_by_fips.get(int(r["county_fips3"])) if pd.notna(r.get("county_fips3")) else None,
            "lat": round(float(r["latitude"]), 4), "lon": round(float(r["longitude"]), 4),
            "deaths": int(r["total_deaths"]), "damage": round(float(r["total_damage"])),
            "hc": int(r["high_consequence"]), "split": r.get("split"), "p": round(float(pr), 4),
            "rain_total_mm": None if pd.isna(r.get("rain_event_total_mm")) else round(float(r["rain_event_total_mm"]), 0),
            "helene": int(hl),
        })
    return out


def build_cities(root):
    legacy = root / "src/legacy/minh/highground_explorer_original.html"
    if legacy.exists():
        m = re.search(r"const MAJOR_CITIES = (\[.*?\]);", legacy.read_text(encoding="utf-8"), re.S)
        if m:
            try:
                text = re.sub(r",\s*\]", "]", m.group(1))
                raw = json.loads(re.sub(r"(\w+):", r'"\1":', text).replace("'", '"'))
                tier1 = ("Charlotte", "Raleigh", "Asheville", "Wilmington")
                tier2 = ("Greensboro", "Durham", "Winston-Salem", "Fayetteville", "Greenville", "Hickory")
                out = [{"name": c.get("name"), "lat": c.get("lat"), "lon": c.get("lon"),
                        "size": 1 if c.get("name") in tier1 else 2 if c.get("name") in tier2 else 3}
                       for c in raw if c.get("name") and c.get("lat") is not None]
                if len(out) >= 6:
                    # add Western NC towns the legacy list lacks (label positions only; approximate)
                    have = {c["name"] for c in out}
                    out += [{"name": n, "lat": la, "lon": lo, "size": 3} for n, la, lo in WNC_TOWNS if n not in have]
                    return out
            except (ValueError, AttributeError):
                pass
    return [{"name": n, "lat": la, "lon": lo, "size": s} for n, la, lo, s in FALLBACK_CITIES]


def build_validation(devel, rungs, ladder, summary_path):
    """Ladder gains for the explorer's model, plus any spatial/temporal/permutation results on disk."""
    gains = []
    labels = {"+ Place": "Place", "+ People": "People (county)", "+ History": "Local flood history",
              "+ Rainfall": "Rainfall", "+ Hydrology": "Hydrology", "+ Tract SVI": "Tract SVI"}
    lr = ladder[(ladder["model"] == MODEL_NAME) & ladder["pr_gain_vs_previous"].notna()]
    for _, r in lr.iterrows():
        gains.append({"group": labels.get(r["rung"], r["rung"]), "model": MODEL_NAME, "gain": r["pr_gain_vs_previous"],
                      "lo": r["pr_gain_vs_previous_lo"], "hi": r["pr_gain_vs_previous_hi"]})
    out = {"ladder": gains}
    if summary_path.exists():
        extra = json.loads(summary_path.read_text(encoding="utf-8"))
        for k in ("spatial", "temporal", "permutation", "ablation"):
            if extra.get(k):
                out[k] = extra[k]
    return out


# ---- main ----------------------------------------------------------------------------
def build_explorer(project_dir=".", template="src/content/explorer_template.html",
                   out="src/content/highground_explorer.html", explorer_dir="data/derived/explorer",
                   nri_path="data/raw/nri/NRI_Table_Counties.csv", hl_start="2024-09-24", hl_end="2024-09-30",
                   cv_repeats=5, cv_folds=5, docs_copy=None):
    t0 = time.time()
    root = Path(project_dir).resolve()
    rp = lambda p: Path(p) if Path(p).is_absolute() else root / p
    ex_dir = rp(explorer_dir)
    for need in ("grid.csv", "counties.geojson", "hillshade.png", "hillshade.json"):
        if not (ex_dir / need).exists():
            raise SystemExit(f"missing {ex_dir / need}; run build_explorer_data() in src/R/explorer_data.R first")
    html = rp(template).read_text(encoding="utf-8")
    if html.count(PLACEHOLDER) != 1:
        raise SystemExit(f"template must contain exactly one {PLACEHOLDER} line")

    flood = hg.load_flood_table(root)
    df = hg.build_model_frame(flood, rp(nri_path))
    devel, test = hg.split_frame(df)
    rungs = hg.resolve_ladder(devel)
    rung = next((r for r in rungs if r["rung"] == MODEL_RUNG and r["features"]), None)
    if rung is None:
        raise SystemExit(f"feature set '{MODEL_RUNG}' is unavailable in this data (rainfall columns missing?)")
    features = rung["features"]
    log(f"model: {MODEL_NAME}, {len(features)} features ({MODEL_RUNG}); dev {len(devel)} events, test {len(test)}")

    fit, model = fit_explorer_model(devel, test, features)

    # validation numbers for the explorer's own model (logistic regression only: fast)
    folds = hg.make_group_folds(devel[hg.TARGET], devel[hg.GROUP], repeats=cv_repeats, folds=cv_folds)
    ladder, _ = hg.feature_ladder(devel, folds, rungs, models=(MODEL_NAME,))
    pick = lambda name: ladder[(ladder["rung"] == name) & (ladder["model"] == MODEL_NAME)].iloc[0]
    last_rung = [r for r in rungs if r["features"] and r["kind"] in ("base", "add")][-1]["rung"]
    boot = hg.holdout_bootstrap(fit, test, n_boot=2000, models=[MODEL_NAME])
    bt = lambda metric: boot[boot["metric"] == metric].iloc[0]
    hs = hg.helene_sensitivity(fit, test, hl_start, hl_end, models=[MODEL_NAME])
    hs_ex = hs[hs["subset"] == "Excluding window"].iloc[0]

    # thresholds and counts for plain-language text
    # The target is built once in R with a training-years threshold; recover it from the table
    # (the largest damage among non-severe, no-death events) so the text can never drift.
    nonsev = df[(df["high_consequence"] == 0) & (df["total_deaths"] == 0)]
    threshold = float(nonsev["total_damage"].max()) if len(nonsev) else float("nan")

    counties_gj, stats = build_counties(ex_dir, df, rp(nri_path), hl_start, hl_end)
    stats_by_fips = {s["fips3"]: s["idx"] for s in stats}
    grid_block, grid_df, county_idx, latest = build_grid(ex_dir, df, stats, hl_start=hl_start)
    scenario = build_scenarios(devel, grid_df, stats, county_idx)
    events = build_events(df, fit, stats_by_fips, hl_start, hl_end)
    hill_meta = json.loads((ex_dir / "hillshade.json").read_text(encoding="utf-8"))
    hill_uri = "data:image/png;base64," + base64.b64encode((ex_dir / "hillshade.png").read_bytes()).decode()
    grid_meta = json.loads((ex_dir / "meta.json").read_text(encoding="utf-8")) if (ex_dir / "meta.json").exists() else {}

    d = pd.to_datetime(df["event_date"])
    hel_mask = (d >= pd.Timestamp(hl_start)) & (d <= pd.Timestamp(hl_end))
    n_dev_pos = int(devel[hg.TARGET].sum())
    dlon = float(grid_meta.get("dlon", 0.041666667))
    dlat = float(grid_meta.get("dlat", 0.041666667))

    data = {
        "meta": {
            "title": "Carolina HighGround explorer",
            "subtitle": "What-if map of flood-related storm severity in North Carolina",
            "generated": date.today().isoformat(), "data_end": latest,
            "hc_definition": HC_DEFINITION.format(thr=threshold),
            "n_events": int(len(df)), "n_dev": int(len(devel)), "n_test": int(len(test)),
            "n_dev_positives": n_dev_pos,
            "base_rate_dev": float(devel[hg.TARGET].mean()), "base_rate_test": float(test[hg.TARGET].mean()),
            "model": {
                "name": f"{MODEL_NAME}, {len(features)} features", "n_features": len(features),
                "feature_set": MODEL_RUNG,
                "cv_pr_auc": pick(MODEL_RUNG)["pr_auc"], "cv_pr_auc_sd": pick(MODEL_RUNG)["pr_auc_sd"],
                "cv_base_rate": pick(MODEL_RUNG)["base_rate"],
                "season_only_pr_auc": pick("Season only")["pr_auc"],
                "full_model_features": int(pick(last_rung)["n_features"]),
                "full_model_cv_pr_auc": pick(last_rung)["pr_auc"],
                "holdout_pr_auc": bt("pr_auc")["estimate"], "holdout_pr_lo": bt("pr_auc")["lo"],
                "holdout_pr_hi": bt("pr_auc")["hi"],
                "holdout_top10_capture": bt("top10_capture")["estimate"], "holdout_top10_lo": bt("top10_capture")["lo"],
                "holdout_top10_hi": bt("top10_capture")["hi"],
                "holdout_n": int(len(test)), "holdout_positives": int(test[hg.TARGET].sum()),
                "holdout_excl_helene_pr_auc": hs_ex["pr_auc"], "holdout_excl_helene_positives": int(hs_ex["n_positive"]),
                "helene_share_of_test_positives": hs_ex["share_test_positives_in_window"],
                "note": (f"This explorer uses the {len(features)}-feature model. The report's {int(pick(last_rung)['n_features'])}-feature model "
                         f"adds hydrology and tract vulnerability and scores {pick(last_rung)['pr_auc']:.3f} against "
                         f"{pick(MODEL_RUNG)['pr_auc']:.3f} here, a difference the data cannot separate."),
            },
            "helene": {
                "label": "Helene", "start": hl_start, "end": hl_end, "rain_window_note": HELENE_RAIN_WINDOW,
                "n_events": int(hel_mask.sum()), "n_deaths": int(df.loc[hel_mask, "total_deaths"].sum()),
                "damage": float(df.loc[hel_mask, "total_damage"].sum()),
            },
            "grid": {"dlon": dlon, "dlat": dlat, "west": grid_meta.get("west"), "east": grid_meta.get("east"),
                     "south": grid_meta.get("south"), "north": grid_meta.get("north"), "n": int(len(grid_df))},
            "sources": [
                {"name": "NOAA Storm Events Database (NCEI)", "note": "Flood-related events 2016-2026: deaths, damage, location, date."},
                {"name": "gridMET daily precipitation (4 km)", "note": "Storm rainfall, wettest day, prior-week rain."},
                {"name": "USGS 3DEP-derived DEM (62 m)", "note": "Elevation, slope, relief; height above stream and drainage area via WhiteboxTools."},
                {"name": "USGS NHD High Resolution", "note": "Distance to the nearest stream."},
                {"name": "USGS Annual NLCD 2023", "note": "Paved (impervious) surface."},
                {"name": "FEMA National Risk Index v1.20", "note": "County social vulnerability and population density."},
                {"name": "CDC/ATSDR Social Vulnerability Index 2022", "note": "Tract vulnerability (context only, not a model input)."},
                {"name": "U.S. Census Bureau", "note": "County and tract boundaries."},
            ],
            "limitations": [
                "Explanatory, not a forecast. Rainfall describes the storm itself, so the model estimates how severe a flood-related event is likely to be at a place, not whether flooding will happen.",
                f"The outcome is NOAA's reported record: {HC_DEFINITION.format(thr=threshold)}. Reporting differs by place, so some patterns may reflect who reports.",
                "Grid cells are about 4 km wide and values are taken at the cell center, so local conditions can differ.",
                f"Only {n_dev_pos} high-consequence events in 2016-2023 trained the model; small effects cannot be detected.",
                f"{hs_ex['share_test_positives_in_window'] * 100:.0f}% of the 2024-2026 test positives come from the Helene week, so holdout scores largely measure one storm.",
                "County values (population density, social vulnerability) are the same everywhere in a county.",
                "Places far from any reported event are extrapolations from the model.",
            ],
        },
        "features": build_features_block(model),
        "groups": [{"key": k, "label": v} for k, v in GROUPS],
        "model": model,
        "scenario": scenario,
        "grid": grid_block,
        "counties": counties_gj,
        "countyStats": stats,
        "events": events,
        "cities": build_cities(root),
        "hillshade": {"uri": hill_uri, "west": hill_meta["west"], "east": hill_meta["east"],
                      "south": hill_meta["south"], "north": hill_meta["north"]},
        "validation": build_validation(devel, rungs, ladder, rp("outs/tables/model_validation_summary.json")),
    }
    # fill grid bounds if the R step did not write them
    for k, v in (("west", "lon"), ("east", "lon"), ("south", "lat"), ("north", "lat")):
        if data["meta"]["grid"][k] is None:
            vals = [x for x in grid_block[v] if x is not None]
            half = (dlon if v == "lon" else dlat) / 2
            data["meta"]["grid"][k] = (min(vals) - half) if k in ("west", "south") else (max(vals) + half)

    # self-check: the formula applied to a held-out row matches the Python model
    row = test.iloc[0]
    py_p = float(hg.predict_calibrated(fit, MODEL_NAME, test.iloc[[0]])[0])
    js_p = score_with_export(model, {f: (None if pd.isna(row[f]) else float(row[f])) for f in features})
    assert abs(py_p - js_p) < 1e-4, f"exported formula disagrees with the fitted model: {py_p} vs {js_p}"

    payload = json.dumps(to_py(data), separators=(",", ":"), allow_nan=False)
    result = html.replace(PLACEHOLDER, "const DATA = " + payload + ";")
    out_path = rp(out)
    out_path.write_text(result, encoding="utf-8")
    if docs_copy:
        rp(docs_copy).write_text(result, encoding="utf-8")
    log(f"wrote {out_path} ({len(result) / 1e6:.2f} MB); grid {len(grid_df)} cells, {len(events)} events, "
        f"{len(stats)} counties; formula check {py_p:.5f} vs {js_p:.5f}; {time.time() - t0:.0f} s")
    return {"path": str(out_path), "bytes": len(result), "cells": int(len(grid_df)), "events": len(events)}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build the explorer from the project's model and data.")
    ap.add_argument("--project-dir", default=".")
    ap.add_argument("--template", default="src/content/explorer_template.html")
    ap.add_argument("--out", default="src/content/highground_explorer.html")
    ap.add_argument("--explorer-dir", default="data/derived/explorer")
    ap.add_argument("--nri-path", default="data/raw/nri/NRI_Table_Counties.csv")
    ap.add_argument("--helene-start", default="2024-09-24")
    ap.add_argument("--helene-end", default="2024-09-30")
    ap.add_argument("--cv-repeats", type=int, default=5)
    ap.add_argument("--cv-folds", type=int, default=5)
    ap.add_argument("--docs-copy", default=None, help="also write the explorer here (e.g. docs/explorer.html)")
    a = ap.parse_args(argv)
    build_explorer(a.project_dir, a.template, a.out, a.explorer_dir, a.nri_path, a.helene_start, a.helene_end,
                   a.cv_repeats, a.cv_folds, a.docs_copy)


if __name__ == "__main__":
    main()
