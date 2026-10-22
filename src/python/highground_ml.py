"""Carolina HighGround modeling helpers.

Used two ways:

* From the Quarto report (`src/_modeling.qmd`), which imports this file as
  `import highground_ml as hg` and calls the functions chunk by chunk.
* From the command line, which runs the same analyses on the exported model
  table and writes CSVs to `outs/tables/model_*.csv`:

      python src/python/highground_ml.py --project-dir <project root>

Conventions (same as the rest of the project): split by the `split` column,
group cross-validation by `episode_id`, never use outcome columns as
predictors, keep spatial NAs as missing (median imputation is fit on training
rows only), and only flood events with coordinates are modeled.
"""

from __future__ import annotations

import argparse
import math
import os
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingClassifier, RandomForestClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, roc_auc_score
from sklearn.model_selection import StratifiedGroupKFold, StratifiedKFold, cross_val_predict
from sklearn.neighbors import BallTree
from sklearn.preprocessing import StandardScaler

TARGET = "high_consequence"
GROUP = "episode_id"
REGION_PREFIX = "region_is_"

# ---- Feature groups (the "ladder") ------------------------------------------
SEASON = ["event_month", "peak_hurricane_season"]
PLACE = ["slope_degrees", "elevation_m", "impervious_mean_250m", "distance_to_stream_m", "local_relief_5km"]
PEOPLE = ["population_density", "SOVI_SCORE"]
HISTORY = ["nearby_minor_flood_count_25km", "nearby_severe_flood_count_25km"]
RAINFALL = ["rain_event_total_mm", "rain_max_1day_mm", "rain_antecedent_7d_mm"]
HYDROLOGY = ["hand_m", "log_drainage_area_km2"]
TRACT_SVI = ["svi_rpl_themes", "svi_rpl_theme1", "svi_rpl_theme2", "svi_rpl_theme3", "svi_rpl_theme4"]

# (rung name, columns, kind). "base" starts the cumulative chain, "alone" is a
# side comparison that is not added to later rungs, "add" extends the chain.
LADDER_STEPS = [
    ("Season only", SEASON, "base"),
    ("Region only", "region", "alone"),
    ("+ Place", PLACE, "add"),
    ("+ People", PEOPLE, "add"),
    ("+ History", HISTORY, "add"),
    ("+ Rainfall", RAINFALL, "add"),
    ("+ Hydrology", HYDROLOGY, "add"),
    ("+ Tract SVI", TRACT_SVI, "add"),
]
BASELINE_RUNG = "Season only"

# ---- Models -------------------------------------------------------------------
# name -> (factory, needs standardized inputs)
MODELS = {
    "Logistic regression": (lambda: LogisticRegression(max_iter=2000, class_weight="balanced", C=0.5), True),
    "Random forest": (lambda: RandomForestClassifier(n_estimators=100, max_depth=6, class_weight="balanced",
                                                    min_samples_leaf=5, max_features="sqrt", random_state=42), False),
    "Gradient boosting": (lambda: HistGradientBoostingClassifier(max_depth=3, learning_rate=0.05, max_iter=300,
                                                                class_weight="balanced", random_state=42), False),
}


def make_model(name):
    """Return a fresh, unfitted estimator for one of the names in `MODELS`."""
    return MODELS[name][0]()


def needs_scaling(name):
    """True if the model in `MODELS` should see standardized features."""
    return MODELS[name][1]


# ---- Features -------------------------------------------------------------------
def build_model_frame(flood_df, nri_path, history_radius_km=25, history_window_years=3):
    """Add the Python-side features to the flood event table.

    Parameters
    ----------
    flood_df : DataFrame
        One row per flood event with coordinates. Needs latitude, longitude,
        event_date, event_month, county_fips3, region, split, episode_id and
        the target `high_consequence`.
    nri_path : path to FEMA NRI `NRI_Table_Counties.csv`.
    history_radius_km, history_window_years : flood-history window.

    Returns
    -------
    DataFrame sorted by event_date with: population_density and SOVI_SCORE
    (county NRI join), nearby_minor/severe_flood_count_25km (earlier flood
    events within the radius and window, split by outcome; only past events
    count), peak_hurricane_season (Aug-Oct), and one-hot region columns
    (`region_is_<name>`).
    """
    df = flood_df.copy()
    df["event_date"] = pd.to_datetime(df["event_date"])
    df[TARGET] = df[TARGET].astype(int)

    nri = pd.read_csv(nri_path, encoding="utf-8-sig",
                      usecols=["STCOFIPS", "STATEABBRV", "POPULATION", "AREA", "SOVI_SCORE"])
    nri = nri[nri["STATEABBRV"] == "NC"].copy()
    nri["population_density"] = nri["POPULATION"] / nri["AREA"]
    nri["county_fips3"] = nri["STCOFIPS"] % 1000
    df["county_fips3"] = pd.to_numeric(df["county_fips3"], errors="coerce")
    df = df.merge(nri[["county_fips3", "population_density", "SOVI_SCORE"]], on="county_fips3", how="left")

    df = df.sort_values("event_date", kind="stable").reset_index(drop=True)
    coords = np.radians(df[["latitude", "longitude"]].to_numpy(dtype=float))
    neighbors = BallTree(coords, metric="haversine").query_radius(coords, r=float(history_radius_km) / 6371.0)
    dates, label = df["event_date"].to_numpy(), df[TARGET].to_numpy()
    window = np.timedelta64(365 * int(history_window_years), "D")
    minor, severe = [], []
    for i, idx in enumerate(neighbors):
        past = (dates[idx] < dates[i]) & (dates[idx] >= dates[i] - window)
        minor.append(int(np.sum(past & (label[idx] == 0))))
        severe.append(int(np.sum(past & (label[idx] == 1))))
    df["nearby_minor_flood_count_25km"] = minor
    df["nearby_severe_flood_count_25km"] = severe

    df["peak_hurricane_season"] = df["event_month"].isin([8, 9, 10]).astype(int)

    for reg in sorted(df["region"].dropna().unique()):
        df[f"{REGION_PREFIX}{reg}"] = (df["region"] == reg).astype(int)
    return df


def split_frame(df):
    """Return (devel, test): train + validation years, and the test years."""
    devel = df[df["split"].isin(["train", "validation"])].reset_index(drop=True)
    test = df[df["split"] == "test"].reset_index(drop=True)
    return devel, test


def feature_availability(df, features):
    """Share of non-missing values and median for each feature."""
    return pd.DataFrame({
        "feature": list(features),
        "available_pct": [round(100 * df[f].notna().mean(), 1) for f in features],
        "median": [round(float(df[f].median()), 2) for f in features],
    })


def resolve_ladder(devel, steps=LADDER_STEPS):
    """Decide which ladder rungs can run on this data.

    A rung is skipped when any of its new columns is absent or entirely NA in
    the development rows. A skipped rung adds nothing to later rungs.

    Returns a list of dicts with keys: rung, added (columns this rung adds),
    features (full feature list for the rung, or None if skipped), status.
    """
    region_cols = sorted(c for c in devel.columns if c.startswith(REGION_PREFIX))
    chain, out = [], []
    for name, cols, kind in steps:
        cols = region_cols if cols == "region" else list(cols)
        missing = [c for c in cols if c not in devel.columns]
        empty = [c for c in cols if c in devel.columns and devel[c].isna().all()]
        if not cols or missing or empty:
            why = []
            if not cols:
                why.append("no columns")
            if missing:
                why.append("absent: " + ", ".join(missing))
            if empty:
                why.append("all NA: " + ", ".join(empty))
            out.append({"rung": name, "kind": kind, "added": cols, "features": None,
                        "status": "skipped (" + "; ".join(why) + ")"})
            continue
        if kind == "base":
            chain = list(cols)
            feats = list(chain)
        elif kind == "alone":
            feats = list(cols)
        else:
            chain = chain + cols
            feats = list(chain)
        out.append({"rung": name, "kind": kind, "added": cols, "features": feats, "status": "evaluated"})
    return out


