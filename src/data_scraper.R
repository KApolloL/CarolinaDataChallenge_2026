# ============================================================
# Download NCDOT Structures, USDA SSURGO, and NLCD Imperviousness
# for North Carolina
# ============================================================

# Install once if needed:
#
# install.packages(c(
#   "sf",
#   "tidyverse",
#   "httr2",
#   "soilDB",
#   "janitor",
#   "terra",
#   "tigris",
#   "sbtools"
# ))


# ============================================================
# 1. Load packages
# ============================================================

suppressPackageStartupMessages({
  library(sf)
  library(tidyverse)
  library(httr2)
  library(soilDB)
  library(janitor)
  library(terra)
  library(tigris)
  library(sbtools)
})


# ============================================================
# 2. Configure project directories
# ============================================================

project_dir <- "/Users/kentalee/Documents/KALProjects/UNCProjects/CarolinaDataChallenge_2026"

dirs <- list(
  data = file.path(
    project_dir,
    "data"
  ),
  
  results = file.path(
    project_dir,
    "outs"
  ),
  
  ncdot = file.path(
    project_dir,
    "data",
    "ncdot"
  ),
  
  usda = file.path(
    project_dir,
    "data",
    "usda_soils"
  ),
  
  nlcd = file.path(
    project_dir,
    "data",
    "nlcd_fractional_impervious"
  )
)

invisible(
  lapply(
    dirs,
    dir.create,
    recursive = TRUE,
    showWarnings = FALSE
  )
)

data_dir <- dirs$data
results_dir <- dirs$results
ncdot_dir <- dirs$ncdot
usda_dir <- dirs$usda
nlcd_dir <- dirs$nlcd


# ============================================================
# 3. Helper functions
# ============================================================

# Null-coalescing operator
`%||%` <- function(x, y) {
  if (is.null(x)) {
    y
  } else {
    x
  }
}


# Return the first nonmissing value
first_nonmissing <- function(
    x,
    default = NA
) {
  valid_values <- x[
    !is.na(x) &
      !(is.character(x) & trimws(x) == "")
  ]
  
  if (length(valid_values) == 0) {
    return(default)
  }
  
  valid_values[[1]]
}


# ============================================================
# 4. Download NCDOT structures and culverts
# ============================================================

ncdot_service_url <- paste0(
  "https://gis11.services.ncdot.gov/",
  "arcgis/rest/services/NCDOT_Structures/MapServer"
)


# ------------------------------------------------------------
# 4.1 Retrieve NCDOT layer metadata
# ------------------------------------------------------------

message("Retrieving NCDOT layer metadata...")

ncdot_service_metadata <- request(
  ncdot_service_url
) %>%
  req_url_query(
    f = "json"
  ) %>%
  req_retry(
    max_tries = 3
  ) %>%
  req_perform() %>%
  resp_body_json(
    simplifyVector = TRUE
  )

ncdot_layers <- as_tibble(
  ncdot_service_metadata$layers
) %>%
  select(
    id,
    name,
    type
  )

print(ncdot_layers)


# ------------------------------------------------------------
# 4.2 Function to download ArcGIS REST layers
# ------------------------------------------------------------

