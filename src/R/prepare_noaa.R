# ============================================================
# Blue Ridge FloodWatch — NOAA Storm Events preparation
# ============================================================
#
# Builds an event-level table with exactly one row per EVENT_ID.
#
#   details     -> one row per EVENT_ID (duplicates collapsed with
#                  first-nonmissing metadata and max() impacts)
#   fatalities  -> aggregated separately by EVENT_ID (record counts)
#   locations   -> aggregated separately by EVENT_ID (record count,
#                  first location point as a coordinate fallback)
#
# The three tables are never joined row-to-row, so fatality and
# location records cannot multiply event-level injuries, deaths,
# or damage.
#
# Requires: scripts/utils.R, tidyverse, lubridate.

# ------------------------------------------------------------
# North Carolina county lookup
# ------------------------------------------------------------
# All 100 NC counties with 3-digit county FIPS and the project's
# three-region scheme (carried over unchanged from the original
# cdc_2026.qmd: 24 mountain, 35 central, 41 coastal/coastal-plain
# counties). The county names are validated against NOAA county
# records at run time (see validate_county_lookup()).

nc_county_lookup <- function() {
  counties <- c(
    "ALAMANCE", "ALEXANDER", "ALLEGHANY", "ANSON", "ASHE", "AVERY",
    "BEAUFORT", "BERTIE", "BLADEN", "BRUNSWICK", "BUNCOMBE", "BURKE",
    "CABARRUS", "CALDWELL", "CAMDEN", "CARTERET", "CASWELL", "CATAWBA",
    "CHATHAM", "CHEROKEE", "CHOWAN", "CLAY", "CLEVELAND", "COLUMBUS",
    "CRAVEN", "CUMBERLAND", "CURRITUCK", "DARE", "DAVIDSON", "DAVIE",
    "DUPLIN", "DURHAM", "EDGECOMBE", "FORSYTH", "FRANKLIN", "GASTON",
    "GATES", "GRAHAM", "GRANVILLE", "GREENE", "GUILFORD", "HALIFAX",
    "HARNETT", "HAYWOOD", "HENDERSON", "HERTFORD", "HOKE", "HYDE",
    "IREDELL", "JACKSON", "JOHNSTON", "JONES", "LEE", "LENOIR",
    "LINCOLN", "MCDOWELL", "MACON", "MADISON", "MARTIN", "MECKLENBURG",
    "MITCHELL", "MONTGOMERY", "MOORE", "NASH", "NEW HANOVER", "NORTHAMPTON",
    "ONSLOW", "ORANGE", "PAMLICO", "PASQUOTANK", "PENDER", "PERQUIMANS",
    "PERSON", "PITT", "POLK", "RANDOLPH", "RICHMOND", "ROBESON",
    "ROCKINGHAM", "ROWAN", "RUTHERFORD", "SAMPSON", "SCOTLAND", "STANLY",
    "STOKES", "SURRY", "SWAIN", "TRANSYLVANIA", "TYRRELL", "UNION",
    "VANCE", "WAKE", "WARREN", "WASHINGTON", "WATAUGA", "WAYNE",
    "WILKES", "WILSON", "YADKIN", "YANCEY"
  )

  mountain_fips <- c(
    3, 5, 9, 11, 21, 23, 27, 39, 43, 75, 87, 89, 99,
    111, 113, 115, 121, 149, 161, 173, 175, 189, 193, 199
  )
  central_fips <- c(
    1, 7, 25, 33, 35, 37, 45, 57, 59, 63, 67, 69, 71, 77, 81,
    97, 105, 109, 119, 123, 125, 135, 145, 151, 153, 157, 159,
    167, 169, 171, 179, 181, 183, 185, 197
  )

  tibble::tibble(
    county_fips = seq(1L, 199L, by = 2L),   # NC county FIPS are odd, alphabetical
    county_name = counties
  ) |>
    dplyr::mutate(
      region = dplyr::case_when(
        county_fips %in% mountain_fips ~ "mountains",
        county_fips %in% central_fips  ~ "central",
        TRUE                           ~ "coastal"
      )
    )
}

# Compare lookup names to the names NOAA uses on county (CZ_TYPE = "C")
# records. Returns the mismatches (expected: none).
validate_county_lookup <- function(details, lookup = nc_county_lookup()) {
  details |>
    dplyr::filter(toupper(CZ_TYPE) == "C") |>
    dplyr::distinct(
      county_fips = suppressWarnings(as.integer(CZ_FIPS)) %% 1000L,
      noaa_name   = stringr::str_squish(toupper(CZ_NAME))
    ) |>
    dplyr::left_join(lookup, by = "county_fips") |>
    dplyr::filter(is.na(county_name) | noaa_name != county_name)
}

