# ============================================================
# Carolina HighGround — optional data downloads
# ============================================================
#
# Refactored from src/data_scraper.R. Nothing here runs unless the
# QMD is rendered with `download_data: true` (or you call the
# functions yourself). Every function:
#   - skips files that already exist (raw data is never overwritten),
#   - reports success only after checking the file exists and is
#     non-empty,
#   - logs failures through fw_log() instead of stopping the render.
#
# Sources (same endpoints the original scripts used):
#   NOAA Storm Events  https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles/
#   NHD HR (state)     https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/NHD/State/Shape/
#   NCDOT structures   https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Structures/MapServer
#   Annual NLCD        https://di-nlcd.img.arcgis.com/arcgis/rest/services/USA_NLCD_Annual_LandCover_Fractional_Impervious_Surface/ImageServer
#   SSURGO             USDA Soil Data Access via soilDB::SDA_query()
#   DEM                elevatr::get_elev_raster(src = "aws") (AWS terrain tiles)
#   County boundaries  tigris::counties()
#
# Requires: scripts/utils.R, httr2, sf, terra, dplyr; optional soilDB,
# elevatr, tigris.

noaa_base_url <- "https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles/"
nhd_state_url <- "https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/NHD/State/Shape/NHD_H_North_Carolina_State_Shape.zip"
ncdot_service_url <- "https://gis11.services.ncdot.gov/arcgis/rest/services/NCDOT_Structures/MapServer"
nlcd_service_url <- paste0(
  "https://di-nlcd.img.arcgis.com/arcgis/rest/services/",
  "USA_NLCD_Annual_LandCover_Fractional_Impervious_Surface/ImageServer"
)

file_ok <- function(path) file.exists(path) && file.info(path)$size > 0

# Run one download step; log (not stop) on failure.
try_download <- function(label, expr) {
  tryCatch(
    expr,
    error = function(e) {
      fw_log("warning", input = label, message = paste("Download failed:", conditionMessage(e)),
             affects = "input remains missing")
      invisible(NULL)
    }
  )
}

# ------------------------------------------------------------
# NOAA Storm Events (details, fatalities, locations)
# ------------------------------------------------------------
# Reads the NCEI directory listing and downloads the newest revision
# for each requested year/table that is not already present locally.

download_noaa_storm_events <- function(years, dest_dir, tables = c("details", "fatalities", "locations")) {
  dir.create(dest_dir, recursive = TRUE, showWarnings = FALSE)
  listing <- httr2::request(noaa_base_url) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_perform() |>
    httr2::resp_body_string()
  available <- unique(stringr::str_extract_all(
    listing, "StormEvents_(details|fatalities|locations)-ftp_v1\\.0_d\\d{4}_c\\d{8}\\.csv\\.gz"
  )[[1]])

  for (tbl in tables) {
    for (yr in years) {
      local <- list.files(dest_dir, pattern = sprintf("^StormEvents_%s-ftp_v1\\.0_d%d_c\\d{8}\\.csv\\.gz$", tbl, yr))
      if (length(local) > 0) next
      candidates <- sort(available[stringr::str_detect(available, sprintf("^StormEvents_%s-ftp_v1\\.0_d%d_", tbl, yr))], decreasing = TRUE)
      if (length(candidates) == 0) {
        fw_log("warning", input = paste("NOAA", tbl, yr), message = "No file for this year on the NCEI listing.")
        next
      }
      dest <- file.path(dest_dir, candidates[[1]])
      try_download(paste("NOAA", tbl, yr), {
        httr2::request(paste0(noaa_base_url, candidates[[1]])) |>
          httr2::req_retry(max_tries = 3) |>
          httr2::req_perform(path = dest)
        if (file_ok(dest)) fw_log("info", input = paste("NOAA", tbl, yr), message = paste("Downloaded", basename(dest)))
      })
    }
  }
}

# ------------------------------------------------------------
# NHD High Resolution state shapefile ZIP
# ------------------------------------------------------------

download_nhd_state <- function(dest_zip) {
  if (file_ok(dest_zip)) return(invisible(dest_zip))
  dir.create(dirname(dest_zip), recursive = TRUE, showWarnings = FALSE)
  try_download("NHD state ZIP", {
    httr2::request(nhd_state_url) |>
      httr2::req_retry(max_tries = 3) |>
      httr2::req_timeout(3600) |>
      httr2::req_perform(path = dest_zip)
    if (file_ok(dest_zip)) fw_log("info", input = "NHD state ZIP", message = paste("Downloaded", basename(dest_zip)))
  })
}

# ------------------------------------------------------------
# NCDOT structures (layer 0) and culverts (layer 2)
# ------------------------------------------------------------

