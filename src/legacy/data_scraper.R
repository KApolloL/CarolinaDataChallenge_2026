# ============================================================
# Download NCDOT Structures, USDA SSURGO, NLCD Imperviousness,
# and USGS 3DEP Elevation for North Carolina
# ============================================================

# Install once if needed:
#
# install.packages(c(
#   "sf", "tidyverse", "httr2", "jsonlite",
#   "soilDB", "janitor", "terra", "tigris", "elevatr"
# ))

# ============================================================
# 1. Load packages
# ============================================================

suppressPackageStartupMessages({
  library(sf)
  library(tidyverse)
  library(httr2)
  library(jsonlite)  # FIX: was missing; write_json() requires it
  library(soilDB)
  library(janitor)
  library(terra)
  library(tigris)
  library(elevatr)   # FIX: was loaded mid-script; moved here
  # sbtools removed — was imported but never used
})

options(tigris_use_cache = TRUE)

# ============================================================
# 2. Configure project directories
# ============================================================

project_dir <- "/Users/kentalee/Documents/KALProjects/UNCProjects/CarolinaDataChallenge_2026"

# FIX: dem dir was defined separately in the DEM section; unified here
dirs <- list(
  data    = file.path(project_dir, "data"),
  results = file.path(project_dir, "outs"),
  ncdot   = file.path(project_dir, "data", "ncdot"),
  usda    = file.path(project_dir, "data", "usda_soils"),
  nlcd    = file.path(project_dir, "data", "nlcd_fractional_impervious"),
  dem     = file.path(project_dir, "data", "dem_3dep")
)

invisible(lapply(dirs, dir.create, recursive = TRUE, showWarnings = FALSE))

results_dir <- dirs$results
ncdot_dir   <- dirs$ncdot
usda_dir    <- dirs$usda
nlcd_dir    <- dirs$nlcd
dem_dir     <- dirs$dem

# ============================================================
# 3. Helper functions
# ============================================================

# Null-coalescing operator (built-in R >= 4.4; defined here for compatibility)
`%||%` <- function(x, y) if (is.null(x)) y else x

# ============================================================
# 4. Download NCDOT structures and culverts
# ============================================================

ncdot_service_url <- paste0(
  "https://gis11.services.ncdot.gov/",
  "arcgis/rest/services/NCDOT_Structures/MapServer"
)

# --- 4.1 Layer metadata ---

message("Retrieving NCDOT layer metadata...")

ncdot_layers <- request(ncdot_service_url) |>
  req_url_query(f = "json") |>
  req_retry(max_tries = 3L) |>
  req_perform() |>
  resp_body_json(simplifyVector = TRUE) |>
  (\(x) as_tibble(x$layers))() |>
  select(id, name, type)

print(ncdot_layers)

# --- 4.2 Paginated ArcGIS REST download helper ---

download_arcgis_layer <- function(
    service_url,
    layer_id,
    output_name,
    output_directory,
    page_size  = 2000L,
    output_crs = 4326L
) {
  layer_url <- sprintf("%s/%s/query", service_url, layer_id)
  all_pages <- list()
  offset    <- 0L
  page_num  <- 1L
  
  repeat {
    message(sprintf("  Layer %s – page %d (offset %d)...",
                    layer_id, page_num, offset))
    
    tmp <- tempfile(fileext = ".geojson")
    
    request(layer_url) |>
      req_url_query(
        where             = "1=1",
        outFields         = "*",
        returnGeometry    = "true",
        outSR             = output_crs,
        f                 = "geojson",
        resultOffset      = offset,
        resultRecordCount = page_size
      ) |>
      req_retry(max_tries = 3L, backoff = \(x) 2^x) |>
      req_perform() |>
      resp_body_raw() |>
      writeBin(tmp)
    
    page_data <- tryCatch(
      st_read(tmp, quiet = TRUE),
      error = function(e) {
        unlink(tmp)
        stop(sprintf("GeoJSON parse error (layer %s): %s",
                     layer_id, e$message))
      }
    )
    unlink(tmp)
    
    if (nrow(page_data) == 0L) break
    
    message(sprintf("    Retrieved %d records", nrow(page_data)))
    all_pages[[page_num]] <- page_data
    
    if (nrow(page_data) < page_size) break
    
    offset   <- offset + nrow(page_data)
    page_num <- page_num + 1L
  }
  
  if (length(all_pages) == 0L) {
    warning("No records returned for layer ", layer_id)
    return(invisible(NULL))
  }
  
  layer_data <- do.call(rbind, all_pages) |>
    st_transform(crs = output_crs)
  
  out_path <- file.path(output_directory, paste0(output_name, ".gpkg"))
  st_write(layer_data, out_path,
           layer = output_name, delete_dsn = TRUE, quiet = TRUE)
  
  message(sprintf("Saved %d records → %s", nrow(layer_data), out_path))
  invisible(layer_data)
}