def primary_features(rungs):
    """Feature list of the largest available cumulative rung (the primary model)."""
    chain = [r for r in rungs if r["features"] is not None and r["kind"] in ("base", "add")]
    return list(chain[-1]["features"]), chain[-1]["rung"]


# ---- Cross-validation -------------------------------------------------------------
def make_group_folds(y, groups, repeats=5, folds=5, seed_base=100):
    """Repeated StratifiedGroupKFold splits, fixed once so every model and
    feature set is scored on identical folds. Seeds are seed_base + rep.

    Returns a list of (rep, fold, train_idx, valid_idx).
    """
    y, groups = np.asarray(y), np.asarray(groups)
    dummy = np.zeros((len(y), 1))
    out = []
    for rep in range(int(repeats)):
        skf = StratifiedGroupKFold(n_splits=int(folds), shuffle=True, random_state=seed_base + rep)
        for k, (tr, va) in enumerate(skf.split(dummy, y, groups)):
            out.append((rep, k, tr, va))
    return out


def repeated_group_cv(model_name, X, y, fold_list):
    """Score one model on precomputed grouped folds.

    Median imputation (and scaling for logistic regression) is fit inside
    each training fold. Returns one row per fold: rep, fold, pr_auc, roc_auc,
    n_valid, n_valid_pos.
    """
    X = pd.DataFrame(X).reset_index(drop=True)
    y = pd.Series(np.asarray(y))
    rows = []
    for rep, k, tr, va in fold_list:
        imp = SimpleImputer(strategy="median", keep_empty_features=True).fit(X.iloc[tr])
        X_tr, X_va = imp.transform(X.iloc[tr]), imp.transform(X.iloc[va])
        if needs_scaling(model_name):
            sc = StandardScaler().fit(X_tr)
            X_tr, X_va = sc.transform(X_tr), sc.transform(X_va)
        p = make_model(model_name).fit(X_tr, y.iloc[tr]).predict_proba(X_va)[:, 1]
        rows.append({"rep": rep, "fold": k,
                     "pr_auc": average_precision_score(y.iloc[va], p),
                     "roc_auc": roc_auc_score(y.iloc[va], p),
                     "n_valid": len(va), "n_valid_pos": int(y.iloc[va].sum())})
    return pd.DataFrame(rows)


def _cv_cached(cache, model_name, devel, features, fold_list):
    key = (model_name, tuple(features))
    if cache is not None and key in cache:
        return cache[key]
    res = repeated_group_cv(model_name, devel[features], devel[TARGET], fold_list)
    if cache is not None:
        cache[key] = res
    return res


def compare_models(devel, features, fold_list, models=tuple(MODELS), cache=None):
    """Cross-validate several models on one feature set.

    Returns (cv_results, fold_scores). cv_results has one row per model plus
    a "No-skill baseline" row (PR-AUC = share of positives, ROC-AUC = 0.5),
    with columns model, pr_auc, pr_auc_sd, roc_auc, roc_auc_sd, n_folds.
    SDs are across folds (ddof=0). fold_scores is long format with a model
    column.
    """
    rows, folds_long = [], []
    for name in models:
        f = _cv_cached(cache, name, devel, features, fold_list)
        folds_long.append(f.assign(model=name))
        rows.append({"model": name, "pr_auc": f["pr_auc"].mean(), "pr_auc_sd": f["pr_auc"].std(ddof=0),
                     "roc_auc": f["roc_auc"].mean(), "roc_auc_sd": f["roc_auc"].std(ddof=0), "n_folds": len(f)})
    rows.append({"model": "No-skill baseline", "pr_auc": float(devel[TARGET].mean()), "pr_auc_sd": np.nan,
                 "roc_auc": 0.5, "roc_auc_sd": np.nan, "n_folds": np.nan})
    return pd.DataFrame(rows), pd.concat(folds_long, ignore_index=True)


def best_model(cv_results):
    """Row (pandas Series) of the model with the highest mean CV PR-AUC."""
    real = cv_results[cv_results["model"] != "No-skill baseline"]
    return real.sort_values("pr_auc", ascending=False).iloc[0]


def _paired(diff):
    """Mean, approximate 95% interval and share > 0 of fold-wise differences."""
    diff = np.asarray(diff, dtype=float)
    n = len(diff)
    m = float(diff.mean())
    half = 1.96 * float(diff.std(ddof=1)) / math.sqrt(n) if n > 1 else np.nan
    return m, m - half, m + half, float(np.mean(diff > 0))


def feature_ladder(devel, fold_list, rungs=None, models=("Random forest", "Logistic regression"), cache=None):
    """Score each ladder rung with identical folds for each model.

    Paired comparisons: for each fold, PR-AUC of the rung minus PR-AUC of
    "Season only" (and minus the previous cumulative rung) on the same fold.
    The interval is mean +/- 1.96 * sd / sqrt(n_folds). Folds from repeated
    CV share training rows (and repeats reuse the same events), so they are
    not independent; treat the interval as approximate and probably too
    narrow.

    Returns (ladder, fold_scores). ladder has one row per rung x model.
    """
    if rungs is None:
        rungs = resolve_ladder(devel)
    base_rate = float(devel[TARGET].mean())
    scores = {}
    for r in rungs:
        if r["features"] is None:
            continue
        for m in models:
            scores[(r["rung"], m)] = _cv_cached(cache, m, devel, r["features"], fold_list)

    rows, prev_chain = [], None
    for r in rungs:
        for m in models:
            row = {"rung": r["rung"], "model": m, "status": r["status"],
                   "n_features": len(r["features"]) if r["features"] else 0,
                   "features_added": ", ".join(r["added"]), "base_rate": base_rate}
            if r["features"] is None:
                rows.append(row)
                continue
            f = scores[(r["rung"], m)]
            row.update({"pr_auc": f["pr_auc"].mean(), "pr_auc_sd": f["pr_auc"].std(ddof=0),
                        "roc_auc": f["roc_auc"].mean(), "roc_auc_sd": f["roc_auc"].std(ddof=0),
                        "n_folds": len(f)})
            base = scores.get((BASELINE_RUNG, m))
            if base is not None and r["rung"] != BASELINE_RUNG:
                g, lo, hi, share = _paired(f["pr_auc"].to_numpy() - base["pr_auc"].to_numpy())
                row.update({"pr_gain_vs_season": g, "pr_gain_vs_season_lo": lo, "pr_gain_vs_season_hi": hi,
                            "share_folds_beat_season": share})
            if r["kind"] == "add" and prev_chain is not None:
                pf = scores[(prev_chain, m)]
                g, lo, hi, _ = _paired(f["pr_auc"].to_numpy() - pf["pr_auc"].to_numpy())
                row.update({"previous_rung": prev_chain, "pr_gain_vs_previous": g,
                            "pr_gain_vs_previous_lo": lo, "pr_gain_vs_previous_hi": hi})
            rows.append(row)
        if r["features"] is not None and r["kind"] in ("base", "add"):
            prev_chain = r["rung"]

    ladder = pd.DataFrame(rows)
    cols = ["rung", "model", "status", "n_features", "features_added", "pr_auc", "pr_auc_sd", "roc_auc",
            "roc_auc_sd", "n_folds", "base_rate", "pr_gain_vs_season", "pr_gain_vs_season_lo",
            "pr_gain_vs_season_hi", "share_folds_beat_season", "previous_rung", "pr_gain_vs_previous",
            "pr_gain_vs_previous_lo", "pr_gain_vs_previous_hi"]
    for c in cols:
        if c not in ladder:
            ladder[c] = np.nan
    ladder["previous_rung"] = ladder["previous_rung"].fillna("").astype(str)  # keep a plain text column for R
    fold_scores = pd.concat([v.assign(rung=k[0], model=k[1]) for k, v in scores.items()], ignore_index=True)
    return ladder[cols], fold_scores


