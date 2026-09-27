# ============================================================
# Carolina HighGround — targets and Python ML handoff
# ============================================================
#
# Adds documented outcome labels, assigns a chronological split,
# classifies every column by role, writes a feature dictionary,
# and exports CSV / Parquet / GeoPackage files for the Python
# modeling workflow.
#
# Leakage rules applied here:
#   - Outcome columns (injuries, deaths, damage, any_*, fatality
#     record counts, damage-reported flags) are never predictors.
#   - NOAA narratives describe outcomes and are not exported.
#   - The damage threshold is saved with the data. For final model
#     evaluation it must be recomputed on training rows only
#     (or rendered with target_threshold_basis: "train_split").
#
# Requires: scripts/utils.R, dplyr, arrow, sf, jsonlite.

# ------------------------------------------------------------
# Split and targets
# ------------------------------------------------------------

assign_split <- function(event_year, train_end_year, validation_end_year) {
  dplyr::case_when(
    is.na(event_year)                   ~ "unknown",
    event_year <= train_end_year        ~ "train",
    event_year <= validation_end_year   ~ "validation",
    TRUE                                ~ "test"
  )
}

add_targets <- function(events,
                        damage_quantile,
                        positive_damage_only,
                        death_target_value,
                        threshold_basis = c("all_events", "train_split")) {
  threshold_basis <- match.arg(threshold_basis)
  basis <- threshold_basis

  basis_rows <- if (threshold_basis == "train_split") events$split == "train" else rep(TRUE, nrow(events))
  damage_pool <- events$total_damage[basis_rows & !is.na(events$total_damage)]
  if (positive_damage_only) {
    damage_pool <- damage_pool[damage_pool > 0]
  }

  threshold <- if (length(damage_pool) == 0) {
    fw_log("warning", input = "high_consequence target",
           message = "No damage values available to compute the damage threshold; the damage arm of the target is disabled.",
           affects = "high_consequence")
    NA_real_
  } else {
    stats::quantile(damage_pool, probs = damage_quantile, names = FALSE, type = 7)
  }

  events <- events |>
    dplyr::mutate(
      high_consequence = as.integer(
        total_deaths >= death_target_value |
          (!is.na(threshold) & total_damage > threshold)
      ),
      high_human_impact = as.integer(total_deaths >= 1 | total_injuries >= 1)
    )

  definitions <- tibble::tibble(
    target_name = c("high_consequence", "high_human_impact"),
    definition = c(
      sprintf(
        "1 if total_deaths >= %s OR total_damage > the %s quantile of %sdamage values (basis: %s); 0 otherwise.",
        death_target_value, damage_quantile,
        if (positive_damage_only) "positive " else "", basis
      ),
      "1 if total_deaths >= 1 OR total_injuries >= 1; 0 otherwise."
    ),
    damage_threshold_dollars = c(threshold, NA_real_),
    damage_quantile          = c(damage_quantile, NA_real_),
    positive_damage_only     = c(positive_damage_only, NA),
    death_target_value       = c(death_target_value, 1),
    threshold_basis          = c(basis, NA_character_),
    threshold_pool_n         = c(length(damage_pool), NA_integer_),
    positives                = c(sum(events$high_consequence), sum(events$high_human_impact)),
    prevalence               = c(mean(events$high_consequence), mean(events$high_human_impact)),
    leakage_warning = c(
      if (basis == "all_events") {
        "Threshold computed on all events (descriptive). Recompute on training rows only before final model evaluation."
      } else {
        "Threshold computed on training rows only."
      },
      "Outcome label; never use injuries or deaths as predictors."
    )
  )

  list(events = events, threshold = threshold, definitions = definitions)
}

# ------------------------------------------------------------
# Column roles
# ------------------------------------------------------------

column_roles <- function(feature_cols, optional_feature_cols = character()) {
  list(
    identifier = c("event_id", "episode_id"),
    context = c(
      "event_date", "year", "event_year", "split", "is_partial_year",
      "cz_name", "cz_type", "cz_fips", "wfo", "matched_county", "matched_county_fips",
      "region_assignment_method", "in_study_area", "flood_cause",
      "event_coordinate_quality", "spatial_feature_method", "source_vintage",
      "data_coverage_warning", "huc12", "huc12_name"
    ),
    predictor = c(
      "event_type", "region", "event_month", "event_day_of_year",
      "longitude", "latitude", "is_flood_event", "is_tropical_event",
      setdiff(feature_cols, c("huc12", "huc12_name")),
      optional_feature_cols
    ),
    outcome = c(
      "injuries_direct", "injuries_indirect", "total_injuries",
      "deaths_direct", "deaths_indirect", "total_deaths",
      "property_damage_dollars", "crop_damage_dollars", "total_damage",
      "property_damage_reported", "crop_damage_reported",
      "any_death", "any_injury", "any_damage",
      "fatality_records", "fatality_records_direct", "fatality_records_indirect"
    ),
    target = c("high_consequence", "high_human_impact")
  )
}

