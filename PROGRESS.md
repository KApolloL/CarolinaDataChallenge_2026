# Progress: improvements after the winning-project review (started Oct 22 2026)

Purpose: a resume point. If a session ends (usage limit), a fresh session reads this file and continues at the first unchecked item. Each item leaves the repo working. Nothing here is committed unless noted. Rules: see CLAUDE.md (no raw-data edits, ASCII in R strings, no em dashes, no commits unless Kent asks).

Order is by payoff per cost. Re-render and docs rebuild are last (step 6), so stop earlier and the existing site still works.

- [x] 1. Headline metric: top-10% capture next to PR-AUC in the report text and explorer About tab, with the Helene caveat kept.
- [x] 2. Back-tests: add Florence (Sep 2018) and Matthew (Oct 2016) replays to the explorer next to Helene. Needs gridMET rainfall per cell for each window (extend `src/R/explorer_data.R`), export in `export_explorer.py`, template reads `meta.replays`.
- [x] 3. Building exposure: USACE NSI (public API, `https://nsi.sec.usace.army.mil/nsiapi/structures?fips=<county>`) to `data/raw/nsi/` (download once, 100 counties or the 11 study counties plus neighbors), aggregate to the 4 km grid (buildings, residential buildings, population) in R, add to grid and place card ("about N homes in this square").
- [x] 4. Road crossings: NCDOT structures and culverts (`data/raw/ncdot/`) scored with the model at their location, ranked table plus map layer in the explorer, CSV download. State plainly that this ranks crossings by modeled exposure and does not compute isolation (no road network).
- [x] 5. Packaging: README hook, team roles table, live-site link, explorer link; presentation brief updated with validation numbers and the new features.
- [x] 6. Final: `Rscript`/`quarto render src/final_analysis_deliverable.qmd`, rebuild `docs/index.html` and `docs/explorer.html` (see CLAUDE.md), check no `<U+`, update CLAUDE.md and graphify note.

## Log
(append dated lines as items finish)
- Oct 22: step 1 done (no-Helene top-10 capture added to explorer About; report already shows capture with CI and Helene share). Step 2 done: `src/R/explorer_replays.R` writes `data/derived/explorer/replays_grid.csv`; `export_explorer.py` `build_replays` adds `DATA.replays` (Florence, Matthew, flagged in_training); template has a Storm selector (`switchReplay`). Tested in browser. TODO in step 6: call `build_explorer_replays(project_dir)` from the `_modeling.qmd` explorer chunk after `build_explorer_data`.
- Oct 22: step 3 code done (`src/python/build_nsi_grid.py` running; writes `data/derived/explorer/nsi_grid.csv`, resumable via `data/derived/nsi_county_cache/`; export adds grid columns buildings/res_units/pop_night/struct_value_musd; place card shows them). Step 4 code done (`src/R/explorer_crossings.R` -> crossings.csv; `build_crossings` in export; Road crossings tab with CSV). Step 5 README hook/links/team names done; team ROLES not added (ask Kent, do not invent). TODO: run export after NSI finishes, browser-test Road crossings tab and place card, wire `build_explorer_crossings` into `_modeling.qmd`, step 6.
- Oct 22: steps 3 and 4 done and browser-tested (NSI: 4.93M buildings aggregated; 17,380 crossings; explorer 3.8 MB). Remaining: step 6 (render, docs rebuild, CLAUDE.md, graphify note), team roles in README (ask Kent), brief update.
- Oct 22: step 6 done: final report re-rendered (86 MB, no <U+), docs/index.html (37 MB) and docs/explorer.html rebuilt, CLAUDE.md and brief updated. Not done: team roles in README (Kent to supply), graphify doc nodes, vault log line, git commit/push (Kent decides).