download_arcgis_layer <- function(
    service_url,
    layer_id,
    output_name,
    output_directory,
    page_size = 2000L,
    output_crs = 4326
) {
  layer_url <- paste0(
    service_url,
    "/",
    layer_id,
    "/query"
  )
  
  all_pages <- list()
  offset <- 0L
  page_number <- 1L
  
  repeat {
    message(
      "Downloading NCDOT layer ",
      layer_id,
      ", page ",
      page_number,
      ", offset ",
      offset,
      "..."
    )
    
    temporary_geojson <- tempfile(
      fileext = ".geojson"
    )
    
    page_response <- request(
      layer_url
    ) %>%
      req_url_query(
        where = "1=1",
        outFields = "*",
        returnGeometry = "true",
        outSR = output_crs,
        f = "geojson",
        resultOffset = offset,
        resultRecordCount = page_size
      ) %>%
      req_retry(
        max_tries = 3
      ) %>%
      req_perform()
    
    writeBin(
      resp_body_raw(page_response),
      temporary_geojson
    )
    
    page_data <- tryCatch(
      {
        st_read(
          temporary_geojson,
          quiet = TRUE
        )
      },
      error = function(e) {
        unlink(temporary_geojson)
        
        stop(
          "Could not read GeoJSON for NCDOT layer ",
          layer_id,
          ": ",
          e$message
        )
      }
    )
    
    unlink(temporary_geojson)
    
    if (nrow(page_data) == 0) {
      break
    }
    
    all_pages[[length(all_pages) + 1]] <- page_data
    
    message(
      "  Retrieved ",
      nrow(page_data),
      " records"
    )
    
    if (nrow(page_data) < page_size) {
      break
    }
    
    offset <- offset + nrow(page_data)
    page_number <- page_number + 1L
  }
  
  if (length(all_pages) == 0) {
    warning(
      "No records were returned for NCDOT layer ",
      layer_id
    )
    
    return(NULL)
  }
  
  layer_data <- do.call(
    rbind,
    all_pages
  )
  
  layer_data <- st_transform(
    layer_data,
    crs = output_crs
  )
  
  output_path <- file.path(
    output_directory,
    paste0(
      output_name,
      ".gpkg"
    )
  )
  
  st_write(
    layer_data,
    output_path,
    layer = output_name,
    delete_dsn = TRUE,
    quiet = TRUE
  )
  
  message(
    "Saved ",
    nrow(layer_data),
    " records to:\n",
    output_path
  )
  
  invisible(layer_data)
}


# ------------------------------------------------------------
# 4.3 Download NCDOT structure layers
# ------------------------------------------------------------

# Layer 0 = structures
ncdot_structures <- download_arcgis_layer(
  service_url = ncdot_service_url,
  layer_id = 0L,
  output_name = "ncdot_structures_nc",
  output_directory = ncdot_dir,
  page_size = 2000L,
  output_crs = 4326
)

# Layer 2 = culverts
ncdot_culverts <- download_arcgis_layer(
  service_url = ncdot_service_url,
  layer_id = 2L,
  output_name = "ncdot_culverts_nc",
  output_directory = ncdot_dir,
  page_size = 2000L,
  output_crs = 4326
)


# ============================================================
# 5. Query USDA SSURGO data
# ============================================================

# Soil Data Access may limit very large queries. If either query
# fails, divide the query by individual NC soil survey areasymbols.


# ------------------------------------------------------------
# 5.1 General USDA query function
# ------------------------------------------------------------

run_ssurgo_query <- function(
    sql,
    query_name,
    output_directory,
    output_basename
) {
  message(
    "Querying USDA SSURGO ",
    query_name,
    "..."
  )
  
  result <- tryCatch(
    {
      SDA_query(
        sql
      ) %>%
        as_tibble() %>%
        clean_names()
    },
    error = function(e) {
      stop(
        "SSURGO ",
        query_name,
        " query failed: ",
        e$message
      )
    }
  )
  
  csv_path <- file.path(
    output_directory,
    paste0(
      output_basename,
      ".csv"
    )
  )
  
  rds_path <- file.path(
    output_directory,
    paste0(
      output_basename,
      ".rds"
    )
  )
  
  write_csv(
    result,
    csv_path
  )
  
  saveRDS(
    result,
    rds_path
  )
  
  message(
    "Saved ",
    nrow(result),
    " rows to:\n",
    csv_path
  )
  
  result
}


# ------------------------------------------------------------
# 5.2 SSURGO component query
# ------------------------------------------------------------

soil_component_sql <- "
SELECT
    legend.areasymbol,
    legend.areaname,
    mapunit.mukey,
    mapunit.musym,
    mapunit.muname,
    component.cokey,
    component.compname,
    component.comppct_r,
    component.hydgrp,
    component.drainagecl
