"""Aggregate the USACE National Structure Inventory (NSI) to the explorer's grid.

Downloads each NC county from the public NSI API one at a time, assigns every building to its
grid cell, and keeps only the per-cell totals (buildings, residential units, night-time people,
structure value). Raw building records are not stored. Output: data/derived/explorer/nsi_grid.csv.
Resumable: finished counties are cached in data/derived/nsi_county_cache/.

Run: python src/python/build_nsi_grid.py --project-dir .
"""
import argparse, json, time, urllib.request
from pathlib import Path
import numpy as np
import pandas as pd

URL = "https://nsi.sec.usace.army.mil/nsiapi/structures?fips={fips}"


def fetch(fips, tries=4):
    last = None
    for t in range(tries):
        try:
            with urllib.request.urlopen(URL.format(fips=fips), timeout=600) as r:
                return json.loads(r.read())
        except Exception as e:  # network hiccup: wait and retry
            last = e
            time.sleep(5 * (t + 1))
    raise RuntimeError(f"NSI download failed for {fips}: {last}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-dir", default=".")
    a = ap.parse_args()
    root = Path(a.project_dir).resolve()
    ex = root / "data/derived/explorer"
    cache = root / "data/derived/nsi_county_cache"
    cache.mkdir(parents=True, exist_ok=True)
    g = pd.read_csv(ex / "grid.csv")
    dlon = dlat = 0.04166667
    lon0, lat0 = g["lon"].min(), g["lat"].min()
    key = {(int(round((x - lon0) / dlon)), int(round((y - lat0) / dlat))): c
           for c, x, y in zip(g["cell_id"], g["lon"], g["lat"])}
    counties = sorted({int(f) for f in g["county_fips3"].dropna()})
    for c3 in counties:
        fips = f"37{c3:03d}"
        f = cache / f"{fips}.csv"
        if f.exists():
            continue
        feats = fetch(fips).get("features", [])
        rows = []
        for ft in feats:
            p = ft["properties"]
            x, y = p.get("x"), p.get("y")
            if x is None or y is None:
                continue
            cid = key.get((int(round((x - lon0) / dlon)), int(round((y - lat0) / dlat))))
            if cid is None:
                continue
            res = str(p.get("occtype", "")).startswith("RES")
            rows.append((cid, 1, 1 if res else 0, p.get("resunits") or 0 if res else 0,
                         (p.get("pop2amu65") or 0) + (p.get("pop2amo65") or 0),
                         (p.get("pop2pmu65") or 0) + (p.get("pop2pmo65") or 0),
                         p.get("val_struct") or 0))
        d = pd.DataFrame(rows, columns=["cell_id", "buildings", "residential", "res_units", "pop_night", "pop_day", "value"])
        d.groupby("cell_id").sum().reset_index().to_csv(f, index=False)
        print(fips, len(feats), "buildings", flush=True)
    parts = [pd.read_csv(p) for p in sorted(cache.glob("*.csv"))]
    out = pd.concat(parts).groupby("cell_id").sum().reset_index()
    out["value"] = out["value"].round(0)
    out.to_csv(ex / "nsi_grid.csv", index=False)
    print("wrote nsi_grid.csv", len(out), "cells;", int(out["buildings"].sum()), "buildings")


if __name__ == "__main__":
    main()