# ------------------------------------------------------------
# Region assignment
# ------------------------------------------------------------
#
# Order of attempts for each distinct (CZ_TYPE, CZ_FIPS, CZ_NAME):
#
#   1. exact_county_match
#        - county records (CZ_TYPE "C"): 3-digit county FIPS lookup
#        - zone records whose name is exactly a county name
#   2. forecast_zone_county_match
#        - remove directional/descriptive words (WESTERN, INLAND,
#          GREATER, MOUNTAINS, ...) and match the remaining county
#          name; multi-county zone names are accepted only when all
#          named counties fall in the same region
#   3. special_coastal_zone
#        - named barrier-island / Outer Banks zones that contain no
#          county name (NORTHERN OUTER BANKS, HATTERAS ISLAND, ...)
#   4. unmatched
#        - region left NA; never defaulted to any region
#
# Forecast-zone CZ_FIPS values are NWS zone numbers, not county FIPS,
# so they are never used for the county lookup.

assign_nc_region <- function(zones,
                             descriptor_words,
                             special_coastal_pattern,
                             lookup = nc_county_lookup()) {
  descriptor_regex <- paste0("\\b(", paste(toupper(descriptor_words), collapse = "|"), ")\\b")
  # Longest names first so "NEW HANOVER" wins over any shorter overlap.
  county_names <- lookup$county_name[order(-nchar(lookup$county_name))]
  county_regex <- paste0("\\b(", paste(county_names, collapse = "|"), ")\\b")

  keys <- zones |>
    dplyr::distinct(CZ_TYPE, CZ_FIPS, CZ_NAME)

  assign_one <- function(cz_type, cz_fips, cz_name) {
    type <- toupper(trimws(as.character(cz_type)))
    name <- stringr::str_squish(toupper(as.character(cz_name)))
    fips <- suppressWarnings(as.integer(cz_fips)) %% 1000L

    result <- function(method, matched) {
      hits <- lookup[match(matched, lookup$county_name), ]
      regions <- unique(hits$region)
      tibble::tibble(
        region                   = if (method == "special_coastal_zone") "coastal" else if (length(regions) == 1) regions else NA_character_,
        region_assignment_method = method,
        matched_county           = if (length(matched) == 0) NA_character_ else paste(matched, collapse = "; "),
        matched_county_fips      = if (nrow(hits) == 0) NA_character_ else paste(sprintf("%03d", hits$county_fips), collapse = "; ")
      )
    }

    if (is.na(name) || name == "") {
      return(result("unmatched", character()))
    }

    # 1. Exact county match
    if (type == "C" && !is.na(fips) && fips %in% lookup$county_fips) {
      return(result("exact_county_match", lookup$county_name[lookup$county_fips == fips]))
    }
    if (name %in% lookup$county_name) {
      return(result("exact_county_match", name))
    }

    # 2. Forecast-zone county match after removing descriptors
    stripped <- stringr::str_squish(stringr::str_remove_all(name, descriptor_regex))
    if (stripped %in% lookup$county_name) {
      return(result("forecast_zone_county_match", stripped))
    }
    named <- unique(stringr::str_extract_all(stripped, county_regex)[[1]])
    if (length(named) > 0) {
      named_regions <- unique(lookup$region[match(named, lookup$county_name)])
      if (length(named_regions) == 1) {
        return(result("forecast_zone_county_match", named))
      }
    }

    # 3. Special coastal zones
    if (stringr::str_detect(name, stringr::regex(special_coastal_pattern, ignore_case = TRUE))) {
      return(result("special_coastal_zone", character()))
    }

    # 4. Unmatched
    result("unmatched", character())
  }

  assigned <- purrr::pmap(
    list(keys$CZ_TYPE, keys$CZ_FIPS, keys$CZ_NAME),
    assign_one
  ) |>
    dplyr::bind_rows()

  dplyr::bind_cols(keys, assigned)
}

# ------------------------------------------------------------
# File discovery and loading
# ------------------------------------------------------------

