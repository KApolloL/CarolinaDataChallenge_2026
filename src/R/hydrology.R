# hydrology.R
# Hydrologic rasters (breached DEM, D8 pointer, flow accumulation, streams, HAND)
# built with WhiteboxTools via the `whitebox` package.

#' Build hydrologic rasters from a DEM
#'
#' @param dem_path Path to a single-band projected DEM in meters (NA outside the study area).
#' @param out_dir Output directory (created if missing).
#' @param stream_threshold_km2 Minimum upslope area (km2) for a cell to be a stream.
#' @param overwrite If FALSE, steps whose output file exists are skipped.
#' @return Named list of output paths: dem_breached, d8_pointer, flow_acc_km2,
#'   streams, hand_m. Step timings (seconds) are attached as attribute "timings".
#' @details HAND is computed on the breached DEM with streams taken from the same
#'   D8 accumulation, so the drainage network and HAND are consistent. Rivers that
#'   enter the study area from outside are truncated at the edge, so their
#'   accumulation is underestimated.
build_hydro_rasters <- function(dem_path,
                                out_dir = "data/derived/hydro",
                                stream_threshold_km2 = 1,
                                overwrite = FALSE) {
  stopifnot(file.exists(dem_path))
  suppressPackageStartupMessages({ library(terra); library(whitebox) })
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  out_dir <- normalizePath(out_dir)
  dem_path <- normalizePath(dem_path)
  wbt_options(verbose = FALSE, max_procs = max(1L, parallel::detectCores() - 1L))

  p <- function(f) file.path(out_dir, f)
  paths <- list(dem_breached = p("dem_breached.tif"), d8_pointer = p("d8_pointer.tif"),
                flow_acc_km2 = p("flow_acc_km2.tif"), streams = p("streams.tif"),
                hand_m = p("hand_m.tif"))
  dem_in  <- p("dem_input_nodata.tif")   # intermediate: NaN -> explicit nodata
  acc_m2  <- p("flow_acc_m2_tmp.tif")    # intermediate
  tmp_b1  <- p("dem_breach1_tmp.tif")    # intermediate
  timings <- c()
  need <- function(path) overwrite || !file.exists(path)
  timed <- function(name, expr) {
    t0 <- Sys.time(); force(expr)
    timings[name] <<- as.numeric(difftime(Sys.time(), t0, units = "secs"))
    message(sprintf("[hydro] %-14s %.1f s", name, timings[name]))
  }

  # 1. Breach depressions
  if (need(paths$dem_breached)) timed("dem_breached", {
    dem <- rast(dem_path)
    writeRaster(dem, dem_in, overwrite = TRUE, NAflag = -32768, datatype = "FLT4S")
    # least-cost breach: dist = max breach length in cells; fill = TRUE fills leftover pits
    ok <- tryCatch({
      wbt_breach_depressions_least_cost(dem_in, tmp_b1, dist = 100, fill = TRUE)
      file.exists(tmp_b1)
    }, error = function(e) FALSE)
    if (!ok) {
      message("[hydro] least-cost breach failed; using wbt_breach_depressions + fill")
      wbt_breach_depressions(dem_in, tmp_b1)
    }
    wbt_fill_depressions(tmp_b1, paths$dem_breached)  # catch any remaining pits
    unlink(c(tmp_b1))
  })

  # 2. D8 pointer
  if (need(paths$d8_pointer)) timed("d8_pointer",
    wbt_d8_pointer(paths$dem_breached, paths$d8_pointer))

  # 3. Flow accumulation (catchment area, m2 -> km2)
  if (need(paths$flow_acc_km2)) timed("flow_acc_km2", {
    wbt_d8_flow_accumulation(paths$dem_breached, acc_m2, out_type = "catchment area")
    a <- rast(acc_m2) / 1e6
    writeRaster(a, paths$flow_acc_km2, overwrite = TRUE, datatype = "FLT4S", NAflag = -32768)
    unlink(acc_m2)
  })

  # 4. Streams
  if (need(paths$streams)) timed("streams",
    wbt_extract_streams(paths$flow_acc_km2, paths$streams, threshold = stream_threshold_km2))

  # 5. HAND
  if (need(paths$hand_m)) timed("hand_m",
    wbt_elevation_above_stream(paths$dem_breached, paths$streams, paths$hand_m))

  unlink(dem_in)
  attr(paths, "timings") <- timings
  paths
}