# ---- Calibration ---------------------------------------------------------------
def logit(p, eps=1e-6):
    """Log-odds with clipping so 0 and 1 stay finite."""
    p = np.clip(p, eps, 1 - eps)
    return np.log(p / (1 - p))


def platt(oof_raw, y_true):
    """Fit Platt scaling on raw scores; returns (scale, shift) on the logit scale."""
    m = LogisticRegression().fit(logit(np.asarray(oof_raw)).reshape(-1, 1), y_true)
    return float(m.coef_[0][0]), float(m.intercept_[0])


def calibrate(raw, scale, shift):
    """Apply Platt scaling from `platt` to raw scores."""
    return 1 / (1 + np.exp(-(scale * logit(np.asarray(raw)) + shift)))


# ---- Ranking metrics -------------------------------------------------------------
def capture_metrics(y_true, score, shares=(0.10, 0.20)):
    """Share of positives caught, and precision, among the top `share` of
    predicted risk. Top k = ceil(share * n) events; ties broken by row order.
    """
    y = np.asarray(y_true)
    order = np.argsort(-np.asarray(score), kind="stable")
    n, pos = len(y), y.sum()
    out = {}
    for s in shares:
        k = max(1, int(math.ceil(s * n)))
        hit = y[order[:k]].sum()
        tag = f"top{int(round(s * 100))}"
        out[f"{tag}_capture"] = float(hit / pos) if pos > 0 else np.nan
        out[f"{tag}_precision"] = float(hit / k)
    return out


def score_metrics(y_true, score):
    """PR-AUC, ROC-AUC, and capture metrics for one set of predictions."""
    y = np.asarray(y_true)
    has_both = 0 < y.sum() < len(y)
    out = {"pr_auc": average_precision_score(y, score) if y.sum() > 0 else np.nan,
           "roc_auc": roc_auc_score(y, score) if has_both else np.nan}
    out.update(capture_metrics(y, score))
    return out


# ---- Final fit and holdout ---------------------------------------------------------
def fit_holdout(devel, test, features, models=tuple(MODELS), inner_seed=42):
    """Fit each model on all development years and score the holdout years.

    Imputer and scaler are fit on development rows. Platt scaling is fit on
    5-fold out-of-fold predictions within the development rows (not the
    in-bag ones).

    Returns a dict with keys: fitted (name -> model), preds (name -> dict of
    raw, cal, scale, shift), holdout (DataFrame: model, pr_auc, roc_auc,
    mean_predicted, top10/top20 capture and precision), imputer, scaler,
    X_dev_i, X_test_i, y_dev, y_test, test_base_rate, features.
    """
    X_dev, y_dev = devel[features], devel[TARGET]
    X_test, y_test = test[features], test[TARGET]
    imputer = SimpleImputer(strategy="median", keep_empty_features=True).fit(X_dev)
    X_dev_i, X_test_i = imputer.transform(X_dev), imputer.transform(X_test)
    scaler = StandardScaler().fit(X_dev_i)
    inner_cv = StratifiedKFold(5, shuffle=True, random_state=inner_seed)

    fitted, preds = {}, {}
    for name in models:
        Xd = scaler.transform(X_dev_i) if needs_scaling(name) else X_dev_i
        Xt = scaler.transform(X_test_i) if needs_scaling(name) else X_test_i
        model = make_model(name).fit(Xd, y_dev)
        raw = model.predict_proba(Xt)[:, 1]
        oof = cross_val_predict(make_model(name), Xd, y_dev, cv=inner_cv, method="predict_proba")[:, 1]
        scale, shift = platt(oof, y_dev)
        fitted[name] = model
        preds[name] = {"raw": raw, "cal": calibrate(raw, scale, shift), "scale": scale, "shift": shift}

    rows = []
    for n, v in preds.items():
        row = {"model": n}
        row.update(score_metrics(y_test, v["cal"]))
        row["mean_predicted"] = float(v["cal"].mean())
        rows.append(row)
    holdout = pd.DataFrame(rows)[["model", "pr_auc", "roc_auc", "mean_predicted", "top10_capture",
                                  "top10_precision", "top20_capture", "top20_precision"]]
    return {"fitted": fitted, "preds": preds, "holdout": holdout, "imputer": imputer, "scaler": scaler,
            "X_dev_i": X_dev_i, "X_test_i": X_test_i, "y_dev": y_dev, "y_test": y_test,
            "test_base_rate": float(y_test.mean()), "features": list(features)}


def predict_calibrated(fit, name, X):
    """Calibrated risk from a `fit_holdout` result for new rows X (raw features)."""
    Xi = fit["imputer"].transform(X[fit["features"]])
    if needs_scaling(name):
        Xi = fit["scaler"].transform(Xi)
    raw = fit["fitted"][name].predict_proba(Xi)[:, 1]
    return calibrate(raw, fit["preds"][name]["scale"], fit["preds"][name]["shift"])


def calibration_check(fit, model="Random forest"):
    """Compare Platt scaling fit in-bag (on the model's own training
    predictions, the development bug) with the out-of-fold version used here.
    """
    m = fit["fitted"][model]
    Xd = fit["scaler"].transform(fit["X_dev_i"]) if needs_scaling(model) else fit["X_dev_i"]
    s, b = platt(m.predict_proba(Xd)[:, 1], fit["y_dev"])
    inbag = calibrate(fit["preds"][model]["raw"], s, b)
    oof = fit["preds"][model]["cal"]
    return pd.DataFrame({
        "calibration": ["In-bag (fit on the training predictions)", "Out-of-fold (used here)", "Observed test rate"],
        "mean_predicted": [float(inbag.mean()), float(oof.mean()), fit["test_base_rate"]],
        "max_predicted": [float(inbag.max()), float(oof.max()), np.nan],
    })


