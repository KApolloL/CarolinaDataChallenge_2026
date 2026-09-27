"""
Blue Ridge FloodWatch -- rebuilt end-to-end from the actual uploaded data
(ml_ready export + NRI county table), trains the 3 models, then produces:
  1. precision-recall curve plot (test set, all 3 models)
  2. calibration / reliability plot (Random Forest, before vs after Platt fix)
  3. a SHAP summary plot for the Random Forest

NOTE on feature reconstruction (read this before trusting numbers 1:1 with
your earlier run): the ml_ready export you gave me does NOT contain
SOVI_SCORE, population_density, nearby_*_flood_count_25km, local_relief_5km,
or peak_hurricane_season as ready-made columns -- those were built downstream
in your pipeline. I rebuilt them here from source data you also uploaded:
  - SOVI_SCORE, population_density  <- joined from NRI_Table_Counties.csv
    via matched_county_fips (NC state FIPS 37000 + county code = STCOFIPS)
  - nearby_minor/severe_flood_count_25km <- recomputed with the same BallTree
    logic as datathonM3.py, against nc_storm_event_model_table.csv
  - peak_hurricane_season <- event_month in {8,9,10}, same as before
  - local_relief_5km <- NOT available (no DEM/relief raster was uploaded).
    Approximated with roughness_mean_250m, which is the closest proxy present
    in the export (local terrain roughness). Treat local-relief-specific
    claims from earlier analysis as provisional until re-run with the real
    5km relief raster.
Everything else (slope, elevation, imperviousness, distance-to-stream,
event_month, target, splits, episode_id groups) comes directly from your
actual event table, unmodified.
"""
import json
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from sklearn.ensemble import RandomForestClassifier, HistGradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (average_precision_score, roc_auc_score,
                              precision_recall_curve)
from sklearn.calibration import calibration_curve
from sklearn.model_selection import StratifiedKFold, cross_val_predict
from sklearn.neighbors import BallTree
from sklearn.preprocessing import StandardScaler

ML_READY = "ml_ready"
NRI_PATH = "nri/NRI_Table_Counties.csv"
RADIUS_KM = 25
HISTORY_WINDOW_YEARS = 3
STATE_FIPS_PREFIX = 37000  # North Carolina

FEATURES = [
    "slope_degrees", "elevation_m", "impervious_mean_250m", "distance_to_stream_m",
    "population_density", "SOVI_SCORE",
    "nearby_minor_flood_count_25km", "nearby_severe_flood_count_25km",
    "local_relief_5km", "event_month", "peak_hurricane_season",
]
TARGET = "high_consequence"


# ------------------------------------------------------------------
# Data reconstruction
# ------------------------------------------------------------------
def compute_split_flood_history(full_storm_table_path):
    full = pd.read_csv(full_storm_table_path, parse_dates=["event_date"])
    flood = full[full["is_flood_event"] == 1].dropna(subset=["latitude", "longitude"]).copy()
    flood = flood.sort_values("event_date").reset_index(drop=True)
    hc_safe = flood[TARGET].fillna(0).astype(int).to_numpy()

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


def load_nri():
    nri = pd.read_csv(NRI_PATH, usecols=["STCOFIPS", "STATEABBRV", "POPULATION", "AREA", "SOVI_SCORE"])
    nri = nri[nri["STATEABBRV"] == "NC"].copy()
    nri["population_density"] = nri["POPULATION"] / nri["AREA"]
    nri["matched_county_fips"] = nri["STCOFIPS"] - STATE_FIPS_PREFIX
    return nri[["matched_county_fips", "population_density", "SOVI_SCORE"]]


def load_data():
    df = pd.read_csv(f"{ML_READY}/nc_flood_event_model_table.csv", parse_dates=["event_date"])
    df = df.dropna(subset=["latitude", "longitude"]).reset_index(drop=True)

    history = compute_split_flood_history(f"{ML_READY}/nc_storm_event_model_table.csv")
    df = df.merge(history, on="event_id", how="left")
    df["nearby_minor_flood_count_25km"] = df["nearby_minor_flood_count_25km"].fillna(0)
    df["nearby_severe_flood_count_25km"] = df["nearby_severe_flood_count_25km"].fillna(0)

    nri = load_nri()
    df = df.merge(nri, on="matched_county_fips", how="left")

    df["local_relief_5km"] = df["roughness_mean_250m"]  # proxy -- see module docstring
    df["peak_hurricane_season"] = df["event_month"].isin([8, 9, 10]).astype(int)

    devel = df[df["split"].isin(["train", "validation"])].reset_index(drop=True)
    test = df[df["split"] == "test"].reset_index(drop=True)
    return devel, test


