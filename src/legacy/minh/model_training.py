"""
Blue Ridge FloodWatch -- train and compare Logistic Regression, Random Forest,
and HistGradientBoosting on the same 11-feature event-level table.
"""
import json
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier, HistGradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, roc_auc_score
from sklearn.model_selection import StratifiedGroupKFold, StratifiedKFold, cross_val_predict
from sklearn.neighbors import BallTree
from sklearn.preprocessing import StandardScaler

DATA_DIR = "data"
HIGH_CONSEQUENCE_DAMAGE_THRESHOLD = 200_000  # 90th pctile of TRAINING-YEARS-ONLY damage -- leakage-safe
RADIUS_KM = 25
HISTORY_WINDOW_YEARS = 3

FEATURES = [
    "slope_degrees", "elevation_m", "impervious_mean_250m", "distance_to_stream_m",
    "population_density", "SOVI_SCORE",
    "nearby_minor_flood_count_25km", "nearby_severe_flood_count_25km",
    "local_relief_5km", "event_month", "peak_hurricane_season",
]
TARGET = "high_consequence_v2"


def compute_split_flood_history(full_storm_table_path):
    full = pd.read_csv(full_storm_table_path, parse_dates=["event_date"])
    flood = full[full["is_flood_event"] == 1].dropna(subset=["latitude", "longitude"]).copy()
    flood = flood.sort_values("event_date").reset_index(drop=True)
    hc_safe = ((flood["total_deaths"] >= 1) | (flood["total_damage"] > HIGH_CONSEQUENCE_DAMAGE_THRESHOLD)).astype(int).to_numpy()

    coords_rad = np.radians(flood[["latitude", "longitude"]].to_numpy())
    tree = BallTree(coords_rad, metric="haversine")
    radius_rad = RADIUS_KM / 6371.0
    dates, eids = flood["event_date"].to_numpy(), flood["event_id"].to_numpy()

    records = []
    for i in range(len(flood)):
        neighbor_idx = tree.query_radius(coords_rad[i:i + 1], r=radius_rad)[0]
        cur = dates[i]
        n_dates, n_hc = dates[neighbor_idx], hc_safe[neighbor_idx]
        window = (n_dates < cur) & (n_dates >= cur - np.timedelta64(365 * HISTORY_WINDOW_YEARS, "D"))
        records.append({
            "event_id": eids[i],
            "nearby_minor_flood_count_25km": int(np.sum(window & (n_hc == 0))),
            "nearby_severe_flood_count_25km": int(np.sum(window & (n_hc == 1))),
        })
    return pd.DataFrame(records)


def load_data():
    df = pd.read_csv(f"{DATA_DIR}/nc_flood_event_model_table_enriched.csv", parse_dates=["event_date"])
    df = df.dropna(subset=["latitude", "longitude"]).reset_index(drop=True)
    history = compute_split_flood_history(f"{DATA_DIR}/nc_storm_event_model_table.csv")
    df = df.merge(history, on="event_id", how="left")
    relief = pd.read_csv(f"{DATA_DIR}/event_relief.csv")  # see compute_local_relief in the RF export script
    df = df.merge(relief, on="event_id", how="left")
    df["peak_hurricane_season"] = df["event_month"].isin([8, 9, 10]).astype(int)

    devel = df[df["split"].isin(["train", "validation"])].reset_index(drop=True)
    test = df[df["split"] == "test"].reset_index(drop=True)
    return devel, test


def platt_calibrate(raw_probs, y, out_of_fold_fn):
    """Recalibrates a classifier's raw output via Platt scaling (1-D logistic
    regression on the logit), fit on OUT-OF-FOLD predictions -- never on the
    same rows the base model was trained on, which is optimistic/overconfident
    especially for tree models."""
    def logit(p, eps=1e-6):
        p = np.clip(p, eps, 1 - eps)
        return np.log(p / (1 - p))
    oof_raw = out_of_fold_fn()
    recal = LogisticRegression().fit(logit(oof_raw).reshape(-1, 1), y)
    scale, shift = float(recal.coef_[0][0]), float(recal.intercept_[0])
    return scale, shift, logit


