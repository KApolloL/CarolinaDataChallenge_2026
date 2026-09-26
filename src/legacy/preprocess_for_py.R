# ============================================================
# Blue Ridge FloodWatch
# Python/Reticulate Machine Learning Handoff
# ============================================================

# This script creates one row per NOAA EVENT_ID and exports:
#
# 1. A clean machine-learning feature table
# 2. A feature dictionary
# 3. A train/test split recommendation
# 4. A spatial event layer
#
# All distance and area calculations use EPSG:32119.
# The original NOAA event coordinates are retained in longitude/latitude.


# ============================================================
# 1. Load packages
# ============================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(sf)
  library(terra)
  library(arrow)
  library(janitor)
  library(lubridate)
})


# ============================================================
# 2. Configure directories
# ============================================================

project_dir <- "/Users/kentalee/Documents/KALProjects/UNCProjects/CarolinaDataChallenge_2026"

data_dir <- file.path(
  project_dir,
  "data"
)

results_dir <- file.path(
  project_dir,
  "outs"
)

ml_dir <- file.path(
  data_dir,
  "ml_ready"
)

ncdot_dir <- file.path(
  data_dir,
  "ncdot"
)

nlcd_dir <- file.path(
  data_dir,
  "nlcd_fractional_impervious"
)

dem_dir <- file.path(
  data_dir,
  "dem_3dep"
)

nhd_dir <- file.path(
  data_dir,
  "nhd_nc"
)

dir.create(
  ml_dir,
  recursive = TRUE,
  showWarnings = FALSE
)

dir.create(
  results_dir,
  recursive = TRUE,
  showWarnings = FALSE
)


# ============================================================
# 3. Helper functions
# ============================================================

parse_noaa_damage <- function(x) {
  x <- toupper(trimws(as.character(x)))
  
  result <- case_when(
    is.na(x) | x %in% c("", "NA", "NULL") ~ 0,
    str_detect(x, "B$") ~ parse_number(x) * 1e9,
    str_detect(x, "M$") ~ parse_number(x) * 1e6,
    str_detect(x, "K$") ~ parse_number(x) * 1e3,
    TRUE ~ parse_number(x)
  )
  
  replace_na(result, 0)
}


first_nonmissing <- function(x, default = NA) {
  valid_values <- x[
    !is.na(x) &
      !(is.character(x) & trimws(x) == "")
  ]
  
  if (length(valid_values) == 0) {
    return(default)
  }
  
  valid_values[[1]]
}


max_or_zero <- function(x) {
  x <- suppressWarnings(as.numeric(x))
  x <- replace_na(x, 0)
  
  if (length(x) == 0) {
    return(0)
  }
  
  max(x, na.rm = TRUE)
}


count_nearby_features <- function(
    points,
    features,
    radius_m = 1000
) {
  if (nrow(features) == 0) {
    return(rep(0L, nrow(points)))
  }
  
  nearby <- st_is_within_distance(
    points,
    features,
    dist = radius_m
  )
  
  lengths(nearby)
}


safe_raster_extract <- function(
    raster,
    points,
    output_name
) {
  values <- terra::extract(
    raster,
    terra::vect(points)
  )
  
  if (ncol(values) < 2) {
    points[[output_name]] <- NA_real_
  } else {
    points[[output_name]] <- as.numeric(values[[2]])
  }
  
  points
}


# ============================================================
# 4. Load or create the NOAA event table
# ============================================================

# This assumes nc_storm_combined has already been created in your
# earlier NOAA processing code.

if (!exists("nc_storm_combined")) {
  stop(
    "nc_storm_combined does not exist. Run the NOAA loading and ",
    "region-assignment code before running this script."
  )
}


# ============================================================
# 5. Create one row per EVENT_ID
# ============================================================