# --- 4.3 Download structure layers ---

# Layer 0 = structures; Layer 2 = culverts
ncdot_structures <- download_arcgis_layer(
  ncdot_service_url, 0L, "ncdot_structures_nc", ncdot_dir
)

ncdot_culverts <- download_arcgis_layer(
  ncdot_service_url, 2L, "ncdot_culverts_nc", ncdot_dir
)

# ============================================================
# 5. Query USDA SSURGO data
# ============================================================

# Soil Data Access may limit large queries; split by areasymbol if needed.

run_ssurgo_query <- function(sql, query_name, output_directory, output_basename) {
  message("Querying SSURGO: ", query_name)
  result <- tryCatch(
    SDA_query(sql) |> as_tibble() |> clean_names(),
    error = function(e) stop("SSURGO [", query_name, "] failed: ", e$message)
  )
  write_csv(result, file.path(output_directory, paste0(output_basename, ".csv")))
  saveRDS(result,   file.path(output_directory, paste0(output_basename, ".rds")))
  message(sprintf("Saved %d rows → %s/%s.csv",
                  nrow(result), output_directory, output_basename))
  result
}

soil_component_sql <- "
  SELECT
      legend.areasymbol,   legend.areaname,
      mapunit.mukey,       mapunit.musym,     mapunit.muname,
      component.cokey,     component.compname,
      component.comppct_r, component.hydgrp,  component.drainagecl
  FROM legend
  INNER JOIN mapunit   ON mapunit.lkey    = legend.lkey
  INNER JOIN component ON component.mukey = mapunit.mukey
  WHERE legend.areasymbol LIKE 'NC%'
"

soil_horizon_sql <- "
  SELECT
      legend.areasymbol,    legend.areaname,
      mapunit.mukey,        mapunit.musym,      mapunit.muname,
      component.cokey,      component.compname, component.comppct_r,
      chorizon.chkey,
      chorizon.hzdept_r,    chorizon.hzdepb_r,
      chorizon.ksat_r,      chorizon.awc_r
  FROM legend
  INNER JOIN mapunit   ON mapunit.lkey    = legend.lkey
  INNER JOIN component ON component.mukey = mapunit.mukey
  INNER JOIN chorizon  ON chorizon.cokey  = component.cokey
  WHERE legend.areasymbol LIKE 'NC%'
"

soil_components_nc <- run_ssurgo_query(
  soil_component_sql, "components", usda_dir, "nc_ssurgo_components"
)

soil_horizons_nc <- run_ssurgo_query(
  soil_horizon_sql, "horizons", usda_dir, "nc_ssurgo_horizons"
)

dominant_soils_nc <- soil_components_nc |>
  mutate(comppct_r = suppressWarnings(as.numeric(comppct_r))) |>
  group_by(mukey) |>
  slice_max(order_by = comppct_r, n = 1, with_ties = FALSE) |>
  ungroup()

write_csv(dominant_soils_nc,
          file.path(usda_dir, "nc_ssurgo_dominant_components.csv"))

# ============================================================
# 6. Download Annual NLCD Fractional Impervious Surface
# ============================================================

# FIX: nlcd_year was defined a second time in the original §6.2; deduplicated.
nlcd_year        <- 2023L
service_epsg     <- 5070L
nlcd_service_url <- paste0(
  "https://di-nlcd.img.arcgis.com/arcgis/rest/services/",
  "USA_NLCD_Annual_LandCover_Fractional_Impervious_Surface/ImageServer"
)

# --- 6.1 North Carolina boundary ---

message("Downloading North Carolina boundary...")

nc_boundary <- tigris::states(year = 2023, cb = TRUE, class = "sf") |>
  filter(STUSPS == "NC") |>
  st_transform(service_epsg)

st_write(nc_boundary,
         file.path(nlcd_dir, "north_carolina_boundary.gpkg"),
         delete_dsn = TRUE, quiet = TRUE)

# --- 6.2 ImageServer metadata ---

message("Retrieving Annual NLCD ImageServer metadata...")

nlcd_service_metadata <- request(nlcd_service_url) |>
  req_url_query(f = "json") |>
  req_retry(max_tries = 3L, backoff = \(x) 2^x) |>
  req_perform() |>
  resp_body_json(simplifyVector = FALSE)

