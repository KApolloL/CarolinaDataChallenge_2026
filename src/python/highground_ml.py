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
            history_radius_km=25, history_window_years=3, n_boot=2000):
    """Run the whole analysis and return a dict of result tables."""
    df = build_model_frame(flood_df, nri_path, history_radius_km, history_window_years)
    devel, test = split_frame(df)
    rungs = resolve_ladder(devel)
    features, primary_rung = primary_features(rungs)
    folds = make_group_folds(devel[TARGET], devel[GROUP], cv_repeats, cv_folds)
    cache = {}
    ladder, _ = feature_ladder(devel, folds, rungs, cache=cache)
    cv_results, _ = compare_models(devel, features, folds, cache=cache)
    fit = fit_holdout(devel, test, features)
    return {
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
    a = ap.parse_args(argv)

    root = Path(a.project_dir).resolve()
    nri = Path(a.nri_path) if Path(a.nri_path).is_absolute() else root / a.nri_path
    res = run_all(load_flood_table(root), nri, a.highlight_start, a.highlight_end,
                  a.cv_repeats, a.cv_folds, n_boot=a.n_boot)

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


if __name__ == "__main__":
    main()