storm_event_level <- nc_storm_combined %>%
  mutate(
    EVENT_TYPE = str_squish(as.character(EVENT_TYPE)),
    EVENT_TYPE = replace_na(EVENT_TYPE, "Unknown"),
    
    CZ_NAME = str_squish(as.character(CZ_NAME)),
    REGION = str_to_lower(str_squish(as.character(REGION))),
    
    BEGIN_LAT = suppressWarnings(as.numeric(BEGIN_LAT)),
    BEGIN_LON = suppressWarnings(as.numeric(BEGIN_LON)),
    
    INJURIES_DIRECT = replace_na(
      suppressWarnings(as.numeric(INJURIES_DIRECT)),
      0
    ),
    
    INJURIES_INDIRECT = replace_na(
      suppressWarnings(as.numeric(INJURIES_INDIRECT)),
      0
    ),
    
    DEATHS_DIRECT = replace_na(
      suppressWarnings(as.numeric(DEATHS_DIRECT)),
      0
    ),
    
    DEATHS_INDIRECT = replace_na(
      suppressWarnings(as.numeric(DEATHS_INDIRECT)),
      0
    ),
    
    PROPERTY_DAMAGE_DOLLARS = parse_noaa_damage(
      DAMAGE_PROPERTY
    ),
    
    CROP_DAMAGE_DOLLARS = parse_noaa_damage(
      DAMAGE_CROPS
    ),
    
    EVENT_DATE = suppressWarnings(
      parse_date_time(
        BEGIN_DATE_TIME,
        orders = c(
          "d-b-y H:M:S",
          "d-b-Y H:M:S",
          "Y-m-d H:M:S",
          "m/d/Y H:M:S"
        ),
        quiet = TRUE
      )
    )
  ) %>%
  group_by(EVENT_ID) %>%
  summarise(
    EVENT_TYPE = first_nonmissing(EVENT_TYPE),
    YEAR = first_nonmissing(YEAR),
    MONTH_NAME = first_nonmissing(MONTH_NAME),
    EVENT_DATE = first_nonmissing(EVENT_DATE),
    
    CZ_NAME = first_nonmissing(CZ_NAME),
    REGION = first_nonmissing(REGION),
    
    BEGIN_LAT = first_nonmissing(BEGIN_LAT),
    BEGIN_LON = first_nonmissing(BEGIN_LON),
    
    INJURIES_DIRECT = max_or_zero(
      INJURIES_DIRECT
    ),
    
    INJURIES_INDIRECT = max_or_zero(
      INJURIES_INDIRECT
    ),
    
    DEATHS_DIRECT = max_or_zero(
      DEATHS_DIRECT
    ),
    
    DEATHS_INDIRECT = max_or_zero(
      DEATHS_INDIRECT
    ),
    
    PROPERTY_DAMAGE_DOLLARS = max_or_zero(
      PROPERTY_DAMAGE_DOLLARS
    ),
    
    CROP_DAMAGE_DOLLARS = max_or_zero(
      CROP_DAMAGE_DOLLARS
    ),
    
    .groups = "drop"
  ) %>%
  mutate(
    TOTAL_INJURIES =
      INJURIES_DIRECT +
      INJURIES_INDIRECT,
    
    TOTAL_DEATHS =
      DEATHS_DIRECT +
      DEATHS_INDIRECT,
    
    TOTAL_DAMAGE =
      PROPERTY_DAMAGE_DOLLARS +
      CROP_DAMAGE_DOLLARS,
    
    # Keep raw outcome fields.
    # Do not use these as predictors when modeling high_consequence.
    ANY_DEATH = as.integer(TOTAL_DEATHS > 0),
    ANY_INJURY = as.integer(TOTAL_INJURIES > 0),
    ANY_DAMAGE = as.integer(TOTAL_DAMAGE > 0)
  ) %>%
  filter(
    !is.na(EVENT_ID),
    !is.na(BEGIN_LAT),
    !is.na(BEGIN_LON)
  )


# ============================================================
# 6. Create the event point layer
# ============================================================

storm_points <- st_as_sf(
  storm_event_level,
  coords = c(
    "BEGIN_LON",
    "BEGIN_LAT"
  ),
  crs = 4326,
  remove = FALSE
) %>%
  st_transform(32119)

# Remove invalid points
storm_points <- storm_points[
  !st_is_empty(storm_points),
]


# ============================================================
# 7. Load spatial datasets
# ============================================================

# Remove Z, M, XYZ, or XYM geometry dimensions before using
# GEOS operations such as st_transform(), st_distance(), and
# st_nearest_feature().

clean_spatial_layer <- function(
    x,
    target_crs = 32119
) {
  x %>%
    st_zm(
      drop = TRUE,
      what = "ZM"
    ) %>%
    st_make_valid() %>%
    st_transform(
      target_crs
    )
}


# ------------------------------------------------------------
# 7.1 Load NCDOT structures
# ------------------------------------------------------------

structures_path <- file.path(
  ncdot_dir,
  "ncdot_structures_nc.gpkg"
)

ncdot_structures <- st_read(
  structures_path,
  quiet = TRUE
) %>%
  clean_spatial_layer(
    target_crs = 32119
  )


# ------------------------------------------------------------
# 7.2 Load NCDOT culverts
# ------------------------------------------------------------

culverts_path <- file.path(
  ncdot_dir,
  "ncdot_culverts_nc.gpkg"
)

ncdot_culverts <- st_read(
  culverts_path,
  quiet = TRUE
) %>%
  clean_spatial_layer(
    target_crs = 32119
  )


# ------------------------------------------------------------
# 7.3 Extract and load NHD flowlines
# ------------------------------------------------------------

nhd_zip <- file.path(
  data_dir,
  "NHD_H_North_Carolina_State_Shape.zip"
)

if (!file.exists(nhd_zip)) {
  stop(
    "NHD ZIP file not found at: ",
    nhd_zip
  )
}

dir.create(
  nhd_dir,
  recursive = TRUE,
  showWarnings = FALSE
)

existing_nhd_files <- list.files(
  nhd_dir,
  full.names = TRUE,
  recursive = TRUE
)

if (length(existing_nhd_files) == 0) {
  unzip(
    nhd_zip,
    exdir = nhd_dir
  )
}

