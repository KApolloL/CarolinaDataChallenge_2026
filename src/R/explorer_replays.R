# Rainfall for extra storm replays (Florence 2018, Matthew 2016) on the explorer grid.
# Reads data/derived/explorer/grid.csv (lon, lat), writes replays_grid.csv with
# <id>_rain_total_mm, <id>_rain_max_1day_mm, <id>_rain_antecedent_7d_mm per storm.
# Rain windows follow the Helene convention: a total window plus the 7 days before it.

REPLAY_STORMS <- list(
  florence = list(total = c("2018-09-13", "2018-09-18"), ante = c("2018-09-06", "2018-09-12")),
  matthew  = list(total = c("2016-10-07", "2016-10-11"), ante = c("2016-09-30", "2016-10-06"))
)

build_explorer_replays <- function(project_dir = ".", out_dir = "data/derived/explorer", force = FALSE) {
  suppressPackageStartupMessages(library(terra))
  project_dir <- normalizePath(project_dir, mustWork = TRUE)
  if (!grepl("^(/|[A-Za-z]:)", out_dir)) out_dir <- file.path(project_dir, out_dir)
  f_out <- file.path(out_dir, "replays_grid.csv")
  f_grid <- file.path(out_dir, "grid.csv")
  if (!file.exists(f_grid)) stop("grid.csv missing: run build_explorer_data() first")
  if (!force && file.exists(f_out) && file.mtime(f_out) > file.mtime(f_grid)) return(invisible(f_out))
  g <- utils::read.csv(f_grid)
  pts <- terra::vect(as.matrix(g[, c("lon", "lat")]), crs = "EPSG:4326")
  out <- data.frame(cell_id = g$cell_id)
  for (id in names(REPLAY_STORMS)) {
    st <- REPLAY_STORMS[[id]]
    d_tot <- seq(as.Date(st$total[1]), as.Date(st$total[2]), by = "day")
    d_ant <- seq(as.Date(st$ante[1]), as.Date(st$ante[2]), by = "day")
    yr <- unique(format(c(d_tot, d_ant), "%Y"))
    stopifnot(length(yr) == 1)
    r <- terra::rast(file.path(project_dir, "data", "raw", "gridmet", sprintf("pr_%s.nc", yr)))
    tm <- as.Date(terra::time(r))
    v <- as.matrix(terra::extract(r, pts, ID = FALSE))
    wi <- match(d_tot, tm); ai <- match(d_ant, tm)
    if (anyNA(wi) || anyNA(ai)) stop("dates missing from gridMET for ", id)
    w <- v[, wi, drop = FALSE]; a <- v[, ai, drop = FALSE]
    ok_w <- rowSums(is.na(w)) == 0; ok_a <- rowSums(is.na(a)) == 0
    out[[paste0(id, "_rain_total_mm")]] <- round(ifelse(ok_w, rowSums(w), NA_real_), 1)
    out[[paste0(id, "_rain_max_1day_mm")]] <- round(ifelse(ok_w, do.call(pmax, as.data.frame(w)), NA_real_), 1)
    out[[paste0(id, "_rain_antecedent_7d_mm")]] <- round(ifelse(ok_a, rowSums(a), NA_real_), 1)
  }
  utils::write.csv(out, f_out, row.names = FALSE, na = "")
  invisible(f_out)
}