list_noaa_files <- function(noaa_dir, table, years) {
  files <- list.files(
    noaa_dir,
    pattern = paste0("^StormEvents_", table, "-ftp_v1\\.0_d\\d{4}_c\\d{8}\\.csv\\.gz$"),
    full.names = TRUE
  )
  inventory <- tibble::tibble(
    table         = table,
    file          = files,
    data_year     = as.integer(stringr::str_match(basename(files), "_d(\\d{4})_")[, 2]),
    creation_date = stringr::str_match(basename(files), "_c(\\d{8})")[, 2]
  ) |>
    dplyr::filter(data_year %in% years)

  # If NOAA published a newer revision of the same year, keep the newest.
  inventory |>
    dplyr::group_by(data_year) |>
    dplyr::slice_max(creation_date, n = 1, with_ties = FALSE) |>
    dplyr::ungroup() |>
    dplyr::arrange(data_year)
}

# Read every column as character; types are set explicitly later so
# year-to-year type guessing differences cannot break row binding.
read_noaa_files <- function(files) {
  if (length(files) == 0) {
    return(tibble::tibble())
  }
  purrr::map(
    files,
    \(f) readr::read_csv(
      f,
      col_types = readr::cols(.default = readr::col_character()),
      progress = FALSE
    ) |>
      dplyr::mutate(SOURCE_FILE = basename(f))
  ) |>
    dplyr::bind_rows()
}

load_noaa_tables <- function(noaa_dir, years, project_dir) {
  inventory <- dplyr::bind_rows(
    list_noaa_files(noaa_dir, "details", years),
    list_noaa_files(noaa_dir, "fatalities", years),
    list_noaa_files(noaa_dir, "locations", years)
  )

  how_to <- paste0(
    "download StormEvents_*-ftp_v1.0_dYYYY_cYYYYMMDD.csv.gz files from ",
    "https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles/ into ",
    display_path(noaa_dir, project_dir), " (or render with download_data: true)"
  )

  details_files <- inventory$file[inventory$table == "details"]
  if (length(details_files) == 0) {
    check_input(
      file.path(noaa_dir, "StormEvents_details-ftp_v1.0_d*.csv.gz"),
      label = "NOAA Storm Events details",
      required = TRUE,
      how_to_obtain = how_to,
      affects = "the entire analysis",
      project_dir = project_dir
    )
  }

  missing_detail_years <- setdiff(years, inventory$data_year[inventory$table == "details"])
  if (length(missing_detail_years) > 0) {
    fw_log(
      "warning",
      input   = "NOAA Storm Events details",
      message = paste0("No details file for year(s): ", paste(missing_detail_years, collapse = ", "),
                       ". Those years are absent from every table and figure. To obtain them: ", how_to),
      affects = "year coverage"
    )
  }

  for (tbl in c("fatalities", "locations")) {
    have <- inventory$data_year[inventory$table == tbl]
    missing_years <- setdiff(years, have)
    if (length(missing_years) > 0) {
      fw_log(
        "warning",
        input   = paste("NOAA Storm Events", tbl),
        message = paste0("No ", tbl, " file for year(s): ", paste(missing_years, collapse = ", "),
                         ". ", tools::toTitleCase(tbl), " summaries for those years are NA."),
        affects = paste(tbl, "aggregation")
      )
    }
  }

  list(
    details    = read_noaa_files(inventory$file[inventory$table == "details"]),
    fatalities = read_noaa_files(inventory$file[inventory$table == "fatalities"]),
    locations  = read_noaa_files(inventory$file[inventory$table == "locations"]),
    inventory  = inventory
  )
}

# ------------------------------------------------------------
# Cleaning helpers
# ------------------------------------------------------------

# "10.00K" -> 10000, "2.5M" -> 2500000, "1B" -> 1e9. Blank -> NA.
parse_noaa_damage <- function(x) {
  x <- toupper(trimws(as.character(x)))
  multiplier <- dplyr::case_when(
    stringr::str_detect(x, "B$") ~ 1e9,
    stringr::str_detect(x, "M$") ~ 1e6,
    stringr::str_detect(x, "K$") ~ 1e3,
    stringr::str_detect(x, "H$") ~ 1e2,
    TRUE                         ~ 1
  )
  value <- suppressWarnings(readr::parse_number(x))
  # parse_number("K") is NA; NOAA uses a bare "K" to mean zero-reported.
  value[x %in% c("K", "M", "B", "H")] <- 0
  value * multiplier
}