nhd_shapefiles <- list.files(
  nhd_dir,
  pattern = "\\.shp$",
  full.names = TRUE,
  recursive = TRUE,
  ignore.case = TRUE
)

print(nhd_shapefiles)

flowline_candidates <- nhd_shapefiles[
  str_detect(
    str_to_lower(
      basename(nhd_shapefiles)
    ),
    "flowline|nhdflowline"
  )
]

if (length(flowline_candidates) == 0) {
  stop(
    "Could not identify an NHD flowline shapefile. ",
    "Inspect nhd_shapefiles."
  )
}

nhd_flowlines <- st_read(
  flowline_candidates[[1]],
  quiet = TRUE
) %>%
  clean_spatial_layer(
    target_crs = 32119
  )


# ------------------------------------------------------------
# 7.4 Create and clean storm event points
# ------------------------------------------------------------

storm_points <- st_as_sf(
  storm_event_level,
  coords = c(
    "BEGIN_LON",
    "BEGIN_LAT"
  ),
  crs = 4326,
  remove = FALSE
) %>%
  clean_spatial_layer(
    target_crs = 32119
  )

# ============================================================
# 8. Add stream and infrastructure features
#    Optimized using spatial indexing and local cropping
# ============================================================

# ------------------------------------------------------------
# 8.1 Restrict to relevant events
# ------------------------------------------------------------

# For Blue Ridge FloodWatch, use flood-related events.
# This is much faster and more appropriate than processing every
# NOAA storm event in North Carolina.

storm_points <- storm_points %>%
  mutate(
    IS_FLOOD_EVENT = as.integer(
      str_detect(
        str_to_lower(EVENT_TYPE),
        "flood|heavy rain|debris flow|landslide"
      )
    )
  )

analysis_points <- storm_points %>%
  filter(
    IS_FLOOD_EVENT == 1
  )

if (nrow(analysis_points) == 0) {
  stop(
    "No flood-related event points were found. ",
    "Check EVENT_TYPE values."
  )
}

message(
  "Analyzing ",
  nrow(analysis_points),
  " flood-related event points."
)

analysis_points <- storm_points %>%
  filter(
    IS_FLOOD_EVENT == 1
  )

if (nrow(analysis_points) == 0) {
  stop(
    "No flood-related event points were found. ",
    "Check the IS_FLOOD_EVENT definition."
  )
}

message(
  "Analyzing ",
  nrow(analysis_points),
  " flood-related event points."
)


# ------------------------------------------------------------
# 8.2 Crop spatial layers around the event points
# ------------------------------------------------------------

# The largest feature radius used below is 1 kilometer.
# Add a small margin around that radius.

analysis_extent <- st_bbox(
  st_buffer(
    analysis_points,
    dist = 1100
  )
)

nhd_flowlines_local <- st_crop(
  nhd_flowlines,
  analysis_extent
)

ncdot_culverts_local <- st_crop(
  ncdot_culverts,
  analysis_extent
)

ncdot_structures_local <- st_crop(
  ncdot_structures,
  analysis_extent
)

message(
  "NHD flowlines retained: ",
  nrow(nhd_flowlines_local)
)

message(
  "NCDOT culverts retained: ",
  nrow(ncdot_culverts_local)
)

message(
  "NCDOT structures retained: ",
  nrow(ncdot_structures_local)
)


# ------------------------------------------------------------
# 8.3 Distance to the nearest stream
# ------------------------------------------------------------

message(
  "Calculating distance to nearest stream..."
)

nearest_stream_index <- st_nearest_feature(
  analysis_points,
  nhd_flowlines_local
)

nearest_streams <- nhd_flowlines_local[
  nearest_stream_index,
  ,
  drop = FALSE
]

analysis_points$distance_to_stream_m <- as.numeric(
  st_distance(
    analysis_points,
    nearest_streams,
    by_element = TRUE
  )
)


# ------------------------------------------------------------
# 8.4 Count streams using spatially indexed intersections
# ------------------------------------------------------------

message(
  "Counting nearby streams..."
)

stream_buffers_250m <- st_buffer(
  analysis_points,
  dist = 250
)

stream_buffers_1km <- st_buffer(
  analysis_points,
  dist = 1000
)

streams_within_250m <- st_intersects(
  stream_buffers_250m,
  nhd_flowlines_local
)

streams_within_1km <- st_intersects(
  stream_buffers_1km,
  nhd_flowlines_local
)

analysis_points$streams_within_250m <- lengths(
  streams_within_250m
)

analysis_points$streams_within_1km <- lengths(
  streams_within_1km
)


# ------------------------------------------------------------
# 8.5 Count nearby NCDOT culverts
# ------------------------------------------------------------

message(
  "Counting nearby culverts..."
)

culverts_within_250m <- st_intersects(
  stream_buffers_250m,
  ncdot_culverts_local
)

culverts_within_1km <- st_intersects(
  stream_buffers_1km,
  ncdot_culverts_local
)

analysis_points$culverts_within_250m <- lengths(
  culverts_within_250m
)

analysis_points$culverts_within_1km <- lengths(
  culverts_within_1km
)