download_arcgis_layer <- function(service_url, layer_id, out_path, page_size = 2000L, output_crs = 4326L) {
  layer_url <- sprintf("%s/%s/query", service_url, layer_id)
  pages <- list()
  offset <- 0L
  repeat {
    tmp <- tempfile(fileext = ".geojson")
    httr2::request(layer_url) |>
      httr2::req_url_query(
        where = "1=1", outFields = "*", returnGeometry = "true", outSR = output_crs,
        f = "geojson", resultOffset = offset, resultRecordCount = page_size
      ) |>
      httr2::req_retry(max_tries = 3, backoff = \(x) 2^x) |>
      httr2::req_perform(path = tmp)
    page <- sf::st_read(tmp, quiet = TRUE)
    unlink(tmp)
    if (nrow(page) == 0) break
    pages[[length(pages) + 1]] <- page
    if (nrow(page) < page_size) break
    offset <- offset + nrow(page)
  }
  if (length(pages) == 0) stop("No records returned for layer ", layer_id)
  layer_name <- tools::file_path_sans_ext(basename(out_path))
  sf::st_write(dplyr::bind_rows(pages), out_path, layer = layer_name, quiet = TRUE)
}

download_ncdot <- function(culverts_path, structures_path) {
  targets <- list(list(id = 0L, path = structures_path, label = "NCDOT structures"),
                  list(id = 2L, path = culverts_path,   label = "NCDOT culverts"))
  for (t in targets) {
    if (file_ok(t$path)) next
    dir.create(dirname(t$path), recursive = TRUE, showWarnings = FALSE)
    try_download(t$label, {
      download_arcgis_layer(ncdot_service_url, t$id, t$path)
      if (file_ok(t$path)) fw_log("info", input = t$label, message = paste("Downloaded", basename(t$path)))
    })
  }
}

# ------------------------------------------------------------
# SSURGO tabular components and horizons (NC survey areas)
# ------------------------------------------------------------

download_ssurgo_tables <- function(soils_dir) {
  if (!requireNamespace("soilDB", quietly = TRUE)) {
    fw_log("warning", input = "SSURGO", message = "Package soilDB not installed; SSURGO download skipped.")
    return(invisible(NULL))
  }
  dir.create(soils_dir, recursive = TRUE, showWarnings = FALSE)
  queries <- list(
    nc_ssurgo_components = "
      SELECT legend.areasymbol, legend.areaname, mapunit.mukey, mapunit.musym, mapunit.muname,
             component.cokey, component.compname, component.comppct_r, component.hydgrp, component.drainagecl
      FROM legend
      INNER JOIN mapunit   ON mapunit.lkey = legend.lkey
      INNER JOIN component ON component.mukey = mapunit.mukey
      WHERE legend.areasymbol LIKE 'NC%'",
    nc_ssurgo_horizons = "
      SELECT legend.areasymbol, legend.areaname, mapunit.mukey, mapunit.musym, mapunit.muname,
             component.cokey, component.compname, component.comppct_r,
             chorizon.chkey, chorizon.hzdept_r, chorizon.hzdepb_r, chorizon.ksat_r, chorizon.awc_r
      FROM legend
      INNER JOIN mapunit   ON mapunit.lkey = legend.lkey
      INNER JOIN component ON component.mukey = mapunit.mukey
      INNER JOIN chorizon  ON chorizon.cokey = component.cokey
      WHERE legend.areasymbol LIKE 'NC%'"
  )
  for (nm in names(queries)) {
    csv <- file.path(soils_dir, paste0(nm, ".csv"))
    if (file_ok(csv)) next
    try_download(paste("SSURGO", nm), {
      result <- soilDB::SDA_query(queries[[nm]]) |> tibble::as_tibble() |> janitor::clean_names()
      readr::write_csv(result, csv)
      saveRDS(result, file.path(soils_dir, paste0(nm, ".rds")))
      if (nm == "nc_ssurgo_components") {
        result |>
          dplyr::mutate(comppct_r = suppressWarnings(as.numeric(comppct_r))) |>
          dplyr::group_by(mukey) |>
          dplyr::slice_max(comppct_r, n = 1, with_ties = FALSE) |>
          dplyr::ungroup() |>
          readr::write_csv(file.path(soils_dir, "nc_ssurgo_dominant_components.csv"))
      }
      if (file_ok(csv)) fw_log("info", input = "SSURGO", message = paste("Downloaded", basename(csv)))
    })
  }
}

# ------------------------------------------------------------
# County boundaries (used for maps and study-area extent only)
# ------------------------------------------------------------

download_nc_counties <- function(dest_gpkg, year = 2023) {
  if (file_ok(dest_gpkg)) return(invisible(dest_gpkg))
  if (!requireNamespace("tigris", quietly = TRUE)) {
    fw_log("warning", input = "County boundaries", message = "Package tigris not installed; download skipped.")
    return(invisible(NULL))
  }
  dir.create(dirname(dest_gpkg), recursive = TRUE, showWarnings = FALSE)
  try_download("County boundaries", {
    tigris::counties(state = "NC", cb = TRUE, year = year, class = "sf") |>
      sf::st_write(dest_gpkg, layer = "nc_counties", quiet = TRUE)
    if (file_ok(dest_gpkg)) fw_log("info", input = "County boundaries", message = paste("Downloaded", basename(dest_gpkg)))
  })
}

# ------------------------------------------------------------
# Annual NLCD fractional imperviousness (single year, NC extent)
# ------------------------------------------------------------