duplication_check <- function(data, table_name, id_col = "EVENT_ID") {
  if (nrow(data) == 0) {
    return(tibble::tibble(
      table = table_name, rows = 0L, distinct_event_ids = 0L,
      max_rows_per_event = NA_integer_, duplicated_events = NA_integer_
    ))
  }
  counts <- dplyr::count(data, .data[[id_col]])
  tibble::tibble(
    table              = table_name,
    rows               = nrow(data),
    distinct_event_ids = nrow(counts),
    max_rows_per_event = max(counts$n),
    duplicated_events  = sum(counts$n > 1)
  )
}

# ------------------------------------------------------------
# Event-level table
# ------------------------------------------------------------

build_event_level <- function(noaa,
                              state_name,
                              years,
                              partial_years,
                              flood_pattern,
                              tropical_pattern,
                              study_counties,
                              descriptor_words,
                              special_coastal_pattern,
                              coordinate_extent,
                              damage_missing_as_zero = TRUE) {
  lookup <- nc_county_lookup()

  details <- noaa$details |>
    dplyr::filter(toupper(STATE) == toupper(state_name)) |>
    dplyr::mutate(EVENT_ID = as.integer(EVENT_ID))

  checks <- list(
    details_before    = duplication_check(details, "details (state filter, before processing)"),
    fatalities_raw    = duplication_check(noaa$fatalities, "fatalities (raw, all states)"),
    locations_raw     = duplication_check(noaa$locations, "locations (raw, all states)")
  )

  # --- Details: collapse to one row per EVENT_ID --------------------
  details_typed <- details |>
    dplyr::transmute(
      EVENT_ID,
      EPISODE_ID        = as.integer(EPISODE_ID),
      YEAR              = as.integer(YEAR),
      EVENT_TYPE        = stringr::str_squish(EVENT_TYPE),
      CZ_TYPE           = toupper(stringr::str_squish(CZ_TYPE)),
      CZ_FIPS           = as.integer(CZ_FIPS),
      CZ_NAME           = stringr::str_squish(toupper(CZ_NAME)),
      WFO,
      BEGIN_DATE_TIME   = lubridate::parse_date_time(BEGIN_DATE_TIME, orders = c("d-b-y H:M:S", "d-b-Y H:M:S"), quiet = TRUE),
      END_DATE_TIME     = lubridate::parse_date_time(END_DATE_TIME,   orders = c("d-b-y H:M:S", "d-b-Y H:M:S"), quiet = TRUE),
      INJURIES_DIRECT   = as.numeric(INJURIES_DIRECT),
      INJURIES_INDIRECT = as.numeric(INJURIES_INDIRECT),
      DEATHS_DIRECT     = as.numeric(DEATHS_DIRECT),
      DEATHS_INDIRECT   = as.numeric(DEATHS_INDIRECT),
      DAMAGE_PROPERTY_RAW = DAMAGE_PROPERTY,
      DAMAGE_CROPS_RAW    = DAMAGE_CROPS,
      PROPERTY_DAMAGE   = parse_noaa_damage(DAMAGE_PROPERTY),
      CROP_DAMAGE       = parse_noaa_damage(DAMAGE_CROPS),
      FLOOD_CAUSE,
      BEGIN_LAT         = as.numeric(BEGIN_LAT),
      BEGIN_LON         = as.numeric(BEGIN_LON),
      END_LAT           = as.numeric(END_LAT),
      END_LON           = as.numeric(END_LON),
      EVENT_NARRATIVE,
      EPISODE_NARRATIVE,
      SOURCE_FILE
    )

  dup_ids <- details_typed |>
    dplyr::count(EVENT_ID) |>
    dplyr::filter(n > 1) |>
    dplyr::pull(EVENT_ID)

  impact_cols <- c(
    "INJURIES_DIRECT", "INJURIES_INDIRECT", "DEATHS_DIRECT",
    "DEATHS_INDIRECT", "PROPERTY_DAMAGE", "CROP_DAMAGE"
  )

  # Repeated rows for one event repeat the same event-level values, so
  # impacts take max() (never sum); metadata takes the first non-missing.
  collapsed_dups <- details_typed |>
    dplyr::filter(EVENT_ID %in% dup_ids) |>
    dplyr::group_by(EVENT_ID) |>
    dplyr::summarise(
      dplyr::across(dplyr::all_of(impact_cols), max_or_na),
      dplyr::across(!dplyr::all_of(impact_cols), first_nonmissing),
      .groups = "drop"
    )

  details_one <- dplyr::bind_rows(
    dplyr::filter(details_typed, !EVENT_ID %in% dup_ids),
    collapsed_dups
  )

  # --- Fatalities: aggregate separately ------------------------------
  fatality_summary <- if (nrow(noaa$fatalities) > 0) {
    noaa$fatalities |>
      dplyr::mutate(EVENT_ID = as.integer(EVENT_ID)) |>
      dplyr::filter(EVENT_ID %in% details_one$EVENT_ID) |>
      dplyr::distinct(EVENT_ID, FATALITY_ID, .keep_all = TRUE) |>
      dplyr::group_by(EVENT_ID) |>
      dplyr::summarise(
        fatality_records          = dplyr::n(),
        fatality_records_direct   = sum(toupper(FATALITY_TYPE) == "D", na.rm = TRUE),
        fatality_records_indirect = sum(toupper(FATALITY_TYPE) == "I", na.rm = TRUE),
        .groups = "drop"
      )
  } else {
    tibble::tibble(EVENT_ID = integer(), fatality_records = integer(),
                   fatality_records_direct = integer(), fatality_records_indirect = integer())
  }

  # --- Locations: aggregate separately -------------------------------
  location_summary <- if (nrow(noaa$locations) > 0) {
    noaa$locations |>
      dplyr::mutate(
        EVENT_ID       = as.integer(EVENT_ID),
        LOCATION_INDEX = as.integer(LOCATION_INDEX),
        LATITUDE       = as.numeric(LATITUDE),
        LONGITUDE      = as.numeric(LONGITUDE)
      ) |>
      dplyr::filter(EVENT_ID %in% details_one$EVENT_ID) |>
      dplyr::arrange(EVENT_ID, LOCATION_INDEX) |>
      dplyr::group_by(EVENT_ID) |>
      dplyr::summarise(
        location_records   = dplyr::n(),
        location_first_lat = first_nonmissing(LATITUDE),
        location_first_lon = first_nonmissing(LONGITUDE),
        .groups = "drop"
      )
  } else {
    tibble::tibble(EVENT_ID = integer(), location_records = integer(),
                   location_first_lat = numeric(), location_first_lon = numeric())
  }

  # --- Regions --------------------------------------------------------
  regions <- assign_nc_region(
    details_one,
    descriptor_words        = descriptor_words,
    special_coastal_pattern = special_coastal_pattern,
    lookup                  = lookup
  )

  study_upper <- toupper(study_counties)
  in_extent <- function(lon, lat) {
    !is.na(lon) & !is.na(lat) &
      lon >= coordinate_extent$lon_min & lon <= coordinate_extent$lon_max &
      lat >= coordinate_extent$lat_min & lat <= coordinate_extent$lat_max
  }

  # --- Assemble -------------------------------------------------------
  event_level <- details_one |>
    dplyr::left_join(regions, by = c("CZ_TYPE", "CZ_FIPS", "CZ_NAME")) |>
    dplyr::left_join(fatality_summary, by = "EVENT_ID") |>
    dplyr::left_join(location_summary, by = "EVENT_ID") |>
    dplyr::mutate(
      begin_in_extent    = in_extent(BEGIN_LON, BEGIN_LAT),
      location_in_extent = in_extent(location_first_lon, location_first_lat),
      event_coordinate_quality = dplyr::case_when(
        begin_in_extent                          ~ "noaa_begin_point",
        location_in_extent                       ~ "noaa_locations_table_first_point",
        !is.na(BEGIN_LAT) | !is.na(location_first_lat) ~ "outside_state_extent",
        TRUE                                     ~ "missing"
      ),
      longitude = dplyr::case_when(begin_in_extent ~ BEGIN_LON, location_in_extent ~ location_first_lon),
      latitude  = dplyr::case_when(begin_in_extent ~ BEGIN_LAT, location_in_extent ~ location_first_lat)
    )

  if (damage_missing_as_zero) {
    event_level <- event_level |>
      dplyr::mutate(
        property_damage_reported = as.integer(!is.na(PROPERTY_DAMAGE)),
        crop_damage_reported     = as.integer(!is.na(CROP_DAMAGE)),
        PROPERTY_DAMAGE = tidyr::replace_na(PROPERTY_DAMAGE, 0),
        CROP_DAMAGE     = tidyr::replace_na(CROP_DAMAGE, 0)
      )
  } else {
    event_level <- event_level |>
      dplyr::mutate(
        property_damage_reported = as.integer(!is.na(PROPERTY_DAMAGE)),
        crop_damage_reported     = as.integer(!is.na(CROP_DAMAGE))
      )
  }

  event_level <- event_level |>
    dplyr::transmute(
      # Identifiers and context
      event_id                 = EVENT_ID,
      episode_id               = EPISODE_ID,
      event_date               = as.Date(BEGIN_DATE_TIME),
      event_end_date           = as.Date(END_DATE_TIME),
      year                     = YEAR,
      event_year               = lubridate::year(BEGIN_DATE_TIME),
      event_month              = lubridate::month(BEGIN_DATE_TIME),
      event_day_of_year        = lubridate::yday(BEGIN_DATE_TIME),
      event_type               = EVENT_TYPE,
      flood_cause              = FLOOD_CAUSE,
      cz_name                  = CZ_NAME,
      cz_type                  = CZ_TYPE,
      cz_fips                  = CZ_FIPS,
      wfo                      = WFO,
      region,
      region_assignment_method,
      matched_county,
      matched_county_fips,
      in_study_area            = purrr::map_lgl(
        stringr::str_split(matched_county, "; "),
        \(x) any(x %in% study_upper)
      ),
      longitude,
      latitude,
      event_coordinate_quality,
      begin_lat                = BEGIN_LAT,
      begin_lon                = BEGIN_LON,
      end_lat                  = END_LAT,
      end_lon                  = END_LON,
      # Outcomes
      injuries_direct          = tidyr::replace_na(INJURIES_DIRECT, 0),
      injuries_indirect        = tidyr::replace_na(INJURIES_INDIRECT, 0),
      total_injuries           = injuries_direct + injuries_indirect,
      deaths_direct            = tidyr::replace_na(DEATHS_DIRECT, 0),
      deaths_indirect          = tidyr::replace_na(DEATHS_INDIRECT, 0),
      total_deaths             = deaths_direct + deaths_indirect,
      property_damage_dollars  = PROPERTY_DAMAGE,
      crop_damage_dollars      = CROP_DAMAGE,
      total_damage             = property_damage_dollars + crop_damage_dollars,
      property_damage_reported,
      crop_damage_reported,
      any_death                = as.integer(total_deaths > 0),
      any_injury               = as.integer(total_injuries > 0),
      any_damage               = as.integer(total_damage > 0),
      # Separate record counts from the fatalities/locations tables
      fatality_records         = tidyr::replace_na(fatality_records, 0L),
      fatality_records_direct  = tidyr::replace_na(fatality_records_direct, 0L),
      fatality_records_indirect = tidyr::replace_na(fatality_records_indirect, 0L),
      location_records         = tidyr::replace_na(location_records, 0L),
      # Flags
      is_flood_event           = as.integer(stringr::str_detect(EVENT_TYPE, stringr::regex(flood_pattern, ignore_case = TRUE))),
      is_tropical_event        = as.integer(stringr::str_detect(EVENT_TYPE, stringr::regex(tropical_pattern, ignore_case = TRUE))),
      is_partial_year          = year %in% partial_years,
      event_narrative          = EVENT_NARRATIVE,
      episode_narrative        = EPISODE_NARRATIVE,
      noaa_source_file         = SOURCE_FILE
    ) |>
    dplyr::filter(!is.na(event_id), year %in% years) |>
    dplyr::arrange(event_date, event_id)

  checks$event_level_after <- duplication_check(event_level, "event-level table (after processing)", id_col = "event_id")

  if (checks$event_level_after$max_rows_per_event != 1 || checks$event_level_after$duplicated_events != 0) {
    stop("Event-level table does not have exactly one row per EVENT_ID.", call. = FALSE)
  }

  # Compare details-table death counts with fatality-table record counts.
  # Differences are reported, never "corrected".
  fatality_consistency <- event_level |>
    dplyr::filter(total_deaths > 0 | fatality_records > 0) |>
    dplyr::summarise(
      events_with_deaths_or_fatality_records = dplyr::n(),
      counts_agree                           = sum(total_deaths == fatality_records),
      details_greater_than_records           = sum(total_deaths > fatality_records),
      records_greater_than_details           = sum(total_deaths < fatality_records)
    )

  list(
    event_level          = event_level,
    duplication_checks   = dplyr::bind_rows(checks),
    region_assignments   = regions,
    county_lookup_issues = validate_county_lookup(details, lookup),
    fatality_consistency = fatality_consistency
  )
}