# ------------------------------------------------------------
# 8.6 Count nearby NCDOT structures
# ------------------------------------------------------------

message(
  "Counting nearby structures..."
)

structures_within_250m <- st_intersects(
  stream_buffers_250m,
  ncdot_structures_local
)

structures_within_1km <- st_intersects(
  stream_buffers_1km,
  ncdot_structures_local
)

analysis_points$structures_within_250m <- lengths(
  structures_within_250m
)

analysis_points$structures_within_1km <- lengths(
  structures_within_1km
)


# ------------------------------------------------------------
# 8.7 Remove temporary geometry columns
# ------------------------------------------------------------

analysis_points <- analysis_points %>%
  select(
    -any_of(
      c(
        "geometry"
      )
    )
  )


# ============================================================
# 9. Extract DEM and terrain features
# ============================================================

dem_path <- file.path(
  dem_dir,
  "3dep_dem_north_carolina_epsg32119.tif"
)

slope_path <- file.path(
  dem_dir,
  "slope_degrees_epsg32119.tif"
)

roughness_path <- file.path(
  dem_dir,
  "roughness_epsg32119.tif"
)

dem_raster <- terra::rast(
  dem_path
)

slope_raster <- terra::rast(
  slope_path
)

roughness_raster <- terra::rast(
  roughness_path
)

storm_points <- safe_raster_extract(
  dem_raster,
  storm_points,
  "elevation_m"
)

storm_points <- safe_raster_extract(
  slope_raster,
  storm_points,
  "slope_degrees"
)

storm_points <- safe_raster_extract(
  roughness_raster,
  storm_points,
  "terrain_roughness"
)


# ------------------------------------------------------------
# Add local raster summaries within buffers
# ------------------------------------------------------------

extract_buffer_mean <- function(
    raster,
    points,
    radius_m,
    output_name
) {
  buffers <- st_buffer(
    points,
    dist = radius_m
  )
  
  extracted <- terra::extract(
    raster,
    terra::vect(buffers),
    fun = mean,
    na.rm = TRUE
  )
  
  points[[output_name]] <- as.numeric(
    extracted[[2]]
  )
  
  points
}

storm_points <- extract_buffer_mean(
  dem_raster,
  storm_points,
  radius_m = 250,
  output_name = "elevation_mean_250m"
)

storm_points <- extract_buffer_mean(
  slope_raster,
  storm_points,
  radius_m = 250,
  output_name = "slope_mean_250m"
)

storm_points <- extract_buffer_mean(
  roughness_raster,
  storm_points,
  radius_m = 250,
  output_name = "roughness_mean_250m"
)


# ============================================================
# 10. Extract NLCD imperviousness features
# ============================================================

impervious_path <- file.path(
  nlcd_dir,
  "annual_nlcd_fractional_impervious_2023_NC.tif"
)

if (!file.exists(impervious_path)) {
  stop(
    "NLCD raster not found at: ",
    impervious_path
  )
}

impervious_raster <- terra::rast(
  impervious_path
)

# Match the raster CRS to the event points if necessary
storm_points_raster_crs <- st_transform(
  storm_points,
  terra::crs(impervious_raster)
)

storm_points <- safe_raster_extract(
  impervious_raster,
  storm_points_raster_crs,
  "impervious_mean_event"
) %>%
  st_transform(32119)

storm_points <- extract_buffer_mean(
  impervious_raster,
  st_transform(storm_points, terra::crs(impervious_raster)),
  radius_m = 250,
  output_name = "impervious_mean_250m"
) %>%
  st_transform(32119)

storm_points <- extract_buffer_mean(
  impervious_raster,
  st_transform(storm_points, terra::crs(impervious_raster)),
  radius_m = 1000,
  output_name = "impervious_mean_1km"
) %>%
  st_transform(32119)


# ============================================================
# 11. Add analysis labels
# ============================================================

# Important:
# The damage threshold below is descriptive and uses the full dataset.
# For a leakage-safe model, your Python teammate should recalculate
# the threshold using training data only.

positive_damage <- storm_points$TOTAL_DAMAGE[
  storm_points$TOTAL_DAMAGE > 0
]

damage_threshold_90 <- quantile(
  positive_damage,
  probs = 0.90,
  na.rm = TRUE,
  names = FALSE
)

storm_points <- storm_points %>%
  mutate(
    high_consequence = as.integer(
      TOTAL_DEATHS >= 1 |
        TOTAL_DAMAGE > damage_threshold_90
    ),
    
    high_human_impact = as.integer(
      TOTAL_DEATHS >= 1 |
        TOTAL_INJURIES >= 1
    ),
    
    damage_threshold_90 = damage_threshold_90,
    
    # Useful modeling time fields
    EVENT_YEAR = year(EVENT_DATE),
    EVENT_MONTH = month(EVENT_DATE),
    EVENT_DAY_OF_YEAR = yday(EVENT_DATE),
    
    # Broad event classes
    IS_FLOOD_EVENT = as.integer(
      str_detect(
        str_to_lower(EVENT_TYPE),
        "flood|heavy rain|debris flow|landslide"
      )
    ),
    
    IS_TROPICAL_EVENT = as.integer(
      str_detect(
        str_to_lower(EVENT_TYPE),
        "hurricane|tropical storm|tropical depression"
      )
    )
  )