def holdout_bootstrap(fit, test, n_boot=2000, seed=2026, models=None):
    """Cluster bootstrap of holdout metrics by episode_id.

    Each resample draws whole episodes with replacement (storms are the unit
    of independence), recomputes PR-AUC, ROC-AUC and top-10%/top-20% capture
    and precision for every model on the same resample, and returns 95%
    percentile intervals. Resamples with no positives are dropped (count in
    n_boot_used).

    Returns a long DataFrame: model, metric, estimate, lo, hi, n_boot_used.
    """
    models = list(models or fit["preds"])
    y = test[TARGET].to_numpy()
    groups = test[GROUP].to_numpy()
    uniq = pd.unique(groups)
    members = [np.flatnonzero(groups == g) for g in uniq]
    rng = np.random.default_rng(seed)
    draws = {m: [] for m in models}
    for _ in range(int(n_boot)):
        pick = rng.integers(0, len(uniq), len(uniq))
        idx = np.concatenate([members[j] for j in pick])
        yb = y[idx]
        if yb.sum() == 0 or yb.sum() == len(yb):
            continue
        for m in models:
            draws[m].append(score_metrics(yb, fit["preds"][m]["cal"][idx]))
    rows = []
    for m in models:
        est = score_metrics(y, fit["preds"][m]["cal"])
        d = pd.DataFrame(draws[m])
        for metric in est:
            rows.append({"model": m, "metric": metric, "estimate": est[metric],
                         "lo": float(np.nanpercentile(d[metric], 2.5)),
                         "hi": float(np.nanpercentile(d[metric], 97.5)), "n_boot_used": len(d)})
    return pd.DataFrame(rows)


def helene_sensitivity(fit, test, start_date, end_date, models=None):
    """Holdout metrics with and without events dated inside [start, end].

    Returns one row per model x subset ("All test events", "Excluding
    window", "Window only") with n_events, n_positive, base_rate, pr_auc,
    roc_auc, capture metrics, lift (pr_auc / base_rate), and
    share_test_positives_in_window (same value on every row).
    """
    models = list(models or fit["preds"])
    d = pd.to_datetime(test["event_date"])
    in_win = ((d >= pd.Timestamp(start_date)) & (d <= pd.Timestamp(end_date))).to_numpy()
    y = test[TARGET].to_numpy()
    share = float(y[in_win].sum() / y.sum()) if y.sum() else np.nan
    subsets = {"All test events": np.ones_like(in_win), "Excluding window": ~in_win, "Window only": in_win}
    rows = []
    for m in models:
        for label, mask in subsets.items():
            mask = mask.astype(bool)
            ys = y[mask]
            row = {"model": m, "subset": label, "n_events": int(mask.sum()), "n_positive": int(ys.sum()),
                   "base_rate": float(ys.mean()) if mask.any() else np.nan}
            row.update(score_metrics(ys, fit["preds"][m]["cal"][mask]) if mask.any() else {})
            row["lift"] = row.get("pr_auc", np.nan) / row["base_rate"] if row["base_rate"] else np.nan
            row["share_test_positives_in_window"] = share
            rows.append(row)
    return pd.DataFrame(rows)


# ---- Diagnostics -------------------------------------------------------------------
def tree_use(rf, features):
    """How many trees of a fitted random forest split on each feature at least once."""
    used = [set(t.tree_.feature[t.tree_.feature >= 0]) for t in rf.estimators_]
    return pd.DataFrame({"feature": list(features),
                         "trees_using_feature": [sum(j in u for u in used) for j in range(len(features))]})


def tropical_flag_check(devel, features, flag="is_tropical_event"):
    """Refit the random forest with `flag` added and count trees that use it.

    Returns a dict: flag, n_trees, trees_using_flag, flag_events_devel (rows
    with flag == 1), flag_distinct_values. If the flag is constant, no tree
    can split on it.
    """
    if flag not in devel.columns:
        return {"flag": flag, "n_trees": np.nan, "trees_using_flag": np.nan,
                "flag_events_devel": np.nan, "flag_distinct_values": 0}
    feats = list(features) + [flag]
    X = SimpleImputer(strategy="median", keep_empty_features=True).fit_transform(devel[feats])
    rf = make_model("Random forest").fit(X, devel[TARGET])
    use = tree_use(rf, feats)
    return {"flag": flag, "n_trees": len(rf.estimators_),
            "trees_using_flag": int(use.loc[use["feature"] == flag, "trees_using_feature"].iloc[0]),
            "flag_events_devel": int((devel[flag] == 1).sum()),
            "flag_distinct_values": int(devel[flag].nunique(dropna=True))}


def season_inversion(fit, frame, region="mountains", typical=(7, 0), hurricane=(9, 1),
                     models=("Random forest", "Logistic regression")):
    """Score every flood event in `region` twice with all else equal: a
    "typical storm" (event_month, peak_hurricane_season = typical) and a
    "hurricane" (= hurricane). Reports the share of events where the
    hurricane scenario gets the lower calibrated risk.

    Returns a DataFrame: model, n_events, share_hurricane_lower,
    share_equal, mean_typical, mean_hurricane.
    """
    ev = frame[frame["region"] == region]
    rows = []
    if ev.empty or not {"event_month", "peak_hurricane_season"} <= set(fit["features"]):
        return pd.DataFrame(rows)
    a = ev.copy(); a["event_month"], a["peak_hurricane_season"] = typical
    b = ev.copy(); b["event_month"], b["peak_hurricane_season"] = hurricane
    for m in models:
        pa, pb = predict_calibrated(fit, m, a), predict_calibrated(fit, m, b)
        rows.append({"model": m, "n_events": len(ev), "share_hurricane_lower": float(np.mean(pb < pa)),
                     "share_equal": float(np.mean(pb == pa)),
                     "mean_typical": float(pa.mean()), "mean_hurricane": float(pb.mean())})
    return pd.DataFrame(rows)


def shap_values(rf, X, features):
    """SHAP values (positive class) and the mean |SHAP| ranking for a random forest."""
    import shap
    X_shap = pd.DataFrame(X, columns=list(features))
    sv = shap.TreeExplainer(rf).shap_values(X_shap)
    sv = sv[1] if isinstance(sv, list) else sv
    if sv.ndim == 3:
        sv = sv[:, :, 1]
    importance = (pd.Series(np.abs(sv).mean(axis=0), index=list(features))
                  .sort_values(ascending=False).rename("mean_abs_shap").reset_index()
                  .rename(columns={"index": "feature"}))
    return sv, X_shap, importance


# ---- Generalization checks ---------------------------------------------------------
# Named feature groups for the ablation (same columns as the ladder).
ABLATION_GROUPS = [("Season", SEASON), ("Place", PLACE), ("People", PEOPLE), ("History", HISTORY),
                   ("Rainfall", RAINFALL), ("Hydrology", HYDROLOGY), ("Tract SVI", TRACT_SVI)]
VALIDATION_MODELS = ("Logistic regression", "Random forest")


def _fit_predict(model_name, X_tr, y_tr, X_te):
    """Median imputation (and scaling when the model needs it) fit on the
    training rows only, then the model's predicted probability for X_te."""
    imp = SimpleImputer(strategy="median", keep_empty_features=True).fit(X_tr)
    A, B = imp.transform(X_tr), imp.transform(X_te)
    if needs_scaling(model_name):
        sc = StandardScaler().fit(A)
        A, B = sc.transform(A), sc.transform(B)
    return make_model(model_name).fit(A, np.asarray(y_tr)).predict_proba(B)[:, 1]


def _safe_scores(y, p):
    """(PR-AUC, ROC-AUC); NaN when the rows have no positives (PR-AUC) or
    only one class (ROC-AUC), instead of an error or a misleading 0."""
    y = np.asarray(y)
    pr = float(average_precision_score(y, p)) if y.sum() > 0 else np.nan
    roc = float(roc_auc_score(y, p)) if 0 < y.sum() < len(y) else np.nan
    return pr, roc