write_json(nlcd_service_metadata,
           file.path(nlcd_dir, "annual_nlcd_image_server_metadata.json"),
           pretty = TRUE, auto_unbox = TRUE)

# --- 6.3 Bounding box ---

# FIX: nc_boundary is already EPSG:5070; the redundant st_transform(5070)
# present in the original §6.4 has been removed.
nc_bbox     <- st_bbox(nc_boundary)
bbox_string <- paste(
  nc_bbox["xmin"], nc_bbox["ymin"],
  nc_bbox["xmax"], nc_bbox["ymax"],
  sep = ","
)
message("North Carolina bounding box: ", bbox_string)

# --- 6.4 Request dimensions (30 m pixels; cap at 20 000 px per side) ---

pixel_size_m  <- 30L
max_dimension <- 20000L

nc_width  <- ceiling((nc_bbox["xmax"] - nc_bbox["xmin"]) / pixel_size_m)
nc_height <- ceiling((nc_bbox["ymax"] - nc_bbox["ymin"]) / pixel_size_m)

if (nc_width > max_dimension || nc_height > max_dimension) {
  scale_factor <- max(nc_width / max_dimension, nc_height / max_dimension)
  nc_width     <- ceiling(nc_width  / scale_factor)
  nc_height    <- ceiling(nc_height / scale_factor)
}

image_size <- paste(nc_width, nc_height, sep = ",")
message("Requested image size: ", image_size)

# --- 6.5 Optional time filter ---

time_query <- NULL

if (!is.null(nlcd_service_metadata$timeInfo)) {
  t_start    <- as.numeric(
    as.POSIXct(sprintf("%d-01-01", nlcd_year), tz = "UTC")
  ) * 1000
  t_end      <- as.numeric(
    as.POSIXct(sprintf("%d-12-31 23:59:59", nlcd_year), tz = "UTC")
  ) * 1000
  time_query <- paste(t_start, t_end, sep = ",")
  message("Time filtering enabled for ", nlcd_year)
} else {
  message("Service did not expose timeInfo; no time filter applied.")
}

# --- 6.6 Download raw raster ---

nlcd_raw_path <- file.path(
  nlcd_dir,
  sprintf("annual_nlcd_fractional_impervious_%d_NC_raw.tif", nlcd_year)
)

message("Requesting NLCD raster from ImageServer...")

nlcd_req <- request(paste0(nlcd_service_url, "/exportImage")) |>
  req_url_query(
    bbox                 = bbox_string,
    bboxSR               = service_epsg,
    imageSR              = service_epsg,
    size                 = image_size,
    format               = "tiff",
    pixelType            = "U8",
    interpolation        = "Nearest",
    compression          = "LZW",
    noData               = 255L,
    noDataInterpretation = "esriNoDataMatch",
    f                    = "image"
  )

if (!is.null(time_query)) {
  nlcd_req <- nlcd_req |> req_url_query(time = time_query)
}

nlcd_req |>
  req_retry(max_tries = 3L, backoff = \(x) 2^x) |>
  req_perform() |>
  resp_body_raw() |>
  writeBin(nlcd_raw_path)

if (!file.exists(nlcd_raw_path) || file.info(nlcd_raw_path)$size == 0L) {
  stop("The NLCD ImageServer returned an empty raster.")
}
message("Downloaded raw raster: ", nlcd_raw_path)

# --- 6.7 Clip precisely to North Carolina ---

nlcd_raw <- terra::rast(nlcd_raw_path)
nc_vect  <- terra::vect(nc_boundary)

if (!terra::same.crs(nlcd_raw, nc_vect)) {
  nc_vect <- terra::project(nc_vect, terra::crs(nlcd_raw))
}

nc_nlcd_path <- file.path(
  nlcd_dir,
  sprintf("annual_nlcd_fractional_impervious_%d_NC.tif", nlcd_year)
)

terra::crop(nlcd_raw, nc_vect) |>
  terra::mask(nc_vect) |>
  terra::writeRaster(nc_nlcd_path, overwrite = TRUE,
                     gdal = c("COMPRESS=LZW", "TILED=YES"))

message("Saved clipped NLCD raster: ", nc_nlcd_path)

# --- 6.8 Summary and inventory ---

final_nlcd <- terra::rast(nc_nlcd_path)
nlcd_stats <- terra::global(final_nlcd,
                            fun = c("min", "max", "mean"),
                            na.rm = TRUE)