# ============================================================
# 12. Restrict to flood-related events
# ============================================================

flood_feature_table <- storm_points %>%
  filter(
    IS_FLOOD_EVENT == 1
  )


# ============================================================
# 13. Prepare and export Python-ready ML tables
# ============================================================

# This section:
# - Converts the spatial event layer to a regular data frame
# - Removes duplicate column names correctly
# - Separates identifiers, predictors, outcomes, and targets
# - Creates all-event and flood-only modeling tables
# - Exports CSV, Parquet, GeoPackage, and documentation files


# ------------------------------------------------------------
# 13.1 Create flood-event indicator if needed
# ------------------------------------------------------------

if (!"IS_FLOOD_EVENT" %in% names(storm_points)) {
  storm_points <- storm_points %>%
    mutate(
      IS_FLOOD_EVENT = as.integer(
        str_detect(
          str_to_lower(as.character(EVENT_TYPE)),
          "flood|heavy rain|debris flow|landslide"
        )
      )
    )
}

if (!"IS_TROPICAL_EVENT" %in% names(storm_points)) {
  storm_points <- storm_points %>%
    mutate(
      IS_TROPICAL_EVENT = as.integer(
        str_detect(
          str_to_lower(as.character(EVENT_TYPE)),
          "hurricane|tropical storm|tropical depression"
        )
      )
    )
}


# ------------------------------------------------------------
# 13.2 Add target variables if needed
# ------------------------------------------------------------

# Ensure outcome columns exist
storm_points <- storm_points %>%
  mutate(
    TOTAL_INJURIES = replace_na(
      suppressWarnings(as.numeric(TOTAL_INJURIES)),
      0
    ),
    
    TOTAL_DEATHS = replace_na(
      suppressWarnings(as.numeric(TOTAL_DEATHS)),
      0
    ),
    
    PROPERTY_DAMAGE_DOLLARS = replace_na(
      suppressWarnings(as.numeric(PROPERTY_DAMAGE_DOLLARS)),
      0
    ),
    
    CROP_DAMAGE_DOLLARS = replace_na(
      suppressWarnings(as.numeric(CROP_DAMAGE_DOLLARS)),
      0
    )
  )

if (!"TOTAL_DAMAGE" %in% names(storm_points)) {
  storm_points <- storm_points %>%
    mutate(
      TOTAL_DAMAGE =
        PROPERTY_DAMAGE_DOLLARS +
        CROP_DAMAGE_DOLLARS
    )
}

if (!"ANY_DEATH" %in% names(storm_points)) {
  storm_points <- storm_points %>%
    mutate(
      ANY_DEATH = as.integer(TOTAL_DEATHS > 0)
    )
}

if (!"ANY_INJURY" %in% names(storm_points)) {
  storm_points <- storm_points %>%
    mutate(
      ANY_INJURY = as.integer(TOTAL_INJURIES > 0)
    )
}

if (!"ANY_DAMAGE" %in% names(storm_points)) {
  storm_points <- storm_points %>%
    mutate(
      ANY_DAMAGE = as.integer(TOTAL_DAMAGE > 0)
    )
}


# ------------------------------------------------------------
# 13.3 Calculate high-consequence target
# ------------------------------------------------------------

positive_damage <- storm_points$TOTAL_DAMAGE[
  !is.na(storm_points$TOTAL_DAMAGE) &
    storm_points$TOTAL_DAMAGE > 0
]

if (length(positive_damage) == 0) {
  damage_threshold_90 <- NA_real_
} else {
  damage_threshold_90 <- quantile(
    positive_damage,
    probs = 0.90,
    na.rm = TRUE,
    names = FALSE
  )
}

storm_points <- storm_points %>%
  mutate(
    HIGH_CONSEQUENCE = as.integer(
      TOTAL_DEATHS >= 1 |
        (
          !is.na(damage_threshold_90) &
            TOTAL_DAMAGE > damage_threshold_90
        )
    ),
    
    HIGH_HUMAN_IMPACT = as.integer(
      TOTAL_DEATHS >= 1 |
        TOTAL_INJURIES >= 1
    ),
    
    DAMAGE_THRESHOLD_90 = damage_threshold_90
  )


# ------------------------------------------------------------
# 13.4 Convert spatial event data to a regular data frame
# ------------------------------------------------------------

ml_feature_table <- storm_points %>%
  mutate(
    longitude = as.numeric(BEGIN_LON),
    latitude = as.numeric(BEGIN_LAT)
  ) %>%
  st_drop_geometry() %>%
  janitor::clean_names()


# ------------------------------------------------------------
# 13.5 Remove duplicate columns correctly
# ------------------------------------------------------------

# Do not use:
# select(!duplicated(names(.)))
#
# dplyr::select() does not accept a logical vector in this form.
# Use base R instead.