def ablation_sets(features):
    """Reduced feature sets for the order-sensitivity check.

    Returns a list of (set name, kind, columns): "Full model", "Rainfall
    only" and "Season + Rainfall" (kind "subset"; only when the rainfall
    columns are in `features`), and "Full minus <group>" for every group in
    `ABLATION_GROUPS` that has columns in `features` (kind "drop one").
    Column order follows `features`, so "Full minus Tract SVI" reuses the
    "+ Hydrology" ladder scores from the cache.
    """
    feats = list(features)
    present = [(g, [c for c in cols if c in feats]) for g, cols in ABLATION_GROUPS]
    present = [(g, cols) for g, cols in present if cols]
    have = dict(present)
    out = [("Full model", "full", feats)]
    if "Rainfall" in have:
        out.append(("Rainfall only", "subset", have["Rainfall"]))
        if "Season" in have:
            keep = set(have["Season"]) | set(have["Rainfall"])
            out.append(("Season + Rainfall", "subset", [c for c in feats if c in keep]))
    for g, cols in present:
        rest = [c for c in feats if c not in cols]
        if rest:
            out.append((f"Full minus {g}", "drop one", rest))
    return out


def ablation_study(devel, fold_list, features, models=VALIDATION_MODELS, cache=None):
    """Order-sensitivity check for the feature ladder.

    The ladder adds groups in a fixed order, so a group added early can take
    credit that a later group would also have earned. Here each reduced set
    from `ablation_sets` is scored on the same folds as the ladder, and the
    full model is compared with it fold by fold: gain = PR-AUC(full) -
    PR-AUC(reduced) on the same fold. The interval is mean +/- 1.96 * sd /
    sqrt(n_folds); folds from repeated CV share training rows and events, so
    they are not independent and the interval is approximate (probably too
    narrow). A "Full minus X" gain whose interval is above zero means the
    full model needs group X even with every other group present.

    Returns one row per set x model: set, kind, model, n_features,
    features, pr_auc, pr_auc_sd, roc_auc, full_pr_auc, gain_full_vs_set,
    gain_lo, gain_hi, share_folds_full_better, n_folds.
    """
    sets = ablation_sets(features)
    rows = []
    for m in models:
        full = _cv_cached(cache, m, devel, list(features), fold_list)
        for name, kind, cols in sets:
            f = _cv_cached(cache, m, devel, cols, fold_list)
            row = {"set": name, "kind": kind, "model": m, "n_features": len(cols), "features": ", ".join(cols),
                   "pr_auc": f["pr_auc"].mean(), "pr_auc_sd": f["pr_auc"].std(ddof=0),
                   "roc_auc": f["roc_auc"].mean(), "full_pr_auc": full["pr_auc"].mean(), "n_folds": len(f),
                   "gain_full_vs_set": np.nan, "gain_lo": np.nan, "gain_hi": np.nan,
                   "share_folds_full_better": np.nan}
            if kind != "full":
                g, lo, hi, share = _paired(full["pr_auc"].to_numpy() - f["pr_auc"].to_numpy())
                row.update({"gain_full_vs_set": g, "gain_lo": lo, "gain_hi": hi, "share_folds_full_better": share})
            rows.append(row)
    cols = ["set", "kind", "model", "n_features", "features", "pr_auc", "pr_auc_sd", "roc_auc", "full_pr_auc",
            "gain_full_vs_set", "gain_lo", "gain_hi", "share_folds_full_better", "n_folds"]
    return pd.DataFrame(rows)[cols]


def county_blocked_cv(devel, features, models=VALIDATION_MODELS, repeats=5, folds=10, seed_base=100,
                      group_col="county_fips3", purge_episodes=False):
    """Cross-validation that holds out whole counties.

    StratifiedGroupKFold with groups = county code, `folds` folds, repeated
    with seeds seed_base + rep (the project's cv_repeats seeds). Every event
    in a held-out county is scored by a model that never saw that county.
    Events without a county code share one group (-1). Storm episodes can
    span counties, so one storm can still sit on both sides of a split
    (in this data most high-consequence events belong to multi-county
    episodes). With purge_episodes=True, training rows whose episode_id
    also appears in the held-out counties are dropped, so neither the place
    nor the storm has been seen in training.

    Returns fold-level scores: model, rep, fold, n_train, n_valid,
    n_valid_pos, pr_auc, roc_auc (NaN for a fold with no positives).
    """
    y = devel[TARGET].to_numpy()
    groups = pd.to_numeric(devel[group_col], errors="coerce").fillna(-1).to_numpy()
    episodes = devel[GROUP].to_numpy()
    X = devel[list(features)].reset_index(drop=True)
    dummy = np.zeros((len(y), 1))
    splits = []
    for rep in range(int(repeats)):
        skf = StratifiedGroupKFold(n_splits=int(folds), shuffle=True, random_state=seed_base + rep)
        splits += [(rep, k, tr, va) for k, (tr, va) in enumerate(skf.split(dummy, y, groups))]
    rows = []
    for m in models:
        for rep, k, tr, va in splits:
            if purge_episodes:
                tr = tr[~np.isin(episodes[tr], episodes[va])]
            p = _fit_predict(m, X.iloc[tr], y[tr], X.iloc[va])
            pr, roc = _safe_scores(y[va], p)
            rows.append({"model": m, "rep": rep, "fold": k, "n_train": len(tr), "n_valid": len(va),
                         "n_valid_pos": int(y[va].sum()), "pr_auc": pr, "roc_auc": roc})
    return pd.DataFrame(rows)


def region_holdout(devel, features, models=VALIDATION_MODELS, region_col="region", purge_episodes=False):
    """Train on two regions (mountains, central, coastal) and test on the third.

    Uses only the rows passed in (the development years). Each region's
    PR-AUC should be read against that region's own base rate, which differs
    between regions. With purge_episodes=True, training rows from storm
    episodes that also reach the held-out region are dropped.

    Returns one row per held-out region x model: model, held_out, n_train,
    n, positives, base_rate, pr_auc, roc_auc (NaN if the region has no
    positives).
    """
    y = devel[TARGET].to_numpy()
    X = devel[list(features)].reset_index(drop=True)
    reg = devel[region_col].to_numpy()
    episodes = devel[GROUP].to_numpy()
    rows = []
    for m in models:
        for r in sorted(pd.unique(devel[region_col].dropna())):
            te = reg == r
            tr = ~te
            if purge_episodes:
                tr = tr & ~np.isin(episodes, episodes[te])
            p = _fit_predict(m, X[tr], y[tr], X[te])
            pr, roc = _safe_scores(y[te], p)
            rows.append({"model": m, "held_out": r, "n_train": int(tr.sum()), "n": int(te.sum()),
                         "positives": int(y[te].sum()),
                         "base_rate": float(y[te].mean()), "pr_auc": pr, "roc_auc": roc})
    return pd.DataFrame(rows)