role_of <- function(column, roles) {
  for (role in names(roles)) {
    if (column %in% roles[[role]]) return(role)
  }
  "context"
}

# ------------------------------------------------------------
# Feature dictionary
# ------------------------------------------------------------

describe_column <- function(col, settings) {
  eb <- buffer_label(settings$event_buffer_m)
  sb <- buffer_label(settings$stream_buffer_m)
  ib <- buffer_label(settings$infrastructure_buffer_m)
  fixed <- c(
    event_id = "NOAA EVENT_ID (unique row key)",
    episode_id = "NOAA EPISODE_ID; several events can share an episode (use for grouped CV)",
    event_date = "Event begin date (NOAA BEGIN_DATE_TIME, local standard time of the CZ)",
    year = "NOAA YEAR field",
    event_year = "Calendar year of event begin date",
    event_month = "Month of event begin date",
    event_day_of_year = "Day of year of event begin date",
    event_type = "NOAA EVENT_TYPE",
    flood_cause = "NOAA FLOOD_CAUSE (flood events only)",
    cz_name = "NOAA county or forecast-zone name",
    cz_type = "C = county record, Z = forecast-zone record",
    cz_fips = "County FIPS (C) or NWS zone number (Z)",
    wfo = "NWS Weather Forecast Office",
    region = "NC region (mountains/central/coastal) from county or zone name",
    region_assignment_method = "exact_county_match / forecast_zone_county_match / special_coastal_zone / unmatched",
    matched_county = "County name(s) matched from the CZ record",
    matched_county_fips = "3-digit county FIPS of matched county(ies)",
    in_study_area = "Matched county is in the configured study_counties",
    longitude = "Event longitude (EPSG:4326) from NOAA BEGIN_LON or first locations-table point",
    latitude = "Event latitude (EPSG:4326) from NOAA BEGIN_LAT or first locations-table point",
    event_coordinate_quality = "Source of the event coordinate",
    is_flood_event = "EVENT_TYPE matches flood_event_pattern",
    is_tropical_event = "EVENT_TYPE matches tropical_event_pattern",
    is_partial_year = "Event year is listed in partial_years (incomplete NOAA year)",
    split = "Recommended chronological split",
    injuries_direct = "NOAA direct injuries", injuries_indirect = "NOAA indirect injuries",
    total_injuries = "Direct + indirect injuries",
    deaths_direct = "NOAA direct deaths", deaths_indirect = "NOAA indirect deaths",
    total_deaths = "Direct + indirect deaths",
    property_damage_dollars = "NOAA DAMAGE_PROPERTY in dollars (nominal, not inflation-adjusted)",
    crop_damage_dollars = "NOAA DAMAGE_CROPS in dollars (nominal)",
    total_damage = "Property + crop damage (nominal dollars)",
    property_damage_reported = "1 if NOAA DAMAGE_PROPERTY was non-blank",
    crop_damage_reported = "1 if NOAA DAMAGE_CROPS was non-blank",
    any_death = "total_deaths > 0", any_injury = "total_injuries > 0", any_damage = "total_damage > 0",
    fatality_records = "Rows in NOAA fatalities table for this event",
    fatality_records_direct = "Fatality records with FATALITY_TYPE = D",
    fatality_records_indirect = "Fatality records with FATALITY_TYPE = I",
    high_consequence = "Primary target (see target_definitions.csv)",
    high_human_impact = "Secondary target (see target_definitions.csv)",
    distance_to_stream_m = "Distance to nearest NHD HR flowline of the configured ftypes",
    distance_to_nearest_culvert_m = "Distance to nearest NCDOT culvert",
    distance_to_nearest_structure_m = "Distance to nearest NCDOT structure (bridge layer)",
    elevation_m = "DEM elevation at the event point",
    slope_degrees = "Slope at the event point",
    terrain_roughness = "Terrain roughness (elevation range in 3x3 window) at the event point",
    impervious_mean_event = "Annual NLCD fractional imperviousness (%) at the event point",
    huc12 = "WBD HUC12 containing the event point",
    huc12_name = "WBD HUC12 name",
    huc12_area_km2 = "Area of the containing HUC12 (not upstream contributing area)",
    spatial_feature_method = "Methods used to compute this row's spatial features",
    source_vintage = "Source dataset vintages for this row",
    data_coverage_warning = "Coverage caveats for this row"
  )
  if (col %in% names(fixed)) return(unname(fixed[[col]]))

  radius <- stringr::str_extract(col, "(\\d+m|\\d+km)$")
  dplyr::case_when(
    stringr::str_detect(col, "^streams_within_")    ~ paste("Count of NHD HR flowline segments within", radius),
    stringr::str_detect(col, "^stream_density")     ~ paste("Flowline length (km) per km^2 within", radius),
    stringr::str_detect(col, "^culverts_within_")   ~ paste("Count of NCDOT culverts within", radius),
    stringr::str_detect(col, "^structures_within_") ~ paste("Count of NCDOT structures within", radius),
    stringr::str_detect(col, "^elevation_mean_")    ~ paste("Mean DEM elevation within", radius),
    stringr::str_detect(col, "^slope_mean_")        ~ paste("Mean slope within", radius),
    stringr::str_detect(col, "^roughness_mean_")    ~ paste("Mean terrain roughness within", radius),
    stringr::str_detect(col, "^impervious_mean_")   ~ paste("Mean Annual NLCD imperviousness (%) within", radius),
    TRUE ~ NA_character_
  )
}