ml_feature_table <- ml_feature_table[
  ,
  !duplicated(names(ml_feature_table)),
  drop = FALSE
]

if (anyDuplicated(names(ml_feature_table)) > 0) {
  stop(
    "Duplicate column names remain in ml_feature_table."
  )
}


# ------------------------------------------------------------
# 13.6 Keep one row per EVENT_ID
# ------------------------------------------------------------

if (!"event_id" %in% names(ml_feature_table)) {
  stop(
    "The column EVENT_ID was not found after cleaning names."
  )
}

ml_feature_table <- ml_feature_table %>%
  distinct(
    event_id,
    .keep_all = TRUE
  )


# ============================================================
# 14. Define identifiers, predictors, and outcomes
# ============================================================

id_columns <- c(
  "event_id",
  "episode_id",
  "event_date",
  "year",
  "event_year",
  "event_month",
  "event_day_of_year",
  "event_type",
  "cz_name",
  "cz_type",
  "cz_fips",
  "region",
  "region_assignment_method",
  "longitude",
  "latitude"
)

outcome_columns <- c(
  "total_injuries",
  "total_deaths",
  "property_damage_dollars",
  "crop_damage_dollars",
  "total_damage",
  "any_death",
  "any_injury",
  "any_damage",
  "high_consequence",
  "high_human_impact"
)

candidate_feature_columns <- c(
  # Time/context features
  "event_year",
  "event_month",
  "event_day_of_year",
  
  # Geographic features
  "longitude",
  "latitude",
  "region",
  
  # Hydrography features
  "distance_to_stream_m",
  "streams_within_250m",
  "streams_within_1km",
  
  # NCDOT infrastructure features
  "distance_to_nearest_culvert_m",
  "distance_to_nearest_structure_m",
  "culverts_within_250m",
  "culverts_within_1km",
  "structures_within_250m",
  "structures_within_1km",
  
  # Terrain features
  "elevation_m",
  "elevation_mean_250m",
  "slope_degrees",
  "slope_mean_250m",
  "terrain_roughness",
  "roughness_mean_250m",
  
  # NLCD features
  "impervious_mean_event",
  "impervious_mean_250m",
  "impervious_mean_1km",
  
  # Event-type indicators
  "is_flood_event",
  "is_tropical_event"
)

id_columns <- intersect(
  id_columns,
  names(ml_feature_table)
)

outcome_columns <- intersect(
  outcome_columns,
  names(ml_feature_table)
)

feature_columns <- intersect(
  candidate_feature_columns,
  names(ml_feature_table)
)


# ============================================================
# 15. Create model, predictor, and target tables
# ============================================================

# ------------------------------------------------------------
# 15.1 Complete modeling table
# ------------------------------------------------------------

model_table <- ml_feature_table %>%
  select(
    any_of(
      c(
        id_columns,
        feature_columns,
        outcome_columns
      )
    )
  )

model_table <- model_table[
  ,
  !duplicated(names(model_table)),
  drop = FALSE
]


# ------------------------------------------------------------
# 15.2 Predictor-only table
# ------------------------------------------------------------

predictor_table <- ml_feature_table %>%
  select(
    any_of(
      c(
        id_columns,
        feature_columns
      )
    )
  )

predictor_table <- predictor_table[
  ,
  !duplicated(names(predictor_table)),
  drop = FALSE
]


# ------------------------------------------------------------
# 15.3 Target-only table
# ------------------------------------------------------------

target_table <- ml_feature_table %>%
  select(
    any_of(
      c(
        "event_id",
        "episode_id",
        "event_date",
        "event_year",
        "event_type",
        "region",
        outcome_columns
      )
    )
  )

target_table <- target_table[
  ,
  !duplicated(names(target_table)),
  drop = FALSE
]


# ============================================================
# 16. Create flood-only modeling table
# ============================================================

if ("is_flood_event" %in% names(model_table)) {
  flood_model_table <- model_table %>%
    filter(
      is_flood_event == 1
    )
} else if ("event_type" %in% names(model_table)) {
  flood_model_table <- model_table %>%
    filter(
      str_detect(
        str_to_lower(as.character(event_type)),
        "flood|heavy rain|debris flow|landslide"
      )
    )
} else {
  warning(
    "Neither is_flood_event nor event_type is available. ",
    "Flood-only table will be empty."
  )
  
  flood_model_table <- model_table[0, ]
}

flood_model_table <- flood_model_table[
  ,
  !duplicated(names(flood_model_table)),
  drop = FALSE
]


# ============================================================
# 17. Add chronological split recommendations
# ============================================================

# 2016–2021: training
# 2022–2023: validation
# 2024–2026: test
#
# 2026 should be treated as a partial year if applicable.

model_table <- model_table %>%
  mutate(
    is_partial_year = event_year %in% params$partial_years,
    
    split = case_when(
      event_year <= 2021 ~ "train",
      event_year %in% c(2022, 2023) ~ "validation",
      event_year >= 2024 ~ "test",
      TRUE ~ "unknown"
    )
  )