def spatial_validation(devel, features, episode_folds, models=VALIDATION_MODELS, repeats=5, county_folds=10,
                       seed_base=100, cache=None):
    """Episode-grouped CV vs county-blocked CV vs region held out, side by side.

    The episode-grouped rows reuse the ladder's folds (and `cache`), so they
    match the scores reported elsewhere. County-blocked rows average the
    fold scores from `county_blocked_cv` over folds that have positives
    (n_folds_no_pos counts the folds recorded as NaN). Region rows come from
    `region_holdout`; a "Mean of regions" row averages the three regions
    (pr_sd is then the SD across regions). A model that scores much lower
    when whole counties or regions are held out is leaning on
    place-specific patterns rather than rules that transfer to new places.

    County and region schemes are run twice: as specified (only the place
    is held out) and "storm-purged" (training rows from any episode that
    reaches the held-out place are dropped too). Without the purge a storm
    that crossed county lines is partly in training, which can make the
    place-blocked score look better than the episode-grouped one.

    Returns a DataFrame: scheme, model, held_out, n, positives, base_rate,
    pr_auc, pr_sd, roc_auc, n_folds, n_folds_no_pos. Also returns the
    county fold scores (with a `purged` column) as the second element.
    """
    y = devel[TARGET]
    n, pos, base = len(devel), int(y.sum()), float(y.mean())
    n_ep_folds = len({k for _, k, _, _ in episode_folds})
    n_ep_reps = len({r for r, _, _, _ in episode_folds})
    county = pd.concat([
        county_blocked_cv(devel, features, models, repeats, county_folds, seed_base).assign(purged=False),
        county_blocked_cv(devel, features, models, repeats, county_folds, seed_base,
                          purge_episodes=True).assign(purged=True)], ignore_index=True)
    region = pd.concat([region_holdout(devel, features, models).assign(purged=False),
                        region_holdout(devel, features, models, purge_episodes=True).assign(purged=True)],
                       ignore_index=True)
    suffix = {False: "", True: ", storm-purged"}
    rows = []
    for m in models:
        e = _cv_cached(cache, m, devel, list(features), episode_folds)
        rows.append({"scheme": "Episode-grouped CV", "model": m,
                     "held_out": f"{n_ep_folds} folds of storm episodes x {n_ep_reps} repeats",
                     "n": n, "positives": pos, "base_rate": base, "pr_auc": e["pr_auc"].mean(),
                     "pr_sd": e["pr_auc"].std(ddof=0), "roc_auc": e["roc_auc"].mean(),
                     "n_folds": len(e), "n_folds_no_pos": int((e["n_valid_pos"] == 0).sum())})
        for purged in (False, True):
            c = county[(county["model"] == m) & (county["purged"] == purged)]
            rows.append({"scheme": "County-blocked CV" + suffix[purged], "model": m,
                         "held_out": f"{int(county_folds)} folds of counties x {int(repeats)} repeats",
                         "n": n, "positives": pos, "base_rate": base, "pr_auc": float(np.nanmean(c["pr_auc"])),
                         "pr_sd": float(np.nanstd(c["pr_auc"])), "roc_auc": float(np.nanmean(c["roc_auc"])),
                         "n_folds": len(c), "n_folds_no_pos": int(c["pr_auc"].isna().sum())})
        for purged in (False, True):
            g = region[(region["model"] == m) & (region["purged"] == purged)]
            sch = "Region held out" + suffix[purged]
            for _, r in g.iterrows():
                rows.append({"scheme": sch, "model": m, "held_out": r["held_out"], "n": r["n"],
                             "positives": r["positives"], "base_rate": r["base_rate"], "pr_auc": r["pr_auc"],
                             "pr_sd": np.nan, "roc_auc": r["roc_auc"], "n_folds": 1,
                             "n_folds_no_pos": int(r["positives"] == 0)})
            rows.append({"scheme": sch, "model": m, "held_out": "Mean of regions", "n": int(g["n"].sum()),
                         "positives": int(g["positives"].sum()), "base_rate": float(g["base_rate"].mean()),
                         "pr_auc": float(np.nanmean(g["pr_auc"])), "pr_sd": float(np.nanstd(g["pr_auc"])),
                         "roc_auc": float(np.nanmean(g["roc_auc"])), "n_folds": len(g),
                         "n_folds_no_pos": int(g["pr_auc"].isna().sum())})
    out = pd.DataFrame(rows)
    out["n"] = out["n"].astype(int)
    out["positives"] = out["positives"].astype(int)
    return out, county


def storm_span_summary(devel, county_fold_scores=None):
    """How much storms cross place boundaries in the development rows.

    Returns a dict: share_pos_multi_county and share_pos_multi_region
    (share of high-consequence events whose episode spans more than one
    county / region), and, if county fold scores from `spatial_validation`
    are given, mean_train_unpurged and mean_train_purged (average training
    rows per county-blocked fold without and with the storm purge).
    """
    pos = devel[TARGET] == 1
    span_c = devel.groupby(GROUP)["county_fips3"].transform("nunique")
    span_r = devel.groupby(GROUP)["region"].transform("nunique")
    out = {"share_pos_multi_county": float((span_c[pos] > 1).mean()) if pos.any() else np.nan,
           "share_pos_multi_region": float((span_r[pos] > 1).mean()) if pos.any() else np.nan}
    if county_fold_scores is not None and "purged" in county_fold_scores:
        cf = county_fold_scores
        out["mean_train_unpurged"] = float(cf.loc[~cf["purged"], "n_train"].mean())
        out["mean_train_purged"] = float(cf.loc[cf["purged"], "n_train"].mean())
    return out


def rolling_origin(frame, features, models=VALIDATION_MODELS, first_year=2019, last_year=2025, min_pos=5,
                   year_col="event_year"):
    """Temporal validation: for each year Y, fit on all events with
    year < Y and score the events of year Y.

    Imputation and scaling are fit on the training years inside each fit.
    The target is used as exported: its damage threshold was set once from
    the training-split years and is not recomputed per origin, so early
    origins use a label definition informed by a few later years. Years with
    fewer than `min_pos` positives are flagged (few_positives) because their
    PR-AUC rests on a handful of events. The pooled row scores the
    concatenated predictions of all test years together; each year comes
    from a different fit, so it mixes score scales and is a rough summary.

    Returns: label, year (NaN on the pooled row), model, n_train,
    train_positives, n, positives, base_rate, pr_auc, roc_auc,
    few_positives, min_pos.
    """
    yr = pd.to_numeric(frame[year_col], errors="coerce").to_numpy()
    y = frame[TARGET].to_numpy().astype(int)
    X = frame[list(features)].reset_index(drop=True)
    rows = []
    for m in models:
        ys, ps = [], []
        for Y in range(int(first_year), int(last_year) + 1):
            tr, te = yr < Y, yr == Y
            if te.sum() == 0 or y[tr].sum() == 0:
                continue
            p = _fit_predict(m, X[tr], y[tr], X[te])
            pr, roc = _safe_scores(y[te], p)
            ys.append(y[te]); ps.append(p)
            rows.append({"label": str(Y), "year": float(Y), "model": m, "n_train": int(tr.sum()),
                         "train_positives": int(y[tr].sum()), "n": int(te.sum()), "positives": int(y[te].sum()),
                         "base_rate": float(y[te].mean()), "pr_auc": pr, "roc_auc": roc,
                         "few_positives": bool(y[te].sum() < min_pos), "min_pos": int(min_pos)})
        if ys:
            yy, pp = np.concatenate(ys), np.concatenate(ps)
            pr, roc = _safe_scores(yy, pp)
            rows.append({"label": f"Pooled {first_year}-{last_year}", "year": np.nan, "model": m, "n_train": np.nan,
                         "train_positives": np.nan, "n": len(yy), "positives": int(yy.sum()),
                         "base_rate": float(yy.mean()), "pr_auc": pr, "roc_auc": roc,
                         "few_positives": bool(yy.sum() < min_pos), "min_pos": int(min_pos)})
    return pd.DataFrame(rows)