FROM legend
INNER JOIN mapunit
    ON mapunit.lkey = legend.lkey
INNER JOIN component
    ON component.mukey = mapunit.mukey
WHERE legend.areasymbol LIKE 'NC%'
"

soil_components_nc <- run_ssurgo_query(
  sql = soil_component_sql,
  query_name = "component",
  output_directory = usda_dir,
  output_basename = "nc_ssurgo_components"
)


# ------------------------------------------------------------
# 5.3 SSURGO horizon query
# ------------------------------------------------------------

soil_horizon_sql <- "
SELECT
    legend.areasymbol,
    legend.areaname,
    mapunit.mukey,
    mapunit.musym,
    mapunit.muname,
    component.cokey,
    component.compname,
    component.comppct_r,
    chorizon.chkey,
    chorizon.hzdept_r,
    chorizon.hzdepb_r,
    chorizon.ksat_r,
    chorizon.awc_r
FROM legend
INNER JOIN mapunit
    ON mapunit.lkey = legend.lkey
INNER JOIN component
    ON component.mukey = mapunit.mukey
INNER JOIN chorizon
    ON chorizon.cokey = component.cokey
WHERE legend.areasymbol LIKE 'NC%'
"

soil_horizons_nc <- run_ssurgo_query(
  sql = soil_horizon_sql,
  query_name = "horizon",
  output_directory = usda_dir,
  output_basename = "nc_ssurgo_horizons"
)


# ------------------------------------------------------------
# 5.4 Dominant soil component by map unit
# ------------------------------------------------------------

dominant_soils_nc <- soil_components_nc %>%
  mutate(
    comppct_r = suppressWarnings(
      as.numeric(comppct_r)
    )
  ) %>%
  group_by(
    mukey
  ) %>%
  slice_max(
    order_by = comppct_r,
    n = 1,
    with_ties = FALSE
  ) %>%
  ungroup()

write_csv(
  dominant_soils_nc,
  file.path(
    usda_dir,
    "nc_ssurgo_dominant_components.csv"
  )
)


# ============================================================
# 6. Download Annual NLCD Fractional Impervious Surface
# ============================================================

# ScienceBase item for Annual NLCD Collection 1.2 Fractional
# Impervious Surface.
sciencebase_item_id <- "697b907eb66b0197c3043c9f"

# Use a pre-event year when building historical model features.
nlcd_year <- 2023


# ------------------------------------------------------------
# 6.1 Download North Carolina boundary
# ------------------------------------------------------------

message(
  "Downloading North Carolina boundary..."
)

nc_boundary <- tigris::states(
  year = 2023,
  cb = TRUE,
  class = "sf"
) %>%
  filter(
    STUSPS == "NC"
  ) %>%
  st_transform(
    5070
  )

nc_boundary_path <- file.path(
  nlcd_dir,
  "north_carolina_boundary.gpkg"
)

st_write(
  nc_boundary,
  nc_boundary_path,
  delete_dsn = TRUE,
  quiet = TRUE
)


# ============================================================
# 6.2 Download Annual NLCD Fractional Imperviousness
#     Directly from the official ArcGIS ImageServer
# ============================================================

# Annual NLCD Fractional Impervious Surface ImageServer
nlcd_service_url <- paste0(
  "https://di-nlcd.img.arcgis.com/",
  "arcgis/rest/services/",
  "USA_NLCD_Annual_LandCover_Fractional_Impervious_Surface/",
  "ImageServer"
)

# Use a pre-event or analysis year.
nlcd_year <- 2023

# The service reports spatial reference 0 in its metadata.
# Annual NLCD products use an Albers equal-area projection.
# Explicitly use NAD83 / Conus Albers.
service_epsg <- 5070
service_crs <- "EPSG:5070"


# ------------------------------------------------------------
# 6.3 Retrieve ImageServer metadata
# ------------------------------------------------------------