flood_model_table <- flood_model_table %>%
  mutate(
    is_partial_year = event_year %in% params$partial_years,
    
    split = case_when(
      event_year <= 2021 ~ "train",
      event_year %in% c(2022, 2023) ~ "validation",
      event_year >= 2024 ~ "test",
      TRUE ~ "unknown"
    )
  )

split_recommendation <- model_table %>%
  count(
    split,
    event_year,
    is_partial_year,
    name = "events"
  ) %>%
  arrange(
    event_year
  )


# ============================================================
# 18. Create feature dictionary
# ============================================================

feature_dictionary <- tibble(
  column_name = names(model_table),
  role = case_when(
    column_name %in% outcome_columns ~ "outcome",
    column_name %in% c(
      "high_consequence",
      "high_human_impact"
    ) ~ "target",
    column_name %in% id_columns ~ "identifier",
    column_name %in% feature_columns ~ "predictor",
    TRUE ~ "context"
  ),
  data_type = map_chr(
    model_table,
    ~ class(.x)[1]
  ),
  units = case_when(
    str_detect(
      column_name,
      "distance|elevation"
    ) ~ "meters",
    
    str_detect(
      column_name,
      "slope"
    ) ~ "degrees",
    
    str_detect(
      column_name,
      "damage"
    ) ~ "US dollars",
    
    str_detect(
      column_name,
      "injur|death|events|structures|culverts|streams"
    ) ~ "count",
    
    str_detect(
      column_name,
      "longitude|latitude"
    ) ~ "decimal degrees",
    
    TRUE ~ NA_character_
  ),
  description = case_when(
    column_name == "event_id" ~
      "Unique NOAA event identifier",
    
    column_name == "event_type" ~
      "NOAA storm event type",
    
    column_name == "region" ~
      "Assigned North Carolina geographic region",
    
    column_name == "distance_to_stream_m" ~
      "Distance from event point to nearest NHD flowline",
    
    column_name == "streams_within_250m" ~
      "Number of NHD flowlines within 250 meters",
    
    column_name == "streams_within_1km" ~
      "Number of NHD flowlines within 1 kilometer",
    
    column_name == "culverts_within_250m" ~
      "Number of NCDOT culverts within 250 meters",
    
    column_name == "culverts_within_1km" ~
      "Number of NCDOT culverts within 1 kilometer",
    
    column_name == "structures_within_250m" ~
      "Number of NCDOT structures within 250 meters",
    
    column_name == "structures_within_1km" ~
      "Number of NCDOT structures within 1 kilometer",
    
    column_name == "elevation_m" ~
      "3DEP elevation at the event location",
    
    column_name == "slope_degrees" ~
      "3DEP slope at the event location",
    
    column_name == "terrain_roughness" ~
      "Terrain roughness at the event location",
    
    column_name == "impervious_mean_event" ~
      "NLCD imperviousness at the event location",
    
    column_name == "impervious_mean_250m" ~
      "Mean NLCD imperviousness within 250 meters",
    
    column_name == "impervious_mean_1km" ~
      "Mean NLCD imperviousness within 1 kilometer",
    
    column_name == "high_consequence" ~
      "Death or damage above the configured damage threshold",
    
    column_name == "high_human_impact" ~
      "At least one reported death or injury",
    
    TRUE ~
      paste(
        "Prepared ML field:",
        column_name
      )
  ),
  source_dataset = case_when(
    str_detect(
      column_name,
      "stream"
    ) ~ "NHD",
    
    str_detect(
      column_name,
      "culvert|structure"
    ) ~ "NCDOT",
    
    str_detect(
      column_name,
      "elevation|slope|roughness"
    ) ~ "USGS 3DEP",
    
    str_detect(
      column_name,
      "impervious"
    ) ~ "Annual NLCD",
    
    str_detect(
      column_name,
      "damage|injur|death|event"
    ) ~ "NOAA Storm Events",
    
    TRUE ~ "Derived"
  ),
  source_vintage = case_when(
    str_detect(
      column_name,
      "impervious"
    ) ~ "2023",
    
    str_detect(
      column_name,
      "event|damage|injur|death"
    ) ~ "2016–2026",
    
    TRUE ~ NA_character_
  ),
  aggregation_method = case_when(
    str_detect(
      column_name,
      "within"
    ) ~ "Count within configured buffer",
    
    str_detect(
      column_name,
      "mean"
    ) ~ "Mean within configured buffer",
    
    column_name == "distance_to_stream_m" ~
      "Nearest-feature distance",
    
    TRUE ~ "Event-level or derived"
  ),
  missing_value_policy = case_when(
    str_detect(
      column_name,
      "stream|culvert|structure"
    ) ~
      "Retain NA if source coverage is unavailable; do not interpret as zero",
    
    TRUE ~
      "Retain NA or document imputation in Python"
  ),
  leakage_warning = case_when(
    column_name %in% outcome_columns ~
      "Do not use as predictor",
    
    column_name == "high_consequence" ~
      "Target only; recalculate damage threshold using training data",
    
    str_detect(
      column_name,
      "impervious"
    ) ~
      "2023 static layer; may create temporal leakage for earlier events",
    
    TRUE ~
      "Review before modeling"
  )
)