def permutation_test(devel, features, model="Logistic regression", n_perm=500, folds=5, seed=2026, fold_seed=100,
                     return_null=False):
    """Label-permutation test of the cross-validated PR-AUC.

    The observed score is the mean PR-AUC over one repeat of 5-fold
    episode-grouped CV (seed `fold_seed`). The null distribution shuffles
    the development labels `n_perm` times (fixed seed) and rescores each
    shuffle on the same folds. The shuffle is over single events, so it
    ignores episode structure (events from one storm share outcomes); a
    shuffle between whole episodes would give a somewhat wider null.
    Imputation and scaling do not depend on the labels, so they are fit
    once per fold. p-value = (1 + #null >= observed) / (1 + n_perm).

    Returns a one-row DataFrame: model, observed, null_mean, null_sd,
    null_p95, null_max, n_null_ge_observed, p_value, n_perm, n_folds. With
    return_null=True, returns (summary, array of null scores).
    """
    y = devel[TARGET].to_numpy().astype(int)
    X = devel[list(features)].reset_index(drop=True)
    fl = make_group_folds(y, devel[GROUP], repeats=1, folds=folds, seed_base=fold_seed)
    prepped = []
    for _, _, tr, va in fl:
        imp = SimpleImputer(strategy="median", keep_empty_features=True).fit(X.iloc[tr])
        A, B = imp.transform(X.iloc[tr]), imp.transform(X.iloc[va])
        if needs_scaling(model):
            sc = StandardScaler().fit(A)
            A, B = sc.transform(A), sc.transform(B)
        prepped.append((tr, va, A, B))

    def score(labels):
        s = []
        for tr, va, A, B in prepped:
            p = make_model(model).fit(A, labels[tr]).predict_proba(B)[:, 1]
            s.append(_safe_scores(labels[va], p)[0])
        return float(np.nanmean(s))

    observed = score(y)
    rng = np.random.default_rng(seed)
    null = np.array([score(rng.permutation(y)) for _ in range(int(n_perm))])
    out = pd.DataFrame([{"model": model, "observed": observed, "null_mean": float(null.mean()),
                         "null_sd": float(null.std(ddof=1)), "null_p95": float(np.percentile(null, 95)),
                         "null_max": float(null.max()), "n_null_ge_observed": int(np.sum(null >= observed)),
                         "p_value": float((1 + np.sum(null >= observed)) / (1 + len(null))),
                         "n_perm": int(n_perm), "n_folds": len(fl)}])
    return (out, null) if return_null else out


def calibration_deciles(devel, features, fold_list, model="Logistic regression", n_bins=10):
    """Reliability table from out-of-fold predictions, by risk decile.

    Uses the first repeat of `fold_list` (episode-grouped folds), so each
    development event gets exactly one out-of-fold prediction. Raw scores
    from a class-weighted model run high by design, so they are Platt-scaled
    by cross-fitting: the scaling applied to fold k is fit on the
    out-of-fold predictions of the other folds only. Events are then cut
    into `n_bins` equal-size groups by calibrated risk.

    Returns one row per decile (1 = lowest risk): decile, n, positives,
    mean_predicted, observed_rate, mean_raw, min_predicted, max_predicted.
    """
    y = devel[TARGET].to_numpy().astype(int)
    X = devel[list(features)].reset_index(drop=True)
    first = min(r for r, _, _, _ in fold_list)
    fl = [(tr, va) for r, _, tr, va in fold_list if r == first]
    raw = np.full(len(y), np.nan)
    fold_id = np.full(len(y), -1)
    for k, (tr, va) in enumerate(fl):
        raw[va] = _fit_predict(model, X.iloc[tr], y[tr], X.iloc[va])
        fold_id[va] = k
    cal = np.full(len(y), np.nan)
    for k in range(len(fl)):
        other = (fold_id != k) & (fold_id >= 0)
        s, b = platt(raw[other], y[other])
        cal[fold_id == k] = calibrate(raw[fold_id == k], s, b)
    ok = ~np.isnan(cal)
    d = pd.DataFrame({"y": y[ok], "raw": raw[ok], "cal": cal[ok]})
    d["decile"] = pd.qcut(d["cal"].rank(method="first"), int(n_bins), labels=False) + 1
    out = (d.groupby("decile").agg(n=("y", "size"), positives=("y", "sum"), mean_predicted=("cal", "mean"),
                                   observed_rate=("y", "mean"), mean_raw=("raw", "mean"),
                                   min_predicted=("cal", "min"), max_predicted=("cal", "max"))
           .reset_index())
    out["decile"] = out["decile"].astype(int)
    out["positives"] = out["positives"].astype(int)
    return out


def _json_clean(v):
    """Plain Python value for JSON: numpy scalars -> int/float/bool, NaN -> None."""
    if isinstance(v, (np.bool_, bool)):
        return bool(v)
    if isinstance(v, (np.integer,)):
        return int(v)
    if isinstance(v, (float, np.floating)):
        return None if not np.isfinite(v) else float(v)
    return v


def _records(df, cols):
    return [{c: _json_clean(r[c]) for c in cols} for r in df[cols].to_dict("records")]


def validation_summary(ladder, spatial, temporal, permutation, models=VALIDATION_MODELS):
    """Compact, JSON-friendly summary of the validation results (for the
    interactive explorer).

    Keys: ladder (group, model, gain, lo, hi: paired PR-AUC gain of each
    ladder rung over the rung before it), spatial (scheme, model, held_out,
    pr_auc, pr_sd, roc_auc), temporal (year, model, n, positives,
    base_rate, pr_auc, roc_auc, few_positives; year is null on the pooled
    row), permutation (observed, null_mean, null_p95, p_value, n_perm).
    Values are plain Python numbers, NaN as None.
    """
    lad = ladder[ladder["model"].isin(models) & ladder["pr_gain_vs_previous"].notna()].copy()
    lad["group"] = lad["rung"].str.replace(r"^\+\s*", "", regex=True)
    lad = lad.rename(columns={"pr_gain_vs_previous": "gain", "pr_gain_vs_previous_lo": "lo",
                              "pr_gain_vs_previous_hi": "hi"})
    sp = spatial[spatial["model"].isin(models)]
    tm = temporal[temporal["model"].isin(models)]
    pm = permutation.iloc[0]
    return {
        "ladder": _records(lad, ["group", "model", "gain", "lo", "hi"]),
        "spatial": _records(sp, ["scheme", "model", "held_out", "pr_auc", "pr_sd", "roc_auc"]),
        "temporal": _records(tm, ["year", "model", "n", "positives", "base_rate", "pr_auc", "roc_auc",
                                  "few_positives"]),
        "permutation": {k: _json_clean(pm[k]) for k in ["observed", "null_mean", "null_p95", "p_value", "n_perm"]},
    }


def run_validation(df, devel, features, fold_list, cache=None, cv_repeats=5, n_perm=500, county_folds=10,
                   first_year=2019, last_year=2025):
    """Run all generalization checks; returns (dict of tables, dict of
    seconds per analysis). Keys: ablation, spatial_cv, spatial_cv_folds,
    temporal, permutation, calib_deciles."""
    import time
    out, secs = {}, {}
    t = time.time(); out["ablation"] = ablation_study(devel, fold_list, features, cache=cache)
    secs["ablation"] = time.time() - t
    t = time.time()
    out["spatial_cv"], out["spatial_cv_folds"] = spatial_validation(devel, features, fold_list, repeats=cv_repeats,
                                                                    county_folds=county_folds, cache=cache)
    secs["spatial_cv"] = time.time() - t
    t = time.time(); out["temporal"] = rolling_origin(df, features, first_year=first_year, last_year=last_year)
    secs["temporal"] = time.time() - t
    t = time.time(); out["permutation"] = permutation_test(devel, features, n_perm=n_perm)
    secs["permutation"] = time.time() - t
    t = time.time(); out["calib_deciles"] = calibration_deciles(devel, features, fold_list)
    secs["calib_deciles"] = time.time() - t
    return out, secs