def repeated_group_cv(build_fn, X, y, groups, needs_scaling, n_repeats=5, n_splits=5):
    prs, rocs = [], []
    for rep in range(n_repeats):
        skf = StratifiedGroupKFold(n_splits=n_splits, shuffle=True, random_state=100 + rep)
        for tr, va in skf.split(X, y, groups):
            imputer = SimpleImputer(strategy="median").fit(X.iloc[tr])
            X_tr, X_va = imputer.transform(X.iloc[tr]), imputer.transform(X.iloc[va])
            model = build_fn()
            if needs_scaling:
                scaler = StandardScaler().fit(X_tr)
                X_tr, X_va = scaler.transform(X_tr), scaler.transform(X_va)
            model.fit(X_tr, y.iloc[tr])
            p = model.predict_proba(X_va)[:, 1]
            prs.append(average_precision_score(y.iloc[va], p))
            rocs.append(roc_auc_score(y.iloc[va], p))
    return np.mean(prs), np.std(prs), np.mean(rocs), np.std(rocs)


# ============================================================
# Model 1: Logistic Regression (deployed in the linear-model artifact)
# ============================================================
def train_logistic_regression(devel, test):
    X_dev, y_dev = devel[FEATURES], devel[TARGET]
    X_test, y_test = test[FEATURES], test[TARGET]

    imputer = SimpleImputer(strategy="median").fit(X_dev)
    scaler = StandardScaler().fit(imputer.transform(X_dev))
    X_dev_s = scaler.transform(imputer.transform(X_dev))
    X_test_s = scaler.transform(imputer.transform(X_test))

    model = LogisticRegression(max_iter=2000, class_weight="balanced", C=0.5)
    model.fit(X_dev_s, y_dev)

    scale, shift, logit = platt_calibrate(
        None, y_dev,
        lambda: cross_val_predict(
            LogisticRegression(max_iter=2000, class_weight="balanced", C=0.5),
            X_dev_s, y_dev, cv=StratifiedKFold(5, shuffle=True, random_state=42), method="predict_proba"
        )[:, 1]
    )

    raw_test = model.predict_proba(X_test_s)[:, 1]
    cal_test = 1 / (1 + np.exp(-(scale * logit(raw_test) + shift)))
    print(f"Logistic Regression -- holdout PR-AUC={average_precision_score(y_test, cal_test):.4f} "
          f"ROC-AUC={roc_auc_score(y_test, cal_test):.4f}  mean_pred={cal_test.mean():.4f} actual={y_test.mean():.4f}")

    final_coefs = {f: float(c * scale) for f, c in zip(FEATURES, model.coef_[0])}
    final_intercept = float(model.intercept_[0] * scale + shift)
    export = {
        "features": FEATURES,
        "coefficients": final_coefs,
        "intercept": final_intercept,
        "medians": {f: float(m) for f, m in zip(FEATURES, imputer.statistics_)},
        "means": {f: float(m) for f, m in zip(FEATURES, scaler.mean_)},
        "stds": {f: float(s) for f, s in zip(FEATURES, scaler.scale_)},
    }
    with open("model_logistic.json", "w") as fh:
        json.dump(export, fh, indent=2)
    return model, imputer, scaler