# ============================================================
# 19. Create target definitions
# ============================================================

target_definitions <- tibble(
  target_name = c(
    "high_consequence",
    "high_human_impact"
  ),
  
  definition = c(
    paste0(
      "1 if total deaths >= 1 or total damage exceeds the ",
      "90th percentile of positive damage values; 0 otherwise."
    ),
    
    "1 if total deaths >= 1 or total injuries >= 1; 0 otherwise."
  ),
  
  damage_threshold = c(
    as.character(damage_threshold_90),
    NA_character_
  ),
  
  leakage_warning = c(
    "Recalculate the damage threshold using training data only.",
    "This is an outcome label and must not be used as a predictor."
  )
)


# ============================================================
# 20. Write validation summaries
# ============================================================

model_table_summary <- tibble(
  table_name = c(
    "all_events",
    "flood_events",
    "predictor_table",
    "target_table"
  ),
  
  rows = c(
    nrow(model_table),
    nrow(flood_model_table),
    nrow(predictor_table),
    nrow(target_table)
  ),
  
  columns = c(
    ncol(model_table),
    ncol(flood_model_table),
    ncol(predictor_table),
    ncol(target_table)
  )
)

class_balance <- model_table %>%
  summarise(
    total_events = n(),
    high_consequence_events = sum(
      high_consequence,
      na.rm = TRUE
    ),
    high_consequence_rate = mean(
      high_consequence,
      na.rm = TRUE
    ),
    high_human_impact_events = sum(
      high_human_impact,
      na.rm = TRUE
    ),
    high_human_impact_rate = mean(
      high_human_impact,
      na.rm = TRUE
    ),
    years_present = n_distinct(
      event_year,
      na.rm = TRUE
    )
  )

missing_predictors <- model_table %>%
  summarise(
    across(
      any_of(feature_columns),
      ~ sum(is.na(.x))
    )
  ) %>%
  pivot_longer(
    cols = everything(),
    names_to = "feature",
    values_to = "missing_count"
  ) %>%
  mutate(
    missing_fraction = missing_count / nrow(model_table)
  ) %>%
  arrange(
    desc(missing_fraction)
  )

missing_targets <- model_table %>%
  summarise(
    across(
      any_of(
        c(
          "high_consequence",
          "high_human_impact"
        )
      ),
      ~ sum(is.na(.x))
    )
  )


# ============================================================
# 21. Validate the exported data
# ============================================================

# Check that EVENT_ID is unique.
duplicate_event_ids <- model_table %>%
  count(event_id) %>%
  filter(n > 1)

if (
  nrow(duplicate_event_ids) > 0
) {
  warning(
    "Duplicate event_id values remain in the model table."
  )
} else {
  message(
    "Validation passed: one row per event_id."
  )
}


# Check whether target columns contain missing values.
missing_targets <- model_table %>%
  summarise(
    across(
      any_of(
        c(
          "high_consequence",
          "high_human_impact"
        )
      ),
      ~ sum(is.na(.x))
    )
  )

write_csv(
  missing_targets,
  file.path(
    ml_dir,
    "missing_target_counts.csv"
  )
)


# Check missingness in predictor columns.
missing_predictors <- model_table %>%
  summarise(
    across(
      any_of(feature_columns),
      ~ sum(is.na(.x))
    )
  ) %>%
  pivot_longer(
    cols = everything(),
    names_to = "feature",
    values_to = "missing_count"
  ) %>%
  mutate(
    missing_fraction = missing_count / nrow(model_table)
  ) %>%
  arrange(
    desc(missing_fraction)
  )

write_csv(
  missing_predictors,
  file.path(
    ml_dir,
    "predictor_missingness.csv"
  )
)


# ============================================================
# 22. Final handoff message
# ============================================================

cat(
  "\n============================================================\n"
)

cat(
  "Python machine-learning handoff complete\n"
)

cat(
  "============================================================\n\n"
)

cat(
  "Main modeling table:\n",
  file.path(
    ml_dir,
    "nc_storm_event_model_table.parquet"
  ),
  "\n\n",
  sep = ""
)

cat(
  "Flood-only modeling table:\n",
  file.path(
    ml_dir,
    "nc_flood_event_model_table.parquet"
  ),
  "\n\n",
  sep = ""
)

cat(
  "Predictor-only table:\n",
  file.path(
    ml_dir,
    "nc_storm_predictors_only.parquet"
  ),
  "\n\n",
  sep = ""
)

cat(
  "Target table:\n",
  file.path(
    ml_dir,
    "nc_storm_targets.parquet"
  ),
  "\n\n",
  sep = ""
)

cat(
  "Feature dictionary:\n",
  file.path(
    ml_dir,
    "feature_dictionary.csv"
  ),
  "\n\n",
  sep = ""
)

cat(
  "Spatial event layer:\n",
  file.path(
    ml_dir,
    "nc_storm_event_features.gpkg"
  ),
  "\n",
  sep = ""
)