build_feature_dictionary <- function(model_table, roles, settings, vintages) {
  cols <- names(model_table)
  tibble::tibble(
    column_name = cols,
    role        = vapply(cols, role_of, character(1), roles = roles),
    data_type   = vapply(model_table, \(x) class(x)[1], character(1)),
    description = vapply(cols, describe_column, character(1), settings = settings),
    units = dplyr::case_when(
      stringr::str_detect(cols, "distance|elevation") ~ "meters",
      stringr::str_detect(cols, "slope")              ~ "degrees",
      stringr::str_detect(cols, "roughness")          ~ "meters (elevation range)",
      stringr::str_detect(cols, "impervious")         ~ "percent (0-100)",
      stringr::str_detect(cols, "stream_density")     ~ "km per km^2",
      stringr::str_detect(cols, "dollars|total_damage") ~ "US dollars (nominal)",
      stringr::str_detect(cols, "within_|injuries|deaths|records$") ~ "count",
      cols %in% c("longitude", "latitude")            ~ "decimal degrees (EPSG:4326)",
      cols == "huc12_area_km2"                        ~ "km^2",
      TRUE ~ NA_character_
    ),
    source_dataset = dplyr::case_when(
      stringr::str_detect(cols, "stream")                      ~ "USGS NHD High Resolution",
      stringr::str_detect(cols, "^huc12")                      ~ "USGS WBD",
      stringr::str_detect(cols, "culvert|structure")           ~ "NCDOT Structures service",
      stringr::str_detect(cols, "elevation|slope|roughness")   ~ "DEM (elevatr / AWS terrain tiles incl. USGS 3DEP)",
      stringr::str_detect(cols, "impervious")                  ~ "USGS Annual NLCD",
      cols %in% c("high_consequence", "high_human_impact", "split", "region",
                  "region_assignment_method", "matched_county", "matched_county_fips",
                  "in_study_area", "is_flood_event", "is_tropical_event", "is_partial_year") ~ "Derived from NOAA",
      TRUE ~ "NOAA Storm Events"
    ),
    source_vintage = dplyr::case_when(
      stringr::str_detect(cols, "stream")                    ~ vintages$nhd,
      stringr::str_detect(cols, "^huc12")                    ~ vintages$nhd,
      stringr::str_detect(cols, "culvert|structure")         ~ vintages$ncdot,
      stringr::str_detect(cols, "elevation|slope|roughness") ~ vintages$dem,
      stringr::str_detect(cols, "impervious")                ~ vintages$nlcd,
      TRUE                                                   ~ vintages$noaa
    ),
    aggregation_method = dplyr::case_when(
      stringr::str_detect(cols, "_within_")          ~ "Count within radius of event point",
      stringr::str_detect(cols, "_mean_\\d")         ~ "Mean of raster cells within radius (cells touched by buffer)",
      stringr::str_detect(cols, "^distance")         ~ "Nearest-feature distance from event point",
      cols %in% c("elevation_m", "slope_degrees", "terrain_roughness", "impervious_mean_event") ~ "Raster cell value at event point",
      stringr::str_detect(cols, "stream_density")    ~ "Clipped flowline length / buffer area",
      cols %in% roles$outcome                        ~ "max() across duplicate detail rows (never summed)",
      TRUE ~ "Event-level value"
    ),
    missing_value_policy = dplyr::case_when(
      cols %in% c(roles$predictor) & stringr::str_detect(cols, "stream|culvert|structure|huc12") ~
        "NA = no coordinates or layer unavailable; do not impute as zero",
      cols %in% roles$predictor & stringr::str_detect(cols, "elevation|slope|roughness|impervious") ~
        "NA = no coordinates or outside raster; impute inside the Python CV pipeline if needed",
      cols %in% c("longitude", "latitude") ~ "NA = NOAA record has no usable coordinates (mostly forecast-zone events)",
      TRUE ~ "Retain as-is"
    ),
    leakage_warning = dplyr::case_when(
      role == "outcome"  ~ "Outcome: never use as a predictor",
      role == "target"   ~ "Target: recompute damage threshold on training rows before final evaluation",
      stringr::str_detect(cols, "impervious") ~ "2023 static layer; post-dates most events (possible temporal leakage)",
      cols == "event_type" ~ "Known at report time; fine for post-event triage models, not for pre-event forecasting",
      cols == "flood_cause" ~ "Recorded after the event; excluded from predictors",
      TRUE ~ NA_character_
    )
  )
}