# ============================================================
# Model 2: Random Forest (deployed in the tree-ensemble artifact)
# ============================================================
def train_random_forest(devel, test, n_estimators=100, max_depth=6):
    X_dev, y_dev = devel[FEATURES], devel[TARGET]
    X_test, y_test = test[FEATURES], test[TARGET]

    imputer = SimpleImputer(strategy="median").fit(X_dev)
    X_dev_imp, X_test_imp = imputer.transform(X_dev), imputer.transform(X_test)

    model = RandomForestClassifier(n_estimators=n_estimators, max_depth=max_depth, class_weight="balanced",
                                    min_samples_leaf=5, max_features="sqrt", random_state=42)
    model.fit(X_dev_imp, y_dev)

    scale, shift, logit = platt_calibrate(
        None, y_dev,
        lambda: cross_val_predict(
            RandomForestClassifier(n_estimators=n_estimators, max_depth=max_depth, class_weight="balanced",
                                    min_samples_leaf=5, max_features="sqrt", random_state=42),
            X_dev_imp, y_dev, cv=StratifiedKFold(5, shuffle=True, random_state=42), method="predict_proba"
        )[:, 1]
    )

    raw_test = model.predict_proba(X_test_imp)[:, 1]
    cal_test = 1 / (1 + np.exp(-(scale * logit(raw_test) + shift)))
    print(f"Random Forest       -- holdout PR-AUC={average_precision_score(y_test, cal_test):.4f} "
          f"ROC-AUC={roc_auc_score(y_test, cal_test):.4f}  mean_pred={cal_test.mean():.4f} actual={y_test.mean():.4f}")

    def export_tree(tree):
        t = tree.tree_
        value = t.value[:, 0, :]
        leaf_prob = (value[:, 1] / value.sum(axis=1)).tolist()
        return {"feature": t.feature.tolist(), "threshold": t.threshold.tolist(),
                "left": t.children_left.tolist(), "right": t.children_right.tolist(), "prob": leaf_prob}

    export = {
        "features": FEATURES,
        "medians": {f: float(m) for f, m in zip(FEATURES, imputer.statistics_)},
        "trees": [export_tree(t) for t in model.estimators_],
        "feature_importances": {f: float(i) for f, i in zip(FEATURES, model.feature_importances_)},
        "calibration": {"scale": scale, "shift": shift},
    }
    with open("model_random_forest.json", "w") as fh:
        json.dump(export, fh)
    return model, imputer


# ============================================================
# Model 3: HistGradientBoosting (comparison / reported result only -- not
# deployed to either artifact; too complex to export as embeddable JS)
# ============================================================
def train_histgradientboosting(devel, test):
    X_dev, y_dev = devel[FEATURES], devel[TARGET]
    X_test, y_test = test[FEATURES], test[TARGET]
    imputer = SimpleImputer(strategy="median").fit(X_dev)
    X_dev_imp, X_test_imp = imputer.transform(X_dev), imputer.transform(X_test)

    model = HistGradientBoostingClassifier(max_depth=3, learning_rate=0.05, max_iter=300,
                                            class_weight="balanced", random_state=42)
    model.fit(X_dev_imp, y_dev)
    raw_test = model.predict_proba(X_test_imp)[:, 1]
    print(f"HistGradientBoosting-- holdout PR-AUC={average_precision_score(y_test, raw_test):.4f} "
          f"ROC-AUC={roc_auc_score(y_test, raw_test):.4f}  (uncalibrated -- reporting only, not deployed)")
    return model, imputer


if __name__ == "__main__":
    devel, test = load_data()
    print(f"Dev pool: n={len(devel)} ({devel[TARGET].mean():.1%} positive)  "
          f"Test: n={len(test)} ({test[TARGET].mean():.1%} positive)\n")

    X, y, groups = devel[FEATURES], devel[TARGET], devel["episode_id"]
    print("=== Repeated grouped 5x5 CV (the number to report) ===")
    for name, build_fn, scaled in [
        ("Logistic Regression", lambda: LogisticRegression(max_iter=2000, class_weight="balanced", C=0.5), True),
        ("Random Forest", lambda: RandomForestClassifier(n_estimators=100, max_depth=6, class_weight="balanced",
                                                          min_samples_leaf=5, max_features="sqrt", random_state=42), False),
        ("HistGradientBoosting", lambda: HistGradientBoostingClassifier(max_depth=3, learning_rate=0.05, max_iter=300,
                                                                         class_weight="balanced", random_state=42), False),
    ]:
        pr, pr_std, roc, roc_std = repeated_group_cv(build_fn, X, y, groups, scaled)
        print(f"  {name:22s} PR-AUC={pr:.4f}+/-{pr_std:.4f}  ROC-AUC={roc:.4f}+/-{roc_std:.4f}")

    print("\n=== Final fit + calibration + holdout test (illustrative, small-n) ===")
    train_logistic_regression(devel, test)
    train_random_forest(devel, test)
    train_histgradientboosting(devel, test)