print(final_nlcd)
print(nlcd_stats)

write_csv(
  tibble(
    product      = "Annual NLCD Fractional Impervious Surface",
    year         = nlcd_year,
    source       = nlcd_service_url,
    output_file  = nc_nlcd_path,
    raster_crs   = terra::crs(final_nlcd),
    resolution_x = terra::res(final_nlcd)[1],
    resolution_y = terra::res(final_nlcd)[2],
    min_value    = nlcd_stats$min,
    max_value    = nlcd_stats$max,
    mean_value   = nlcd_stats$mean
  ),
  file.path(nlcd_dir, "annual_nlcd_fractional_impervious_summary.csv")
)

write_csv(
  tibble(
    dataset          = "Annual NLCD fractional imperviousness",
    year             = nlcd_year,
    source           = nlcd_service_url,
    output_directory = nlcd_dir,
    output_file      = nc_nlcd_path,
    raster_cells     = terra::ncell(final_nlcd)
  ),
  file.path(results_dir, "nlcd_download_inventory.csv")
)

cat("\nNLCD download complete.\nFinal raster: ", nc_nlcd_path, "\n")

# ============================================================
# 7. USGS 3DEP Elevation Data
# ============================================================

# --- 7.1 Define study area ---

# FIX: The original script re-read nc_boundary from disk and re-transformed
# it (st_transform(5070)), even though nc_boundary is already in memory and
# already in EPSG:5070.
# FIX: mountain_counties was defined but never applied; removed.
study_area <- nc_boundary   # already EPSG:5070, already in memory

# --- 7.2 Download DEM ---

message("Downloading 3DEP elevation data (z = 10, ~30 m)...")

# elevatr::get_elev_raster() returns a {raster} RasterLayer;
# convert immediately to a terra SpatRaster.
dem_raw <- elevatr::get_elev_raster(
  locations = study_area,
  z         = 10L,
  clip      = "locations",
  src       = "aws"
) |> terra::rast()

# --- 7.3 Reproject boundary to raster CRS, crop, mask, then reproject ---

dem_nc <- terra::vect(study_area) |>
  terra::project(terra::crs(dem_raw)) |>
  (\(v) terra::crop(dem_raw, v) |> terra::mask(v))() |>
  terra::project("EPSG:32119", method = "bilinear")

dem_path <- file.path(dem_dir, "3dep_dem_north_carolina_epsg32119.tif")

terra::writeRaster(dem_nc, dem_path, overwrite = TRUE,
                   gdal = c("COMPRESS=LZW", "TILED=YES"))

# --- 7.4 Derive terrain features ---

message("Deriving terrain features...")

# FIX: terra::terrain() accepts a vector of variable names and returns a
# named multi-layer SpatRaster in one call — three separate calls removed.
# Note: 'unit' applies to slope and aspect only; it is silently ignored
# for roughness, which is dimensionless (elevation range within neighborhood).
terrain_rasters <- terra::terrain(
  dem_nc,
  v         = c("slope", "aspect", "roughness"),
  unit      = "degrees",
  neighbors = 8L
)

terrain_paths <- c(
  slope     = file.path(dem_dir, "slope_degrees_epsg32119.tif"),
  aspect    = file.path(dem_dir, "aspect_degrees_epsg32119.tif"),
  roughness = file.path(dem_dir, "roughness_epsg32119.tif")
)

# FIX: vectorized over named layers; replaces three separate writeRaster calls
walk2(
  names(terrain_paths),
  terrain_paths,
  \(nm, path) terra::writeRaster(
    terrain_rasters[[nm]], path,
    overwrite = TRUE,
    gdal      = c("COMPRESS=LZW", "TILED=YES")
  )
)

# --- 7.5 Raster summary ---

# FIX: map_chr / map_dbl replace manually repeated terra::crs/res calls
raster_list <- c(
  list(dem_nc),
  lapply(names(terrain_rasters), \(n) terrain_rasters[[n]])
)

dem_summary <- tibble(
  dataset      = c("3DEP DEM", "Slope", "Aspect", "Roughness"),
  file         = c(dem_path, unname(terrain_paths)),
  crs          = map_chr(raster_list, terra::crs),
  resolution_x = map_dbl(raster_list, \(r) terra::res(r)[1]),
  resolution_y = map_dbl(raster_list, \(r) terra::res(r)[2])
)

write_csv(dem_summary, file.path(dem_dir, "3dep_terrain_summary.csv"))

cat("\n3DEP processing complete.\nDEM saved to: ", dem_path, "\n")