download_nlcd_impervious <- function(out_path, year, nc_boundary_gpkg, pixel_size_m = 30L, max_dimension = 20000L) {
  if (file_ok(out_path)) return(invisible(out_path))
  if (!file_ok(nc_boundary_gpkg)) {
    fw_log("warning", input = "Annual NLCD", message = "NC boundary GeoPackage is missing; NLCD download skipped.")
    return(invisible(NULL))
  }
  try_download("Annual NLCD", {
    boundary <- sf::st_read(nc_boundary_gpkg, quiet = TRUE) |> sf::st_transform(5070)
    bb <- sf::st_bbox(boundary)
    w <- ceiling((bb["xmax"] - bb["xmin"]) / pixel_size_m)
    h <- ceiling((bb["ymax"] - bb["ymin"]) / pixel_size_m)
    scale <- max(1, w / max_dimension, h / max_dimension)
    size <- paste(ceiling(w / scale), ceiling(h / scale), sep = ",")
    t0 <- as.numeric(as.POSIXct(sprintf("%d-01-01", year), tz = "UTC")) * 1000
    t1 <- as.numeric(as.POSIXct(sprintf("%d-12-31 23:59:59", year), tz = "UTC")) * 1000
    raw_path <- sub("\\.tif$", "_raw.tif", out_path)
    httr2::request(paste0(nlcd_service_url, "/exportImage")) |>
      httr2::req_url_query(
        bbox = paste(bb, collapse = ","), bboxSR = 5070, imageSR = 5070, size = size,
        format = "tiff", pixelType = "U8", interpolation = "Nearest", compression = "LZW",
        noData = 255L, noDataInterpretation = "esriNoDataMatch", time = paste(t0, t1, sep = ","),
        f = "image"
      ) |>
      httr2::req_retry(max_tries = 3) |>
      httr2::req_perform(path = raw_path)
    r <- terra::rast(raw_path)
    v <- terra::vect(boundary)
    terra::mask(terra::crop(r, v), v) |>
      terra::writeRaster(out_path, gdal = c("COMPRESS=LZW", "TILED=YES"))
    if (file_ok(out_path)) fw_log("info", input = "Annual NLCD", message = paste("Downloaded", basename(out_path)))
  })
}

# ------------------------------------------------------------
# DEM and terrain derivatives
# ------------------------------------------------------------

download_dem_terrain <- function(dem_dir, nc_boundary_gpkg, analysis_crs, zoom = 10L) {
  dem_path <- file.path(dem_dir, sprintf("3dep_dem_north_carolina_epsg%s.tif", analysis_crs))
  if (file_ok(dem_path)) return(invisible(dem_path))
  if (!requireNamespace("elevatr", quietly = TRUE) || !file_ok(nc_boundary_gpkg)) {
    fw_log("warning", input = "DEM", message = "elevatr not installed or NC boundary missing; DEM download skipped.")
    return(invisible(NULL))
  }
  dir.create(dem_dir, recursive = TRUE, showWarnings = FALSE)
  try_download("DEM", {
    boundary <- sf::st_read(nc_boundary_gpkg, quiet = TRUE)
    dem_raw <- elevatr::get_elev_raster(locations = boundary, z = zoom, clip = "locations", src = "aws") |>
      terra::rast()
    v <- terra::project(terra::vect(boundary), terra::crs(dem_raw))
    dem <- terra::mask(terra::crop(dem_raw, v), v) |>
      terra::project(paste0("EPSG:", analysis_crs), method = "bilinear")
    terra::writeRaster(dem, dem_path, gdal = c("COMPRESS=LZW", "TILED=YES"))
    terrain <- terra::terrain(dem, v = c("slope", "aspect", "roughness"), unit = "degrees", neighbors = 8)
    terra::writeRaster(terrain[["slope"]],     file.path(dem_dir, sprintf("slope_degrees_epsg%s.tif", analysis_crs)))
    terra::writeRaster(terrain[["aspect"]],    file.path(dem_dir, sprintf("aspect_degrees_epsg%s.tif", analysis_crs)))
    terra::writeRaster(terrain[["roughness"]], file.path(dem_dir, sprintf("roughness_epsg%s.tif", analysis_crs)))
    if (file_ok(dem_path)) fw_log("info", input = "DEM", message = paste("Downloaded and derived terrain for", basename(dem_path)))
  })
}

# ------------------------------------------------------------
# Entry point used by analysis.qmd when download_data is TRUE
# ------------------------------------------------------------

download_all_missing <- function(paths, years, nlcd_year, analysis_crs) {
  try_download("NOAA Storm Events", download_noaa_storm_events(years, paths$noaa_dir))
  download_nhd_state(paths$nhd_zip)
  download_ncdot(paths$ncdot_culverts, paths$ncdot_structures)
  download_ssurgo_tables(paths$soils_dir)
  download_nc_counties(paths$county_boundaries)
  download_nlcd_impervious(paths$nlcd, nlcd_year, paths$nc_boundary)
  download_dem_terrain(dirname(paths$dem), paths$nc_boundary, analysis_crs)
}