# ------------------------------------------------------------------
# Calibration helper (identical logic to datathonM3.py)
# ------------------------------------------------------------------
def logit(p, eps=1e-6):
    p = np.clip(p, eps, 1 - eps)
    return np.log(p / (1 - p))


def platt_calibrate(y, oof_raw):
    recal = LogisticRegression().fit(logit(oof_raw).reshape(-1, 1), y)
    scale, shift = float(recal.coef_[0][0]), float(recal.intercept_[0])
    return scale, shift


def apply_calibration(raw, scale, shift):
    return 1 / (1 + np.exp(-(scale * logit(raw) + shift)))


# ------------------------------------------------------------------
# Train all three + collect test-set predictions for plotting
# ------------------------------------------------------------------
def main():
    devel, test = load_data()
    print(f"Dev pool: n={len(devel)} ({devel[TARGET].mean():.1%} positive)  "
          f"Test: n={len(test)} ({test[TARGET].mean():.1%} positive)")
    print("Feature availability (non-null %) in dev pool:")
    print((devel[FEATURES].notna().mean() * 100).round(1))

    X_dev, y_dev = devel[FEATURES], devel[TARGET]
    X_test, y_test = test[FEATURES], test[TARGET]

    results = {}  # name -> dict(raw_test, cal_test)

    # ---------- Logistic Regression ----------
    imputer_lr = SimpleImputer(strategy="median").fit(X_dev)
    scaler = StandardScaler().fit(imputer_lr.transform(X_dev))
    X_dev_s = scaler.transform(imputer_lr.transform(X_dev))
    X_test_s = scaler.transform(imputer_lr.transform(X_test))

    lr = LogisticRegression(max_iter=2000, class_weight="balanced", C=0.5).fit(X_dev_s, y_dev)
    oof_lr = cross_val_predict(
        LogisticRegression(max_iter=2000, class_weight="balanced", C=0.5),
        X_dev_s, y_dev, cv=StratifiedKFold(5, shuffle=True, random_state=42), method="predict_proba"
    )[:, 1]
    scale, shift = platt_calibrate(y_dev, oof_lr)
    raw_test = lr.predict_proba(X_test_s)[:, 1]
    results["Logistic Regression"] = {"raw": raw_test, "cal": apply_calibration(raw_test, scale, shift)}

    # ---------- Random Forest ----------
    imputer_rf = SimpleImputer(strategy="median").fit(X_dev)
    X_dev_imp, X_test_imp = imputer_rf.transform(X_dev), imputer_rf.transform(X_test)

    rf = RandomForestClassifier(n_estimators=100, max_depth=6, class_weight="balanced",
                                 min_samples_leaf=5, max_features="sqrt", random_state=42)
    rf.fit(X_dev_imp, y_dev)
    oof_rf = cross_val_predict(
        RandomForestClassifier(n_estimators=100, max_depth=6, class_weight="balanced",
                                min_samples_leaf=5, max_features="sqrt", random_state=42),
        X_dev_imp, y_dev, cv=StratifiedKFold(5, shuffle=True, random_state=42), method="predict_proba"
    )[:, 1]
    scale_rf, shift_rf = platt_calibrate(y_dev, oof_rf)
    raw_test_rf = rf.predict_proba(X_test_imp)[:, 1]
    cal_test_rf = apply_calibration(raw_test_rf, scale_rf, shift_rf)
    results["Random Forest"] = {"raw": raw_test_rf, "cal": cal_test_rf}

    # ---------- HistGradientBoosting ----------
    hgb = HistGradientBoostingClassifier(max_depth=3, learning_rate=0.05, max_iter=300,
                                          class_weight="balanced", random_state=42)
    hgb.fit(X_dev_imp, y_dev)
    raw_test_hgb = hgb.predict_proba(X_test_imp)[:, 1]
    # HGB reported uncalibrated in the original pipeline; keep that convention
    results["HistGradientBoosting"] = {"raw": raw_test_hgb, "cal": raw_test_hgb}

    # ---------- Print holdout metrics ----------
    print("\n=== Holdout test metrics (calibrated probs) ===")
    for name, r in results.items():
        pr = average_precision_score(y_test, r["cal"])
        roc = roc_auc_score(y_test, r["cal"])
        print(f"  {name:22s} PR-AUC={pr:.4f}  ROC-AUC={roc:.4f}  mean_pred={r['cal'].mean():.4f}")
    print(f"  Base rate (test)       PR-AUC={y_test.mean():.4f}")

    # ================================================================
    # PLOT 1: Precision-Recall curves, all three models, test set
    # ================================================================
    plt.figure(figsize=(7, 6))
    base_rate = y_test.mean()
    colors = {"Logistic Regression": "#2563eb", "Random Forest": "#16a34a", "HistGradientBoosting": "#dc2626"}
    for name, r in results.items():
        precision, recall, _ = precision_recall_curve(y_test, r["cal"])
        ap = average_precision_score(y_test, r["cal"])
        plt.plot(recall, precision, label=f"{name} (AP={ap:.3f})", color=colors[name], linewidth=2)
    plt.axhline(base_rate, linestyle="--", color="gray", linewidth=1.5,
                label=f"Random baseline (AP={base_rate:.3f})")
    plt.xlabel("Recall")
    plt.ylabel("Precision")
    plt.title("Precision-Recall Curve -- Holdout Test Set\n(high-consequence flood events)")
    plt.legend(loc="upper right")
    plt.grid(alpha=0.3)
    plt.tight_layout()
    plt.savefig("pr_curve.png", dpi=150)
    plt.close()
    print("Saved pr_curve.png")

    # ================================================================
    # PLOT 2: Calibration / reliability curve -- RF before vs after fix
    # ================================================================
    fig, axes = plt.subplots(1, 2, figsize=(12, 5.5))

    for ax, (probs, title) in zip(
        axes,
        [(raw_test_rf, "Random Forest -- RAW (uncalibrated)"),
         (cal_test_rf, "Random Forest -- CALIBRATED (Platt, out-of-fold)")]
    ):
        frac_pos, mean_pred = calibration_curve(y_test, probs, n_bins=8, strategy="quantile")
        ax.plot([0, 1], [0, 1], "k--", linewidth=1, label="Perfect calibration")
        ax.plot(mean_pred, frac_pos, "o-", color="#16a34a", linewidth=2, label="Model")
        ax.set_xlabel("Mean predicted probability")
        ax.set_ylabel("Observed fraction positive")
        ax.set_title(title)
        ax.legend()
        ax.grid(alpha=0.3)
        ax.set_xlim(0, max(0.5, probs.max() * 1.1))
        ax.set_ylim(0, 1)

    plt.suptitle("Calibration (Reliability) Plot -- Holdout Test Set", y=1.02, fontsize=13)
    plt.tight_layout()
    plt.savefig("calibration_plot.png", dpi=150, bbox_inches="tight")
    plt.close()
    print("Saved calibration_plot.png")

    # ================================================================
    # SHAP summary plot for Random Forest
    # ================================================================
    try:
        import shap
        explainer = shap.TreeExplainer(rf)
        # Use a sample of the test set for speed; TreeExplainer is exact either way
        X_shap = pd.DataFrame(X_test_imp, columns=FEATURES)
        shap_values = explainer.shap_values(X_shap)
        # shap_values can be a list (per-class) or a single array depending on sklearn/shap version
        sv = shap_values[1] if isinstance(shap_values, list) else shap_values
        if sv.ndim == 3:  # (n_samples, n_features, n_classes) in newer shap
            sv = sv[:, :, 1]
        plt.figure()
        shap.summary_plot(sv, X_shap, show=False)
        plt.tight_layout()
        plt.savefig("shap_summary.png", dpi=150, bbox_inches="tight")
        plt.close()
        print("Saved shap_summary.png")

        # Also save mean |SHAP| ranking as a plain table for the slides
        mean_abs = pd.Series(np.abs(sv).mean(axis=0), index=FEATURES).sort_values(ascending=False)
        mean_abs.to_csv("shap_feature_importance.csv", header=["mean_abs_shap_value"])
        print("\nMean |SHAP value| ranking (Random Forest, test set):")
        print(mean_abs.round(4))
    except ImportError:
        print("shap not installed -- run: pip install shap --break-system-packages")

    # Save models + predictions for reuse
    devel.assign(**{f"pred_placeholder": 0}).head(0)  # no-op, keeps devel referenced
    np.savez("test_predictions.npz",
             y_test=y_test.to_numpy(),
             **{f"{k}_raw": v["raw"] for k, v in results.items()},
             **{f"{k}_cal": v["cal"] for k, v in results.items()})
    print("\nSaved test_predictions.npz (raw + calibrated probs for all 3 models)")


if __name__ == "__main__":
    main()