message(
  "Retrieving Annual NLCD ImageServer metadata..."
)

nlcd_service_metadata <- request(
  nlcd_service_url
) %>%
  req_url_query(
    f = "json"
  ) %>%
  req_retry(
    max_tries = 3L,
    backoff = ~ 2^.x
  ) %>%
  req_perform() %>%
  resp_body_json(
    simplifyVector = FALSE
  )

write_json(
  nlcd_service_metadata,
  file.path(
    nlcd_dir,
    "annual_nlcd_image_server_metadata.json"
  ),
  pretty = TRUE,
  auto_unbox = TRUE
)

message(
  "Using explicit CRS: ",
  service_crs
)


# ------------------------------------------------------------
# 6.4 Prepare North Carolina boundary
# ------------------------------------------------------------

# nc_boundary was created earlier in Section 6.1.
# Reproject it explicitly to EPSG:5070.

nc_boundary_5070 <- nc_boundary %>%
  st_transform(
    crs = service_epsg
  )

nc_bbox <- st_bbox(
  nc_boundary_5070
)

bbox_string <- paste(
  unname(nc_bbox["xmin"]),
  unname(nc_bbox["ymin"]),
  unname(nc_bbox["xmax"]),
  unname(nc_bbox["ymax"]),
  sep = ","
)

message(
  "North Carolina bounding box:\n",
  bbox_string
)


# ------------------------------------------------------------
# 6.5 Calculate request dimensions
# ------------------------------------------------------------

# Annual NLCD Fractional Imperviousness is a 30-meter product.
# The MRLC product represents the percentage of a 30-meter pixel
# covered by impervious or constructed surfaces. 
pixel_size_m <- 30

nc_width <- ceiling(
  (nc_bbox["xmax"] - nc_bbox["xmin"]) /
    pixel_size_m
)

nc_height <- ceiling(
  (nc_bbox["ymax"] - nc_bbox["ymin"]) /
    pixel_size_m
)

# ArcGIS ImageServer export requests have maximum dimensions.
# Reduce dimensions only if necessary.
max_dimension <- 20000

if (
  nc_width > max_dimension ||
  nc_height > max_dimension
) {
  scale_factor <- max(
    nc_width / max_dimension,
    nc_height / max_dimension
  )
  
  nc_width <- ceiling(
    nc_width / scale_factor
  )
  
  nc_height <- ceiling(
    nc_height / scale_factor
  )
}

image_size <- paste(
  nc_width,
  nc_height,
  sep = ","
)

message(
  "Requested image size: ",
  image_size
)


# ------------------------------------------------------------
# 6.6 Determine whether the service supports time filtering
# ------------------------------------------------------------

time_query <- NULL

if (
  !is.null(nlcd_service_metadata$timeInfo)
) {
  start_date <- as.POSIXct(
    paste0(
      nlcd_year,
      "-01-01 00:00:00"
    ),
    tz = "UTC"
  )
  
  end_date <- as.POSIXct(
    paste0(
      nlcd_year,
      "-12-31 23:59:59"
    ),
    tz = "UTC"
  )
  
  time_query <- paste(
    as.numeric(start_date) * 1000,
    as.numeric(end_date) * 1000,
    sep = ","
  )
  
  message(
    "Time filtering enabled for ",
    nlcd_year
  )
} else {
  message(
    "The service did not expose timeInfo."
  )
}


# ------------------------------------------------------------
# 6.7 Request the North Carolina NLCD raster
# ------------------------------------------------------------

nlcd_export_url <- paste0(
  nlcd_service_url,
  "/exportImage"
)

nlcd_raw_path <- file.path(
  nlcd_dir,
  paste0(
    "annual_nlcd_fractional_impervious_",
    nlcd_year,
    "_NC_raw.tif"
  )
)

message(
  "Requesting NLCD raster..."
)

