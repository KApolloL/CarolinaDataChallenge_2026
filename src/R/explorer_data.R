# ============================================================
# Carolina HighGround: map data for the interactive explorer
# ============================================================
#
# build_explorer_data() writes, under data/derived/explorer/:
#   grid.csv            one row per gridMET cell (center in NC or within 2 km)
#   counties.geojson    simplified NC counties with region and study flags
#   hillshade.png/.json grayscale terrain base layer and its bounds
#   meta.json           grid geometry, Helene windows, vintages, runtime
# Each step is skipped when its output exists unless force = TRUE.
# Raw inputs are only read. Features reuse the training-feature functions.

build_explorer_data <- function(project_dir = ".", out_dir = "data/derived/explorer", force = FALSE) {
  t_start <- Sys.time()
  project_dir <- normalizePath(project_dir, mustWork = TRUE)
  if (!grepl("^(/|[A-Za-z]:)", out_dir)) out_dir <- file.path(project_dir, out_dir)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  pj <- function(...) file.path(project_dir, ...)

  suppressPackageStartupMessages({
    library(sf); library(terra); library(dplyr); library(jsonlite)
  })
  source(pj("src", "R", "utils.R"), local = FALSE)
  source(pj("src", "R", "create_spatial_features.R"), local = FALSE)
  source(pj("src", "R", "prepare_noaa.R"), local = FALSE)

  analysis_crs <- 32119L
  helene_total_days <- seq(as.Date("2024-09-24"), as.Date("2024-09-28"), by = "day")
  helene_ante_days  <- seq(as.Date("2024-09-17"), as.Date("2024-09-23"), by = "day")
  nlcd_year <- 2023L
  svi_release <- 2022L

  f_grid   <- file.path(out_dir, "grid.csv")
  f_cty    <- file.path(out_dir, "counties.geojson")
  f_png    <- file.path(out_dir, "hillshade.png")
  f_hsjson <- file.path(out_dir, "hillshade.json")
  f_meta   <- file.path(out_dir, "meta.json")
  need <- function(f) force || !file.exists(f)

  # ---- counties (needed by grid step too) -------------------------------
  lookup <- nc_county_lookup()
  cty_raw <- sf::st_read(pj("data", "raw", "reference", "nc_counties.gpkg"), quiet = TRUE)
  cty_raw$fips3 <- as.integer(cty_raw$COUNTYFP)
  study_names <- c("Buncombe", "Henderson", "Haywood", "Madison", "McDowell", "Transylvania",
                   "Yancey", "Avery", "Watauga", "Jackson", "Swain")

  if (need(f_cty)) {
    cty <- cty_raw |>
      dplyr::left_join(dplyr::select(lookup, fips3 = county_fips, region), by = "fips3") |>
      dplyr::transmute(name = tools::toTitleCase(tolower(NAME)), fips3, region, study = NAME %in% study_names | tools::toTitleCase(tolower(NAME)) %in% study_names)
    cty <- sf::st_transform(cty, analysis_crs)
    cty <- sf::st_simplify(cty, preserveTopology = TRUE, dTolerance = 400)
    cty <- sf::st_transform(cty, 4326)
    cty <- sf::st_set_precision(cty, 1e4)
    if (file.exists(f_cty)) file.remove(f_cty)
    sf::st_write(cty, f_cty, driver = "GeoJSON", quiet = TRUE,
                 layer_options = "COORDINATE_PRECISION=4")
    fw_log("info", "explorer counties", sprintf("Wrote %s (%d counties, %.0f KB)", basename(f_cty), nrow(cty), file.size(f_cty) / 1024))
  } else {
    fw_log("info", "explorer counties", "Exists; skipped.")
  }

  # ---- grid ----------------------------------------------------------------
  pr_file <- pj("data", "raw", "gridmet", "pr_2024.nc")
  pr <- terra::rast(pr_file)
  if (need(f_grid)) {
    t0 <- Sys.time()
    nc_b <- sf::st_read(pj("data", "raw", "nlcd", "north_carolina_boundary.gpkg"), quiet = TRUE) |>
      sf::st_transform(5070)
    cty_a <- cty_raw |> sf::st_transform(analysis_crs)

    nc_bb <- sf::st_bbox(sf::st_transform(nc_b, 4326))
    pad <- 0.1
    r0 <- terra::crop(pr[[1]], terra::ext(nc_bb["xmin"] - pad, nc_bb["xmax"] + pad,
                                          nc_bb["ymin"] - pad, nc_bb["ymax"] + pad))
    xy <- terra::xyFromCell(r0, seq_len(terra::ncell(r0)))
    cells <- tibble::tibble(lon = xy[, 1], lat = xy[, 2])
    pts5070 <- sf::st_as_sf(cells, coords = c("lon", "lat"), crs = 4326, remove = FALSE) |>
      sf::st_transform(5070)
    near <- lengths(sf::st_is_within_distance(pts5070, sf::st_union(nc_b), dist = 2000)) > 0
    cells <- cells[near, ]
    cells$cell_id <- seq_len(nrow(cells))
    fw_log("info", "explorer grid", sprintf("%d gridMET cells with centers in NC or within 2 km", nrow(cells)))

    pts <- sf::st_as_sf(cells, coords = c("lon", "lat"), crs = 4326, remove = FALSE) |>
      clean_spatial_layer(analysis_crs)
    pts$event_id <- pts$cell_id

    # county: containing, else nearest
    hit <- sf::st_intersects(pts, cty_a)
    idx <- vapply(hit, function(h) if (length(h)) h[[1]] else NA_integer_, integer(1))
    miss <- is.na(idx)
    if (any(miss)) idx[miss] <- sf::st_nearest_feature(pts[miss, ], cty_a)
    cells$county_fips3 <- cty_a$fips3[idx]

    # DEM / slope / impervious / hydrology
    dem_path <- pj("data", "raw", "dem_3dep", "3dep_dem_north_carolina_epsg32119.tif")
    ftr <- extract_raster_features(pts, dem_path, "elevation_m", character(), numeric())
    cells$elevation_m <- ftr$elevation_m
    cells$slope_degrees <- extract_raster_features(
      pts, pj("data", "raw", "dem_3dep", "slope_degrees_epsg32119.tif"), "slope_degrees",
      character(), numeric())$slope_degrees
    cells$impervious_mean_250m <- extract_raster_features(
      pts, pj("data", "raw", "nlcd", sprintf("annual_nlcd_fractional_impervious_%d_NC.tif", nlcd_year)),
      "impervious_point", "impervious_mean_250m", 250, valid_range = c(0, 100))$impervious_mean_250m
    fw_log("info", "explorer grid", "Terrain and imperviousness extracted")

    # streams
    flow_paths <- locate_nhd_layer("NHDFlowline", pj("data", "raw", "nhd", "extracted"),
                                   pj("data", "raw", "nhd", "NHD_H_North_Carolina_State_Shape.zip"))
    flowlines <- load_nhd_flowlines(flow_paths, c(460, 558), analysis_crs, NULL)
    cells$distance_to_stream_m <- nearest_distance_m(pts, flowlines)
    rm(flowlines); invisible(gc())
    fw_log("info", "explorer grid", "Distance to stream computed")

    # local relief (same definition as relief-5km in _modeling.qmd)
    dem <- terra::rast(dem_path)
    buffers <- terra::vect(sf::st_buffer(pts, 5000))
    hi <- terra::extract(dem, buffers, fun = max, na.rm = TRUE, ID = FALSE)[[1]]
    lo <- terra::extract(dem, buffers, fun = min, na.rm = TRUE, ID = FALSE)[[1]]
    rel <- hi - lo
    rel[!is.finite(rel)] <- NA_real_
    cells$local_relief_5km <- rel

    hand <- extract_raster_features(pts, pj("data", "derived", "hydro", "hand_m.tif"), "hand_m",
                                    character(), numeric(), valid_range = c(-5, 5000))
    cells$hand_m <- pmax(hand$hand_m, 0)
    cells$drainage_area_km2_max_250m <- extract_raster_features(
      pts, pj("data", "derived", "hydro", "flow_acc_km2.tif"), "drainage_at_point",
      "drainage_area_km2_max_250m", 250, valid_range = c(0, 1e6), fun = max)$drainage_area_km2_max_250m

    # SVI (2022 release on 2020 tracts)
    svi_files <- stats::setNames(list(pj("data", "raw", "svi", sprintf("svi_%d_nc_tract.csv", svi_release))),
                                 as.character(svi_release))
    tract_files <- list(`2010` = pj("data", "raw", "reference", "nc_tracts_2010.gpkg"),
                        `2020` = pj("data", "raw", "reference", "nc_tracts_2020.gpkg"))
    svi <- svi_tract_features(pts, rep(2024L, nrow(pts)), svi_files, tract_files, analysis_crs)
    cells$svi_rpl_themes <- svi$svi_rpl_themes

    # Helene rainfall straight from gridMET cells
    tm <- as.Date(terra::time(pr))
    vals <- terra::extract(pr, terra::vect(as.matrix(cells[, c("lon", "lat")]), crs = "EPSG:4326"), ID = FALSE)
    vals <- as.matrix(vals)
    wi <- match(helene_total_days, tm); ai <- match(helene_ante_days, tm)
    if (anyNA(wi) || anyNA(ai)) stop("Helene dates missing from pr_2024.nc")
    w <- vals[, wi, drop = FALSE]; a <- vals[, ai, drop = FALSE]
    ok_w <- rowSums(is.na(w)) == 0; ok_a <- rowSums(is.na(a)) == 0
    cells$helene_rain_total_mm <- ifelse(ok_w, rowSums(w), NA_real_)
    cells$helene_rain_max_1day_mm <- ifelse(ok_w, do.call(pmax, as.data.frame(w)), NA_real_)
    cells$helene_rain_antecedent_7d_mm <- ifelse(ok_a, rowSums(a), NA_real_)

    out <- cells[, c("cell_id", "lon", "lat", "county_fips3", "elevation_m", "slope_degrees",
                     "impervious_mean_250m", "distance_to_stream_m", "local_relief_5km",
                     "hand_m", "drainage_area_km2_max_250m", "svi_rpl_themes",
                     "helene_rain_total_mm", "helene_rain_max_1day_mm", "helene_rain_antecedent_7d_mm")]
    out$lon <- round(out$lon, 5); out$lat <- round(out$lat, 5)
    num <- setdiff(names(out), c("cell_id", "lon", "lat", "county_fips3"))
    out[num] <- lapply(out[num], function(x) round(x, 3))
    utils::write.csv(out, f_grid, row.names = FALSE, na = "")
    fw_log("info", "explorer grid", sprintf("Wrote %s (%d rows) in %.1f min", basename(f_grid), nrow(out),
                                            as.numeric(difftime(Sys.time(), t0, units = "mins"))))
  } else {
    fw_log("info", "explorer grid", "Exists; skipped.")
  }

  # ---- hillshade -------------------------------------------------------------
  if (need(f_png) || need(f_hsjson)) {
    t0 <- Sys.time()
    dem <- terra::rast(pj("data", "raw", "dem_3dep", "3dep_dem_north_carolina_epsg32119.tif"))
    bb <- sf::st_bbox(sf::st_transform(cty_raw, 4326))
    west <- floor(bb["xmin"] * 20) / 20 - 0.05; east <- ceiling(bb["xmax"] * 20) / 20 + 0.05
    south <- floor(bb["ymin"] * 20) / 20 - 0.05; north <- ceiling(bb["ymax"] * 20) / 20 + 0.05
    width <- 1300L
    height <- as.integer(round(width * (north - south) / (east - west) * 1.0))
    height <- max(height, 1L)
    tmpl <- terra::rast(nrows = height, ncols = width, xmin = west, xmax = east, ymin = south, ymax = north,
                        crs = "EPSG:4326")
    dem_agg <- terra::aggregate(dem, fact = 11, fun = "mean", na.rm = TRUE)
    dem_ll <- terra::project(dem_agg, tmpl, method = "bilinear")
    # exaggerate relief so the Piedmont and coast also show texture
    sl <- terra::terrain(dem_ll * 3, v = "slope", unit = "radians")
    as_ <- terra::terrain(dem_ll * 3, v = "aspect", unit = "radians")
    hs <- terra::shade(sl, as_, angle = 40, direction = 315, normalize = TRUE)
    m <- terra::values(hs, mat = FALSE)
    m[is.na(m)] <- 0.85
    # stretch contrast
    q <- stats::quantile(m, c(0.01, 0.99), na.rm = TRUE)
    m <- pmin(pmax((m - q[1]) / (q[2] - q[1]), 0), 1)
    m <- 0.12 + 0.86 * m
    img <- matrix(m, nrow = height, ncol = width, byrow = TRUE)
    png::writePNG(img, f_png)
    if (!requireNamespace("png", quietly = TRUE)) stop("package png needed")
    jsonlite::write_json(list(west = unname(west), east = unname(east), south = unname(south),
                              north = unname(north), width = width, height = height),
                         f_hsjson, auto_unbox = TRUE, digits = 6)
    fw_log("info", "explorer hillshade", sprintf("Wrote hillshade %dx%d, %.0f KB in %.1f min", width, height,
                                                 file.size(f_png) / 1024,
                                                 as.numeric(difftime(Sys.time(), t0, units = "mins"))))
  } else {
    fw_log("info", "explorer hillshade", "Exists; skipped.")
  }

  # ---- meta ----------------------------------------------------------------
  if (need(f_meta)) {
    g <- utils::read.csv(f_grid)
    dem_res <- terra::res(terra::rast(pj("data", "raw", "dem_3dep", "3dep_dem_north_carolina_epsg32119.tif")))[1]
    meta <- list(
      dlon = terra::res(pr)[1], dlat = terra::res(pr)[2],
      west = min(g$lon), east = max(g$lon), south = min(g$lat), north = max(g$lat),
      n = nrow(g),
      helene_total_window = c(format(min(helene_total_days)), format(max(helene_total_days))),
      helene_antecedent_window = c(format(min(helene_ante_days)), format(max(helene_ante_days))),
      dem_cell_size_m = dem_res, nlcd_year = nlcd_year, svi_release_year = svi_release,
      runtime_minutes = round(as.numeric(difftime(Sys.time(), t_start, units = "mins")), 2),
      generated = format(Sys.time(), "%Y-%m-%d %H:%M")
    )
    jsonlite::write_json(meta, f_meta, auto_unbox = TRUE, pretty = TRUE, digits = 8)
    fw_log("info", "explorer meta", "Wrote meta.json")
  } else {
    fw_log("info", "explorer meta", "Exists; skipped.")
  }

  invisible(list(grid = f_grid, counties = f_cty, hillshade = f_png, hillshade_json = f_hsjson, meta = f_meta))
}