# ------------------------------------------------------------
# Writers
# ------------------------------------------------------------

write_outputs <- function(table, basename_no_ext, dir, csv, parquet) {
  written <- list()
  if (csv) {
    path <- file.path(dir, paste0(basename_no_ext, ".csv"))
    readr::write_csv(table, path, na = "")
    written[[length(written) + 1]] <- path
  }
  if (parquet) {
    path <- file.path(dir, paste0(basename_no_ext, ".parquet"))
    arrow::write_parquet(table, path)
    written[[length(written) + 1]] <- path
  }
  purrr::map(written, \(p) tibble::tibble(file = p, rows = nrow(table), columns = ncol(table))) |>
    dplyr::bind_rows()
}

# Writes all ML files and returns an inventory built from files that
# actually exist afterwards (no success is reported for a failed write).
export_ml_tables <- function(model_table,
                             roles,
                             dictionary,
                             target_definitions,
                             target_config,
                             split_summary,
                             ml_dir,
                             export_csv,
                             export_parquet,
                             export_spatial_layer,
                             export_feature_dictionary,
                             analysis_crs,
                             geographic_crs,
                             manifest) {
  dir.create(ml_dir, recursive = TRUE, showWarnings = FALSE)
  keep <- \(cols) intersect(cols, names(model_table))

  predictors_only <- model_table |>
    dplyr::select(dplyr::all_of(keep(c(roles$identifier, "split", "is_partial_year", "in_study_area", roles$predictor))))
  targets_only <- model_table |>
    dplyr::select(dplyr::all_of(keep(c(roles$identifier, "event_date", "event_year", "event_type", "region",
                                       "split", "is_partial_year", roles$outcome, roles$target))))
  flood_table <- dplyr::filter(model_table, is_flood_event == 1)

  inventory <- dplyr::bind_rows(
    write_outputs(model_table,     "nc_storm_event_model_table", ml_dir, export_csv, export_parquet),
    write_outputs(flood_table,     "nc_flood_event_model_table", ml_dir, export_csv, export_parquet),
    write_outputs(predictors_only, "nc_storm_predictors_only",   ml_dir, export_csv, export_parquet),
    write_outputs(targets_only,    "nc_storm_targets",           ml_dir, export_csv, export_parquet)
  )

  small <- list(
    target_definitions    = target_definitions,
    split_recommendation  = split_summary
  )
  if (export_feature_dictionary) {
    small$feature_dictionary <- dictionary
  }
  for (nm in names(small)) {
    path <- file.path(ml_dir, paste0(nm, ".csv"))
    readr::write_csv(small[[nm]], path, na = "")
    inventory <- dplyr::bind_rows(inventory, tibble::tibble(file = path, rows = nrow(small[[nm]]), columns = ncol(small[[nm]])))
  }

  json_path <- file.path(ml_dir, "target_config.json")
  jsonlite::write_json(target_config, json_path, auto_unbox = TRUE, pretty = TRUE, digits = NA)
  inventory <- dplyr::bind_rows(inventory, tibble::tibble(file = json_path, rows = NA_integer_, columns = NA_integer_))

  if (export_spatial_layer) {
    located <- dplyr::filter(model_table, !is.na(longitude), !is.na(latitude))
    gpkg_path <- file.path(ml_dir, "nc_storm_event_features.gpkg")
    sf::st_as_sf(located, coords = c("longitude", "latitude"), crs = geographic_crs, remove = FALSE) |>
      sf::st_transform(analysis_crs) |>
      dplyr::mutate(event_date = as.character(event_date)) |>
      sf::st_write(gpkg_path, layer = "storm_events", delete_dsn = TRUE, quiet = TRUE)
    inventory <- dplyr::bind_rows(inventory, tibble::tibble(file = gpkg_path, rows = nrow(located), columns = ncol(located)))
  }

  manifest_path <- file.path(ml_dir, "run_manifest.json")
  jsonlite::write_json(manifest, manifest_path, auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null")
  inventory <- dplyr::bind_rows(inventory, tibble::tibble(file = manifest_path, rows = NA_integer_, columns = NA_integer_))

  inventory |>
    dplyr::mutate(
      exists  = file.exists(file),
      size_mb = round(file.info(file)$size / 1024^2, 2)
    )
}
