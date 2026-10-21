# ============================================================
# Carolina HighGround — event-level rainfall features (gridMET)
# ============================================================
#
# Rainfall totals around each NOAA event, from gridMET daily
# precipitation (4 km, mm/day, WGS84), one NetCDF per year
# (data/raw/gridmet/pr_YYYY.nc, variable precipitation_amount).
#
# Window rule (uses only days up to the event end, never later):
#   start = event_date - pad_days
#   end   = max(start, min(coalesce(event_end_date, event_date),
#                          event_date + max_window_days - 2))
#   (defaults: pad 1, max 8 days, so end <= event_date + 6)
#   antecedent window = the antecedent_days days before start
#
# The cap keeps multi-week flood records from summing weeks of
# unrelated rain. gridMET days run 24 h ending 00:00 UTC, so a
# "day" is not a local calendar day; pad_days absorbs most of
# that offset.
#
# Requires: scripts/utils.R, terra, dplyr, readr, digest.

#' Event-level rainfall features from gridMET daily precipitation
#'
#' @param events Data frame with event_id, longitude, latitude (WGS84,
#'   NA allowed), event_date, event_end_date (Date, end may be NA).
#' @param gridmet_dir Folder holding pr_YYYY.nc files.
#' @param out_csv Output CSV path; a sidecar `<out_csv>.sig` holds the
#'   cache signature. Recomputed only when inputs or parameters change.
#' @param pad_days Days before event_date included in the window.
#' @param max_window_days Maximum window length in days.
#' @param antecedent_days Length of the antecedent window before start.
#' @return Tibble: event_id, rain_event_total_mm, rain_max_1day_mm,
#'   rain_antecedent_7d_mm. NA when the event has no coordinates, falls
#'   outside the grid, or any window day is missing from the files.
compute_event_rainfall <- function(events, gridmet_dir, out_csv,
                                   pad_days = 1, max_window_days = 8,
                                   antecedent_days = 7) {
  nc_files <- sort(list.files(gridmet_dir, pattern = "^pr_\\d{4}\\.nc$", full.names = TRUE))
  if (length(nc_files) == 0) {
    fw_log("warning", input = "gridMET", message = paste("No pr_YYYY.nc files in", gridmet_dir),
           affects = "rainfall features")
    return(dplyr::tibble(event_id = events$event_id, rain_event_total_mm = NA_real_,
                         rain_max_1day_mm = NA_real_, rain_antecedent_7d_mm = NA_real_))
  }

  # --- cache check ---
  sig <- paste(
    file_signature(nc_files),
    digest::digest(list(
      dplyr::select(events, event_id, longitude, latitude, event_date, event_end_date),
      pad_days, max_window_days, antecedent_days
    )),
    sep = "||"
  )
  sig_path <- paste0(out_csv, ".sig")
  if (file.exists(out_csv) && file.exists(sig_path) && identical(readLines(sig_path, warn = FALSE), sig)) {
    fw_log("info", input = "gridMET", message = "Rainfall features cached; reusing.")
    return(readr::read_csv(out_csv, show_col_types = FALSE))
  }

  # --- windows (vectorised) ---
  ev <- dplyr::mutate(
    events,
    win_start = event_date - pad_days,
    win_end   = pmax(win_start, pmin(dplyr::coalesce(event_end_date, event_date),
                                     event_date + (max_window_days - 2))),
    ante_start = win_start - antecedent_days
  )
  located <- !is.na(ev$longitude) & !is.na(ev$latitude) & !is.na(ev$event_date)
  idx <- which(located)

  # --- one extract per year file: points x days ---
  nc_ext <- terra::ext(-84.6, -75.2, 33.6, 36.8)
  pts <- terra::vect(cbind(ev$longitude[idx], ev$latitude[idx]), crs = "EPSG:4326")
  mats <- lapply(nc_files, function(f) {
    r <- terra::crop(terra::rast(f), nc_ext)
    m <- as.matrix(terra::extract(r, pts, ID = FALSE))
    colnames(m) <- format(terra::time(r), "%Y-%m-%d")
    m
  })
  rain <- do.call(cbind, mats)                 # points x days, all years joined
  day_names <- colnames(rain)
  if (anyDuplicated(day_names)) {
    fw_log("warning", input = "gridMET", message = "Duplicate dates across files; keeping first.",
           affects = "rainfall features")
    keep <- !duplicated(day_names)
    rain <- rain[, keep, drop = FALSE]
    day_names <- day_names[keep]
  }
  day_vals <- as.Date(day_names)

  # --- per-event stats from matrix columns (no terra calls) ---
  out <- matrix(NA_real_, nrow = nrow(ev), ncol = 3)
  col_of <- function(d) match(d, day_vals)
  for (k in seq_along(idx)) {
    i <- idx[k]
    w <- col_of(seq(ev$win_start[i], ev$win_end[i], by = "day"))
    a <- col_of(seq(ev$ante_start[i], ev$win_start[i] - 1, by = "day"))
    if (anyNA(w)) next
    v <- rain[k, w]
    if (anyNA(v)) next
    out[i, 1] <- sum(v)
    out[i, 2] <- max(v)
    if (!anyNA(a) && !anyNA(rain[k, a])) out[i, 3] <- sum(rain[k, a])
  }

  res <- dplyr::tibble(
    event_id = ev$event_id,
    rain_event_total_mm = out[, 1],
    rain_max_1day_mm = out[, 2],
    rain_antecedent_7d_mm = out[, 3]
  )
  n_loc <- sum(located)
  n_ok <- sum(!is.na(res$rain_event_total_mm))
  if (n_loc > 0 && n_ok / n_loc < 0.95) {
    fw_log("warning", input = "gridMET",
           message = sprintf("Rainfall coverage low: %d of %d located events have a total.", n_ok, n_loc),
           affects = "rainfall features")
  }

  dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(res, out_csv)
  writeLines(sig, sig_path)
  res
}