nlcd_request <- request(
  nlcd_export_url
) %>%
  req_url_query(
    bbox = bbox_string,
    bboxSR = service_epsg,
    imageSR = service_epsg,
    size = image_size,
    format = "tiff",
    pixelType = "U8",
    interpolation = "Nearest",
    compression = "LZW",
    noData = 255,
    noDataInterpretation = "esriNoDataMatch",
    f = "image"
  )

if (
  !is.null(time_query)
) {
  nlcd_request <- nlcd_request %>%
    req_url_query(
      time = time_query
    )
}

nlcd_response <- nlcd_request %>%
  req_retry(
    max_tries = 3L,
    backoff = ~ 2^.x
  ) %>%
  req_perform()

writeBin(
  resp_body_raw(nlcd_response),
  nlcd_raw_path
)

if (
  !file.exists(nlcd_raw_path) ||
  file.info(nlcd_raw_path)$size == 0
) {
  stop(
    "The NLCD ImageServer returned an empty raster."
  )
}

message(
  "Downloaded raw raster:\n",
  nlcd_raw_path
)


# ------------------------------------------------------------
# 6.8 Clip the raster precisely to North Carolina
# ------------------------------------------------------------

nlcd_raw_raster <- terra::rast(
  nlcd_raw_path
)

nc_boundary_vect <- terra::vect(
  nc_boundary_5070
)

# Make sure the boundary and raster use the same CRS.
if (
  !terra::same.crs(
    nlcd_raw_raster,
    nc_boundary_vect
  )
) {
  nc_boundary_vect <- terra::project(
    nc_boundary_vect,
    terra::crs(nlcd_raw_raster)
  )
}

nlcd_cropped <- terra::crop(
  nlcd_raw_raster,
  nc_boundary_vect
)

nlcd_nc <- terra::mask(
  nlcd_cropped,
  nc_boundary_vect
)

nc_nlcd_path <- file.path(
  nlcd_dir,
  paste0(
    "annual_nlcd_fractional_impervious_",
    nlcd_year,
    "_NC.tif"
  )
)

terra::writeRaster(
  nlcd_nc,
  nc_nlcd_path,
  overwrite = TRUE,
  gdal = c(
    "COMPRESS=LZW",
    "TILED=YES"
  )
)

message(
  "Saved clipped raster:\n",
  nc_nlcd_path
)


# ============================================================
# 7. Quality checks
# ============================================================

final_nlcd <- terra::rast(
  nc_nlcd_path
)

print(
  final_nlcd
)

nlcd_stats <- terra::global(
  final_nlcd,
  fun = c(
    "min",
    "max",
    "mean"
  ),
  na.rm = TRUE
)

print(
  nlcd_stats
)


# ============================================================
# 8. Save summary and inventory
# ============================================================

nlcd_summary <- tibble(
  product = "Annual NLCD Fractional Impervious Surface",
  year = nlcd_year,
  source = nlcd_service_url,
  output_file = nc_nlcd_path,
  raster_crs = terra::crs(final_nlcd),
  resolution_x = terra::res(final_nlcd)[1],
  resolution_y = terra::res(final_nlcd)[2],
  min_value = nlcd_stats$min,
  max_value = nlcd_stats$max,
  mean_value = nlcd_stats$mean
)

write_csv(
  nlcd_summary,
  file.path(
    nlcd_dir,
    "annual_nlcd_fractional_impervious_summary.csv"
  )
)

nlcd_inventory <- tibble(
  dataset = "Annual NLCD fractional imperviousness",
  year = nlcd_year,
  source = nlcd_service_url,
  output_directory = nlcd_dir,
  output_file = nc_nlcd_path,
  raster_cells = terra::ncell(final_nlcd)
)

write_csv(
  nlcd_inventory,
  file.path(
    results_dir,
    "nlcd_download_inventory.csv"
  )
)

cat(
  "\nNLCD download complete.\n",
  "Final raster:\n",
  nc_nlcd_path,
  "\n"
)