# ---- CLI ---------------------------------------------------------------------------
def load_flood_table(project_dir):
    """Rebuild the report's `flood_ml` table from the exported files.

    Flood events with coordinates from data/ml_ready, local relief from
    data/derived/event_relief_5000m.parquet, and county_fips3 from the first
    code in matched_county_fips.
    """
    root = Path(project_dir)
    df = pd.read_parquet(root / "data/ml_ready/nc_flood_event_model_table.parquet")
    df = df[(df["is_flood_event"] == 1) & df["longitude"].notna() & df["latitude"].notna()].copy()
    relief = pd.read_parquet(root / "data/derived/event_relief_5000m.parquet")
    df = df.merge(relief[["event_id", "local_relief_5km"]], on="event_id", how="left")
    df["county_fips3"] = pd.to_numeric(df["matched_county_fips"].astype("string").str.split(";").str[0],
                                       errors="coerce")
    df["event_date"] = df["event_date"].astype(str)
    return df.reset_index(drop=True)


def run_all(flood_df, nri_path, highlight_start, highlight_end, cv_repeats=5, cv_folds=5,
            history_radius_km=25, history_window_years=3, n_boot=2000, validate=True, n_perm=500):
    """Run the whole analysis and return a dict of result tables.

    With validate=True it also runs the generalization checks
    (`run_validation`): keys ablation, spatial_cv, spatial_cv_folds,
    temporal, permutation, calib_deciles, validation_summary (JSON-ready
    dict) and timings (seconds per analysis).
    """
    df = build_model_frame(flood_df, nri_path, history_radius_km, history_window_years)
    devel, test = split_frame(df)
    rungs = resolve_ladder(devel)
    features, primary_rung = primary_features(rungs)
    folds = make_group_folds(devel[TARGET], devel[GROUP], cv_repeats, cv_folds)
    cache = {}
    ladder, _ = feature_ladder(devel, folds, rungs, cache=cache)
    cv_results, _ = compare_models(devel, features, folds, cache=cache)
    fit = fit_holdout(devel, test, features)
    extra = {}
    if validate:
        val, secs = run_validation(df, devel, features, folds, cache=cache, cv_repeats=cv_repeats, n_perm=n_perm)
        extra = dict(val, timings=secs,
                     validation_summary=validation_summary(ladder, val["spatial_cv"], val["temporal"],
                                                           val["permutation"]))
    return {
        **extra,
        "features": features, "primary_rung": primary_rung, "ladder": ladder, "cv_results": cv_results,
        "holdout": fit["holdout"], "holdout_ci": holdout_bootstrap(fit, test, n_boot=n_boot),
        "helene_sensitivity": helene_sensitivity(fit, test, highlight_start, highlight_end),
        "inversion": season_inversion(fit, df),
        "tree_use": tree_use(fit["fitted"]["Random forest"], features),
        "tropical_check": pd.DataFrame([tropical_flag_check(devel, features)]),
        "calib_compare": calibration_check(fit),
        "summary": {"devel_n": len(devel), "devel_pos": int(devel[TARGET].sum()),
                    "test_n": len(test), "test_pos": int(test[TARGET].sum())},
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="Carolina HighGround models: feature ladder, holdout CIs, diagnostics.")
    ap.add_argument("--project-dir", default=".", help="project root")
    ap.add_argument("--nri-path", default="data/raw/nri/NRI_Table_Counties.csv")
    ap.add_argument("--highlight-start", default="2024-09-24")
    ap.add_argument("--highlight-end", default="2024-09-30")
    ap.add_argument("--cv-repeats", type=int, default=5)
    ap.add_argument("--cv-folds", type=int, default=5)
    ap.add_argument("--n-boot", type=int, default=2000)
    ap.add_argument("--out-dir", default="outs/tables")
    ap.add_argument("--n-perm", type=int, default=500, help="label permutations for the permutation test")
    ap.add_argument("--skip-validation", action="store_true", help="skip the generalization checks")
    a = ap.parse_args(argv)

    root = Path(a.project_dir).resolve()
    nri = Path(a.nri_path) if Path(a.nri_path).is_absolute() else root / a.nri_path
    res = run_all(load_flood_table(root), nri, a.highlight_start, a.highlight_end,
                  a.cv_repeats, a.cv_folds, n_boot=a.n_boot, validate=not a.skip_validation, n_perm=a.n_perm)

    pd.set_option("display.width", 200, "display.max_columns", 30, "display.precision", 3)
    print(f"Data: {res['summary']}")
    print(f"Primary model: {res['primary_rung']} ({len(res['features'])} features): {', '.join(res['features'])}\n")
    print("== Feature ladder ==")
    print(res["ladder"].drop(columns=["features_added"]).to_string(index=False))
    print("\n== Model comparison (primary features) ==\n" + res["cv_results"].to_string(index=False))
    print("\n== Holdout with cluster-bootstrap 95% CIs ==\n" + res["holdout_ci"].to_string(index=False))
    print("\n== Helene sensitivity ==\n" + res["helene_sensitivity"].to_string(index=False))
    print("\n== Season inversion (mountain flood events) ==\n" + res["inversion"].to_string(index=False))
    print("\n== Tropical flag check ==\n" + res["tropical_check"].to_string(index=False))

    out = root / a.out_dir
    out.mkdir(parents=True, exist_ok=True)
    for name in ["ladder", "holdout_ci", "helene_sensitivity", "inversion", "tropical_check"]:
        res[name].to_csv(out / f"model_{name}.csv", index=False)
    print(f"\nWrote model_ladder.csv, model_holdout_ci.csv, model_helene_sensitivity.csv, "
          f"model_inversion.csv, model_tropical_check.csv to {out}")

    if "ablation" in res:
        import json
        print("\n== Ablation: full model minus each group, and small subsets ==")
        print(res["ablation"].drop(columns=["features"]).to_string(index=False))
        print("\n== Spatial validation ==\n" + res["spatial_cv"].to_string(index=False))
        print("\n== Rolling-origin temporal validation ==\n" + res["temporal"].to_string(index=False))
        print("\n== Label-permutation test ==\n" + res["permutation"].to_string(index=False))
        print("\n== Reliability by risk decile (out-of-fold) ==\n" + res["calib_deciles"].to_string(index=False))
        print("\nSeconds: " + ", ".join(f"{k} {v:.1f}" for k, v in res["timings"].items()))
        files = {"ablation": "model_ablation.csv", "spatial_cv": "model_spatial_cv.csv",
                 "temporal": "model_temporal.csv", "permutation": "model_permutation.csv",
                 "calib_deciles": "model_calibration_deciles.csv"}
        for k, fn in files.items():
            res[k].to_csv(out / fn, index=False)
        with open(out / "model_validation_summary.json", "w") as fh:
            json.dump(res["validation_summary"], fh, indent=1, allow_nan=False)
        print(f"Wrote {', '.join(files.values())}, model_validation_summary.json to {out}")


if __name__ == "__main__":
    main()
