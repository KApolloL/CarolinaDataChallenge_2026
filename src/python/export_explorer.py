"""Regenerate the interactive risk explorer from the project's own model.

Usage (from anywhere):

    python src/python/export_explorer.py --project-dir <project root>

Reads the original template (src/legacy/minh/highground_explorer_original.html),
refits the explorer's logistic regression with `highground_ml` on the current
data, rebuilds POINTS and REAL_GRID, replaces the hard-coded numbers in the
explorer's prose with values computed here, and writes
src/content/highground_explorer.html.

REAL_GRID comes from data/derived/explorer_grid.csv, which
src/R/explorer_grid.R builds from the project rasters.

MODEL format (what the JS expects): coefficients are per standardized feature
and already include the Platt calibration (coef * scale, intercept * scale +
shift), exactly as src/legacy/minh/model_training.py exports. The JS computes
sigmoid(intercept + sum(coef * clip((x - mean) / std, -1.5, 1.5))).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import highground_ml as hg  # noqa: E402

POINT_KEYS = ["event_id", "event_date", "event_type", "region", "matched_county", "latitude", "longitude",
              "total_deaths", "total_damage", "high_consequence", "split"]
IDW_KEYS = ["slope_degrees", "elevation_m", "impervious_mean_250m", "distance_to_stream_m",
            "population_density", "SOVI_SCORE"]
COUNT_KEYS = ["nearby_minor_flood_count_25km", "nearby_severe_flood_count_25km"]


# ---- literal location and replacement ---------------------------------------------
def find_const(html, name):
    """Return (start, end) of the literal after `const NAME = ` (end excludes the ';')."""
    m = re.search(r"^const " + re.escape(name) + r" = ", html, re.M)
    if not m:
        raise ValueError(f"const {name} not found")
    start = m.end()
    opener = html[start]
    closer = {"[": "]", "{": "}"}[opener]
    depth, i, in_str, esc = 0, start, False, False
    while i < len(html):
        ch = html[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                end = i + 1
                break
        i += 1
    else:
        raise ValueError(f"unterminated literal for {name}")
    if html[end] != ";":
        raise ValueError(f"expected ';' after {name} literal, got {html[end:end + 20]!r}")
    return start, end


def replace_const(html, name, literal):
    s, e = find_const(html, name)
    return html[:s] + literal + html[e:]


def replace_once(html, old, new, label):
    if html.count(old) != 1:
        raise ValueError(f"text to replace not found exactly once ({label})")
    return html.replace(old, new)


# ---- model --------------------------------------------------------------------------
def fit_logistic(devel, test, features):
    fit = hg.fit_holdout(devel, test, features, models=("Logistic regression",))
    name = "Logistic regression"
    scale, shift = fit["preds"][name]["scale"], fit["preds"][name]["shift"]
    model = fit["fitted"][name]
    export = {
        "features": list(features),
        "coefficients": {f: float(c * scale) for f, c in zip(features, model.coef_[0])},
        "intercept": float(model.intercept_[0] * scale + shift),
        "medians": {f: float(m) for f, m in zip(features, fit["imputer"].statistics_)},
        "means": {f: float(m) for f, m in zip(features, fit["scaler"].mean_)},
        "stds": {f: float(s) for f, s in zip(features, fit["scaler"].scale_)},
    }
    return fit, export


def model_prob(model, values, z_clip=1.5):
    """Same math as computeProbAndContrib in the explorer."""
    z = model["intercept"]
    for f in model["features"]:
        s = (values[f] - model["means"][f]) / model["stds"][f]
        z += model["coefficients"][f] * max(-z_clip, min(z_clip, s))
    return 1 / (1 + np.exp(-z))


# ---- points and grid -----------------------------------------------------------------
def build_points(df, model):
    keep = POINT_KEYS + IDW_KEYS + COUNT_KEYS
    pts = df[keep].copy()
    n_filled = {}   # counts of missing values left as null (the patched IDW skips them)
    for f in IDW_KEYS:
        n = int(pts[f].isna().sum())
        if n:
            n_filled[f] = n
    pts["event_date"] = pts["event_date"].astype(str).str[:10]
    pts = pts.sort_values(["event_date", "event_id"], kind="stable")
    recs = []
    for r in pts.to_dict("records"):
        rec = {}
        for k in keep:
            v = r[k]
            if k in ("event_id", "high_consequence", "total_deaths", "nearby_minor_flood_count_25km",
                     "nearby_severe_flood_count_25km"):
                v = int(v) if k != "total_deaths" else int(v)
            elif k in ("latitude", "longitude"):
                v = round(float(v), 5)
            elif k == "total_damage":
                v = float(v)
            elif k in IDW_KEYS:
                v = None if pd.isna(v) else round(float(v), 3)
            else:
                v = str(v)
            rec[k] = v
        recs.append(rec)
    return recs, n_filled


def build_grid(grid_csv, template_html):
    s, e = find_const(template_html, "REAL_GRID")
    old = json.loads(template_html[s:e])
    g = pd.read_csv(grid_csv)
    old_keys = {(c["i"], c["j"]) for c in old}
    if old_keys != set(zip(g["i"], g["j"])):
        raise ValueError("explorer_grid.csv cells do not match the template's REAL_GRID cells")
    cols = ["elevation_m_real", "slope_degrees_real", "impervious_real", "local_relief_5km"]
    out = []
    for r in g.sort_values(["i", "j"]).to_dict("records"):
        cell = {"i": int(r["i"]), "j": int(r["j"]), "lat": float(r["lat"]), "lon": float(r["lon"])}
        for c in cols:
            cell[c] = None if pd.isna(r[c]) else round(float(r[c]), 3)
        out.append(cell)
    # keep the template's cell order
    order = {(c["i"], c["j"]): k for k, c in enumerate(old)}
    out.sort(key=lambda c: order[(c["i"], c["j"])])
    return out


# ---- numbers quoted in the prose -------------------------------------------------------
def compute_claims(df, devel, test, features, fit, model, rungs, cv_repeats, cv_folds):
    claims = {}
    # impervious decile vs overall
    d = df.dropna(subset=["impervious_mean_250m"])
    cut = d["impervious_mean_250m"].quantile(0.90)
    top = d[d["impervious_mean_250m"] >= cut]
    claims["imp_top_rate"] = float(top[hg.TARGET].mean())
    claims["imp_all_rate"] = float(d[hg.TARGET].mean())
    claims["imp_top_n"], claims["imp_all_n"] = len(top), len(d)

    # CV: logistic vs random forest on the explorer's own features
    folds = hg.make_group_folds(devel[hg.TARGET], devel[hg.GROUP], cv_repeats, cv_folds)
    cv, _ = hg.compare_models(devel, features, folds, models=("Logistic regression", "Random forest"))
    row = cv.set_index("model")
    claims["cv_lr"] = float(row.loc["Logistic regression", "pr_auc"])
    claims["cv_rf"] = float(row.loc["Random forest", "pr_auc"])
    claims["cv_base"] = float(devel[hg.TARGET].mean())
    claims["cv_n"] = f"{cv_repeats}x{cv_folds}"
    claims["holdout_pr"] = float(fit["holdout"].iloc[0]["pr_auc"])
    claims["holdout_base"] = float(fit["test_base_rate"])
    claims["n_dev"], claims["n_test"] = len(devel), len(test)
    claims["dev_years"] = (int(devel["event_year"].min()), int(devel["event_year"].max()))
    claims["test_years"] = (int(test["event_year"].min()), int(test["event_year"].max()))
    claims["primary_n"] = len(hg.primary_features(rungs)[0])

    c = model["coefficients"]
    claims["coef"] = c
    claims["tropical"] = hg.tropical_flag_check(devel, features)
    inv = hg.season_inversion(fit, df, models=("Logistic regression",))
    claims["inversion"] = inv.iloc[0].to_dict() if len(inv) else None
    return claims


def fmt_pct(x, d=1):
    return f"{100 * x:.{d}f}%"


def edit_prose(html, cl):
    changes = []
    c = cl["coef"]

    # 1. imperviousness sentence
    old = ("the most impervious 10% of historical events had only a 1.1% high-consequence rate, "
           "versus 8.3% statewide.")
    new = (f"the most impervious 10% of the {cl['imp_all_n']:,} historical events here (those with a measured "
           f"imperviousness) had a {fmt_pct(cl['imp_top_rate'])} high-consequence rate, versus "
           f"{fmt_pct(cl['imp_all_rate'])} for all of them.")
    html = replace_once(html, old, new, "impervious claim")
    changes.append((old, new))

    # 2. flood-history sentence
    old = ("more <em>minor</em> flood history nearby lowers predicted risk (resilience/preparedness), while "
           "more <em>severe</em> flood history clustered nearby raises it (compounding vulnerability) — "
           "confirmed as opposite-signed effects when fit separately.")
    mi, se = c["nearby_minor_flood_count_25km"], c["nearby_severe_flood_count_25km"]
    if mi < 0 < se:
        body = ("more <em>minor</em> flood history nearby lowers predicted risk (resilience/preparedness), while "
                "more <em>severe</em> flood history clustered nearby raises it (compounding vulnerability)")
    else:
        body = "the fitted effects of minor and severe flood history do not have opposite signs in the current fit"
    small = " The severe-history effect is small." if abs(se) < 0.15 else ""
    new = (f"{body}. Fitted log-odds per standard deviation: minor {mi:+.2f}, severe {se:+.2f}.{small}")
    html = replace_once(html, old, new, "flood history claim")
    changes.append((old, new))

    # 3. relief + tropical sentences
    old = ("Surrounding terrain relief (5km) is included too, though its average linear effect is small once "
           "slope/elevation are already in the model — tested directly, including a relief×tropical "
           "interaction term, which came back negligible given the data. Tested honestly: "
           "<code>is_tropical_event</code> itself carries essentially zero weight once "
           "<code>event_month</code> is included — the model gets its seasonal signal from month alone.")
    tr = cl["tropical"]
    rl = c["local_relief_5km"]
    new = (f"Surrounding terrain relief (5km) is included too; its fitted effect is {rl:+.2f} log-odds per "
           f"standard deviation. The model's seasonal signal comes from <code>event_month</code> "
           f"({c['event_month']:+.2f}) and <code>peak_hurricane_season</code> ({c['peak_hurricane_season']:+.2f}); "
           f"<code>is_tropical_event</code> is not a model input (it has {tr['flag_distinct_values']} distinct "
           f"value in the development events, so it carries no information there).")
    html = replace_once(html, old, new, "relief/tropical claim")
    changes.append((old, new))

    # 4. bottom disclaimer
    old = ("11-feature simplified linear model (now using an explicit \"peak hurricane season\" flag alongside "
           "month, which improved both accuracy and made storm-scenario comparisons mathematically guaranteed to "
           "be consistent — hurricane season always scores at least as risky as typical months, by construction, "
           "everywhere). Chosen for full client-side transparency; a compared Random Forest scores higher "
           "(PR-AUC ~0.22 vs ~0.20 in repeated cross-validation, both models now include the same feature) and "
           "is the model reported as this project's primary result. Not an operational flood warning.")
    if c["event_month"] > 0 and c["peak_hurricane_season"] > 0:
        season = ("Because both the month and peak-hurricane-season coefficients are positive, a hurricane "
                  "scenario (September, flag on) scores at least as risky as a typical summer storm (July, flag off) "
                  "at the same place, by construction")
    else:
        season = ("The month and peak-hurricane-season coefficients do not both point the same way, so a hurricane "
                  "scenario is not guaranteed to score higher than a typical storm at the same place")
    inv = cl["inversion"]
    if inv:
        season += (f"; across the {int(inv['n_events'])} mountain flood events, mean predicted risk is "
                   f"{fmt_pct(inv['mean_typical'])} for the typical scenario and {fmt_pct(inv['mean_hurricane'])} "
                   f"for the hurricane scenario ({fmt_pct(inv['share_hurricane_lower'], 0)} of events score lower "
                   f"under the hurricane scenario)")
    season += "."
    cv_phrase = (f"In repeated grouped cross-validation ({cl['cv_n']}) on these same 11 features, PR-AUC is "
                 f"{cl['cv_lr']:.2f} for this logistic regression and {cl['cv_rf']:.2f} for a random forest "
                 f"(no-skill {cl['cv_base']:.2f}); on the {cl['n_test']} holdout events from "
                 f"{cl['test_years'][0]}-{cl['test_years'][1]} this model scores PR-AUC {cl['holdout_pr']:.2f} "
                 f"(no-skill {cl['holdout_base']:.2f}).")
    new = (f"11-feature simplified linear model: class-weighted logistic regression fit on {cl['n_dev']} flood "
           f"events from {cl['dev_years'][0]}-{cl['dev_years'][1]}, with Platt calibration folded into the "
           f"coefficients. {season} Chosen for full client-side transparency. {cv_phrase} The full report's "
           f"primary model uses {cl['primary_n']} features. Not an operational flood warning.")
    html = replace_once(html, old, new, "model disclaimer")
    changes.append((old, new))

    # 5. Helene panel: relief effect
    old = "but its average linear effect is small"
    new = f"but its fitted linear effect is {rl:+.2f} log-odds per standard deviation"
    html = replace_once(html, old, new, "relief effect in Helene note")
    changes.append((old, new))

    # 6. stale numbers in a JS comment
    old = ("(e.g. downtown Charlotte's 80% imperviousness, 3.6 std devs out) back toward what\n"
           "                     // the real empirical rate for that subgroup actually is (~1%), instead of overshooting to ~0.2%.")
    new = ("(e.g. an 80% imperviousness value far above the training mean) back toward what\n"
           "                     // the empirical rate for that subgroup actually is, instead of overshooting.")
    if old in html:
        html = html.replace(old, new)
        changes.append((old, new))
    return html, changes


# ---- behavior patches to the template's JavaScript -------------------------------------
def patch_js(html):
    """Two explicit fixes to the template's JS (each asserted to match exactly once).

    1. IDW interpolation skips neighbors whose value for a feature is null, so no value
       has to be invented for events with missing terrain.
    2. The nearby-flood counts use only events in the 3 years before the latest event in
       POINTS, matching how the training feature is built (events in the prior 3 years),
       instead of counting every event since 2016.
    """
    old = """  IDW_FEATURES.forEach(f => {
    result[f] = nearest.reduce((sum, n, i) => sum + n.p[f] * weights[i], 0) / wSum;
  });"""
    new = """  IDW_FEATURES.forEach(f => {
    // Neighbors with a missing value for this feature are skipped; weights renormalize.
    let num = 0, den = 0;
    nearest.forEach((n, i) => { const v = n.p[f]; if (v != null) { num += v * weights[i]; den += weights[i]; } });
    result[f] = den > 0 ? num / den : MODEL.medians[f];
  });"""
    html = replace_once(html, old, new, "IDW null handling")

    old = """function directSplitFloodCounts(lat, lon, radiusKm) {
  let minor = 0, severe = 0;
  for (const p of POINTS) {
    if (haversineKm(lat, lon, p.latitude, p.longitude) <= radiusKm) {"""
    new = """// Training counted earlier events within 25 km in the previous 3 years, so serving counts the
// 3 years ending at the latest event in the data (not every event since 2016).
const LATEST_EVENT_MS = Math.max(...POINTS.map(p => Date.parse(p.event_date)));
const HISTORY_WINDOW_MS = 3 * 365 * 24 * 3600 * 1000;
function directSplitFloodCounts(lat, lon, radiusKm) {
  let minor = 0, severe = 0;
  for (const p of POINTS) {
    if (Date.parse(p.event_date) < LATEST_EVENT_MS - HISTORY_WINDOW_MS) continue;
    if (haversineKm(lat, lon, p.latitude, p.longitude) <= radiusKm) {"""
    html = replace_once(html, old, new, "3-year flood-count window")
    return html


# ---- main ------------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description="Regenerate src/content/highground_explorer.html from the project's model.")
    ap.add_argument("--project-dir", default=".")
    ap.add_argument("--template", default="src/legacy/minh/highground_explorer_original.html")
    ap.add_argument("--grid-csv", default="data/derived/explorer_grid.csv")
    ap.add_argument("--nri-path", default="data/raw/nri/NRI_Table_Counties.csv")
    ap.add_argument("--out", default="src/content/highground_explorer.html")
    ap.add_argument("--cv-repeats", type=int, default=5)
    ap.add_argument("--cv-folds", type=int, default=5)
    a = ap.parse_args(argv)
    root = Path(a.project_dir).resolve()
    rp = lambda p: Path(p) if Path(p).is_absolute() else root / p

    html = rp(a.template).read_text(encoding="utf-8")
    ms, me = find_const(html, "MODEL")
    features = json.loads(html[ms:me])["features"]

    flood = hg.load_flood_table(root)
    df = hg.build_model_frame(flood, rp(a.nri_path))
    devel, test = hg.split_frame(df)
    missing = [f for f in features if f not in df.columns]
    if missing:
        raise SystemExit(f"explorer features missing from the data: {missing}")
    rungs = hg.resolve_ladder(devel)

    fit, model = fit_logistic(devel, test, features)
    points, filled = build_points(df, model)
    grid = build_grid(rp(a.grid_csv), html)
    claims = compute_claims(df, devel, test, features, fit, model, rungs, a.cv_repeats, a.cv_folds)

    html, changes = edit_prose(html, claims)
    html = patch_js(html)
    html = replace_const(html, "MODEL", json.dumps(model, indent=2))
    html = replace_const(html, "POINTS", json.dumps(points, separators=(",", ":")))
    html = replace_const(html, "REAL_GRID", json.dumps(grid))
    out = rp(a.out)
    out.write_text(html, encoding="utf-8")

    # ---- report ----
    print(f"Wrote {out} ({out.stat().st_size / 1e6:.2f} MB)")
    print(f"POINTS: {len(points)}; missing values left as null (IDW skips them): {filled}")
    print(f"REAL_GRID: {len(grid)} cells; non-null elevation {sum(c['elevation_m_real'] is not None for c in grid)}, "
          f"slope {sum(c['slope_degrees_real'] is not None for c in grid)}, "
          f"impervious {sum(c['impervious_real'] is not None for c in grid)}, "
          f"relief {sum(c['local_relief_5km'] is not None for c in grid)}")
    print("MODEL intercept:", model["intercept"])
    for f in features:
        print(f"  {f:34s} coef {model['coefficients'][f]:+.4f}  median {model['medians'][f]:.3f}  "
              f"mean {model['means'][f]:.3f}  std {model['stds'][f]:.3f}")
    print("Claims:", {k: v for k, v in claims.items() if k not in ("coef",)})
    print("Prose edits:", len(changes))
    for old, new in changes:
        print("  OLD:", old[:200].replace("\n", " "))
        print("  NEW:", new[:600].replace("\n", " "))


if __name__ == "__main__":
    main()
