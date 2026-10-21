# ============================================================
# Carolina HighGround — event-level spatial features
# ============================================================
#
# Point/buffer-based features around each NOAA event point:
#
#   NHD High Resolution flowlines   distance, counts, length density
#   WBD HUC12 polygons              containing HUC12 (membership only)
#   NCDOT culverts and structures   distance, counts
#   3DEP-derived terrain rasters    point values, buffer means
#   Annual NLCD imperviousness 2023 point value, buffer means
#
# These are NOT catchment or upstream-contributing-area features.
# HUC12 membership says which subwatershed a point falls in; it
# does not describe the area draining to that point.
#
# All distances, buffers, and intersections use the analysis CRS
# (EPSG:32119). Raster extraction projects the buffers into each
# raster's native CRS instead of resampling the rasters.
#
# Requires: scripts/utils.R, sf, terra, dplyr, arrow.

# ------------------------------------------------------------
# NHD / WBD file discovery (extract from ZIP only when needed)
# ------------------------------------------------------------

# Find shapefiles for a layer family (e.g. "NHDFlowline" matches
# NHDFlowline.shp, NHDFlowline_0.shp, NHDFlowline_1.shp). If none are
# extracted yet, extract only the needed members from the ZIP.
locate_nhd_layer <- function(layer_regex, extract_dir, zip_path) {
  shp_regex <- paste0("^", layer_regex, "(_\\d+)?\\.shp$")
  find_existing <- function() {
    list.files(extract_dir, pattern = shp_regex, recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
  }

  existing <- find_existing()
  if (length(existing) > 0) {
    return(existing)
  }

  if (is.na(zip_path) || !file.exists(zip_path)) {
    return(character())
  }

  members <- utils::unzip(zip_path, list = TRUE)$Name
  wanted <- members[stringr::str_detect(
    basename(members),
    stringr::regex(paste0("^", layer_regex, "(_\\d+)?\\.(shp|shx|dbf|prj|cpg)$"), ignore_case = TRUE)
  )]
  if (length(wanted) == 0) {
    return(character())
  }

  fw_log("info", input = "NHD ZIP",
         message = paste("Extracting", length(wanted), "member(s) for", layer_regex, "to", extract_dir))
  dir.create(extract_dir, recursive = TRUE, showWarnings = FALSE)
  utils::unzip(zip_path, files = wanted, exdir = extract_dir)
  find_existing()
}

# Geometry type and dimension of each layer before cleaning. Used in
# the validation table so XYZM inputs are visible in the report.
describe_vector_layer <- function(path, dataset) {
  layers <- sf::st_layers(path)
  tibble::tibble(
    dataset       = dataset,
    file          = basename(path),
    layer         = layers$name,
    geometry_type = vapply(layers$geomtype, \(g) paste(g, collapse = ","), character(1)),
    features      = layers$features,
    crs           = vapply(layers$crs, \(c) if (is.null(c$input)) NA_character_ else c$input, character(1))
  )
}

# ------------------------------------------------------------
# Layer loaders
# ------------------------------------------------------------

load_nhd_flowlines <- function(paths, ftypes, target_crs, extent_4326 = NULL) {
  pieces <- purrr::map(paths, function(p) {
    layer <- tools::file_path_sans_ext(basename(p))
    fields <- names(sf::st_read(p, query = sprintf('SELECT * FROM "%s" LIMIT 0', layer), quiet = TRUE))
    where <- if ("ftype" %in% tolower(fields) && length(ftypes) > 0) {
      sprintf(" WHERE ftype IN (%s)", paste(ftypes, collapse = ", "))
    } else {
      fw_log("warning", input = basename(p),
             message = "No 'ftype' field found; all flowline types are used (no stream-type filter).",
             affects = "NHD features")
      ""
    }
    keep <- intersect(c("permanent_", "ftype", "fcode", "gnis_name", "lengthkm", "reachcode"), fields)
    sql <- sprintf('SELECT %s FROM "%s"%s', paste(keep, collapse = ", "), layer, where)
    wkt <- if (is.null(extent_4326)) character(0) else sf::st_as_text(sf::st_as_sfc(extent_4326))
    sf::st_read(p, query = sql, wkt_filter = wkt, quiet = TRUE)
  })
  dplyr::bind_rows(pieces) |>
    clean_spatial_layer(target_crs)
}

load_point_layer <- function(path, target_crs) {
  sf::st_read(path, quiet = TRUE) |>
    clean_spatial_layer(target_crs)
}

# ------------------------------------------------------------
# Feature calculators
# ------------------------------------------------------------

nearest_distance_m <- function(points, features) {
  if (nrow(features) == 0) {
    return(rep(NA_real_, nrow(points)))
  }
  idx <- sf::st_nearest_feature(points, features)
  as.numeric(sf::st_distance(points, features[idx, ], by_element = TRUE))
}

count_within_m <- function(points, features, radius_m) {
  if (nrow(features) == 0) {
    return(rep(0L, nrow(points)))
  }
  # Buffer + st_intersects uses the GEOS STRtree index; st_is_within_distance
  # on projected data does not and is orders of magnitude slower here.
  lengths(sf::st_intersects(sf::st_buffer(points, dist = radius_m), features))
}

# Total flowline length (km) inside each circular buffer divided by the
# buffer area (km^2). A local drainage-density proxy, not a basin metric.
stream_length_density <- function(points, flowlines, radius_m) {
  buffers <- sf::st_buffer(points, dist = radius_m)
  buffers$.row <- seq_len(nrow(buffers))
  pieces <- suppressWarnings(sf::st_intersection(buffers[".row"], sf::st_geometry(flowlines)))
  lengths_km <- tapply(as.numeric(sf::st_length(pieces)) / 1000, pieces$.row, sum)
  out <- rep(0, nrow(points))
  out[as.integer(names(lengths_km))] <- as.numeric(lengths_km)
  out / (pi * (radius_m / 1000)^2)
}

# Point values and buffer means from one raster. Points and buffers are
# built in the analysis CRS and projected to the raster CRS.
extract_raster_features <- function(points, raster_path, point_name, buffer_names, buffer_radii,
                                    valid_range = c(-Inf, Inf), fun = mean) {
  r <- terra::rast(raster_path)[[1]]
  raster_crs <- terra::crs(r)

  clamp <- function(v) {
    v <- as.numeric(v)
    v[!is.na(v) & (v < valid_range[1] | v > valid_range[2])] <- NA_real_
    v
  }

  pts <- terra::project(terra::vect(points), raster_crs)
  out <- tibble::tibble(!!point_name := clamp(terra::extract(r, pts, ID = FALSE)[[1]]))

  for (i in seq_along(buffer_names)) {
    buf <- terra::project(terra::vect(sf::st_buffer(points, dist = buffer_radii[[i]])), raster_crs)
    vals <- terra::extract(r, buf, fun = fun, na.rm = TRUE, ID = FALSE)[[1]]
    vals[is.infinite(vals)] <- NA_real_
    vals[is.nan(vals)] <- NA_real_
    out[[buffer_names[[i]]]] <- clamp(vals)
  }
  out
}

# ------------------------------------------------------------
# Orchestrator
# ------------------------------------------------------------
#
# inputs: named list of resolved paths
#   nhd_zip, nhd_dir, ncdot_culverts, ncdot_structures,
#   dem, slope, roughness, nlcd
# settings: named list
#   analysis_crs, geographic_crs, event_buffer_m, stream_buffer_m,
#   infrastructure_buffer_m, nhd_flowline_ftypes, include_* flags,
#   compute_stream_density

# Year-matched raster extraction: each event uses the raster for its own
# year when one exists, otherwise the nearest available year (earlier years
# fall back to the first file, later years to the last). Returns the
# features plus the vintage actually used per event.
year_matched_raster_features <- function(points, event_years, year_paths, point_name,
                                         buffer_names, buffer_radii, valid_range = c(-Inf, Inf)) {
  avail <- sort(as.integer(names(year_paths)))
  vintage <- vapply(event_years, function(y) {
    if (is.na(y)) return(max(avail))
    earlier <- avail[avail <= y]
    if (length(earlier) > 0) max(earlier) else min(avail)
  }, integer(1))
  out <- NULL
  for (v in sort(unique(vintage))) {
    idx <- which(vintage == v)
    vals <- extract_raster_features(points[idx, ], year_paths[[as.character(v)]], point_name,
                                    buffer_names, buffer_radii, valid_range)
    vals$.row <- idx
    out <- dplyr::bind_rows(out, vals)
  }
  out <- out[order(out$.row), setdiff(names(out), ".row")]
  out$vintage <- vintage
  out
}

# CDC/ATSDR tract SVI for each event point. Each event takes the latest SVI
# release at or before its year (earlier events use the first release), on
# that release's tract geography (2016/2018 releases use 2010 tracts,
# 2020/2022 use 2020 tracts). Percentiles are ranks within one release.
svi_tract_features <- function(points, event_years, svi_files, tract_files, analysis_crs) {
  releases <- sort(as.integer(names(svi_files)))
  release <- vapply(event_years, function(y) {
    if (is.na(y)) return(max(releases))
    earlier <- releases[releases <= y]
    if (length(earlier) > 0) max(earlier) else min(releases)
  }, integer(1))
  geog_of <- function(r) if (r < 2020) "2010" else "2020"
  tract_ids <- list()
  for (g in unique(vapply(release, geog_of, character(1)))) {
    tr <- sf::st_read(tract_files[[g]], quiet = TRUE) |> clean_spatial_layer(analysis_crs)
    tr$fips <- if ("GEOID" %in% names(tr)) as.character(tr$GEOID) else substr(as.character(tr$GEO_ID), 10, 20)
    j <- sf::st_join(points["event_id"], tr["fips"], join = sf::st_within, left = TRUE)
    tract_ids[[g]] <- j$fips[match(points$event_id, j$event_id)]
  }
  cols <- c("RPL_THEMES", "RPL_THEME1", "RPL_THEME2", "RPL_THEME3", "RPL_THEME4")
  out <- matrix(NA_real_, nrow(points), length(cols), dimnames = list(NULL, cols))
  for (r in unique(release)) {
    svi <- readr::read_csv(svi_files[[as.character(r)]], show_col_types = FALSE,
                           col_types = readr::cols(FIPS = "c", .default = "c"))
    svi$FIPS <- sprintf("%011s", svi$FIPS)
    idx <- which(release == r)
    m <- match(tract_ids[[geog_of(r)]][idx], svi$FIPS)
    for (cn in cols) {
      v <- suppressWarnings(as.numeric(svi[[cn]][m]))
      v[!is.na(v) & v < 0] <- NA_real_          # CDC codes missing as -999
      out[idx, cn] <- v
    }
  }
  tibble::tibble(
    svi_rpl_themes = out[, "RPL_THEMES"], svi_rpl_theme1 = out[, "RPL_THEME1"],
    svi_rpl_theme2 = out[, "RPL_THEME2"], svi_rpl_theme3 = out[, "RPL_THEME3"],
    svi_rpl_theme4 = out[, "RPL_THEME4"], svi_vintage = release
  )
}

feature_column_names <- function(settings) {
  eb <- buffer_label(settings$event_buffer_m)
  sb <- buffer_label(settings$stream_buffer_m)
  ib <- buffer_label(settings$infrastructure_buffer_m)
  list(
    nhd = unique(c(
      "distance_to_stream_m",
      paste0("streams_within_", sb),
      paste0("streams_within_", ib),
      if (isTRUE(settings$compute_stream_density)) paste0("stream_density_km_per_km2_", sb)
    )),
    wbd = c("huc12", "huc12_name", "huc12_area_km2"),
    ncdot = unique(c(
      "distance_to_nearest_culvert_m",
      paste0("culverts_within_", c(eb, ib)),
      "distance_to_nearest_structure_m",
      paste0("structures_within_", c(eb, ib))
    )),
    dem = c(
      "elevation_m", paste0("elevation_mean_", eb),
      "slope_degrees", paste0("slope_mean_", eb),
      "terrain_roughness", paste0("roughness_mean_", eb)
    ),
    nlcd = unique(c(
      "impervious_mean_event",
      paste0("impervious_mean_", c(eb, ib))
    )),
    hydro = c("hand_m", paste0("drainage_area_km2_max_", eb), "log_drainage_area_km2"),
    svi = c("svi_rpl_themes", "svi_rpl_theme1", "svi_rpl_theme2", "svi_rpl_theme3", "svi_rpl_theme4")
  )
}

build_spatial_features <- function(events, inputs, settings, project_dir) {
  cols <- feature_column_names(settings)
  eb <- buffer_label(settings$event_buffer_m)
  sb <- buffer_label(settings$stream_buffer_m)
  ib <- buffer_label(settings$infrastructure_buffer_m)

  located <- events |>
    dplyr::filter(!is.na(longitude), !is.na(latitude))

  out <- tibble::tibble(event_id = located$event_id)
  methods <- character()
  coverage <- character()
  layer_summary <- list()
  layers_for_maps <- list()

  if (nrow(located) == 0) {
    fw_log("warning", input = "event coordinates",
           message = "No events in scope have usable coordinates; all spatial features are NA.",
           affects = "all spatial features")
    return(list(features = out, methods = methods, coverage = coverage,
                layer_summary = tibble::tibble(), layers = layers_for_maps))
  }

  points <- sf::st_as_sf(
    located |> dplyr::select(event_id, longitude, latitude, event_year),
    coords = c("longitude", "latitude"),
    crs = settings$geographic_crs,
    remove = FALSE
  ) |>
    clean_spatial_layer(settings$analysis_crs)

  extent_4326 <- sf::st_bbox(
    sf::st_transform(sf::st_buffer(points, settings$infrastructure_buffer_m * 1.2), 4269)
  )

  fill_na <- function(names) {
    for (nm in names) out[[nm]] <<- NA
  }

  # --- NHD --------------------------------------------------------------
  if (isTRUE(settings$include_nhd_features)) {
    flow_paths <- locate_nhd_layer("NHDFlowline", inputs$nhd_dir, inputs$nhd_zip)
    if (length(flow_paths) == 0) {
      check_input(inputs$nhd_zip, "NHD flowlines", required = FALSE,
                  how_to_obtain = "download NHD_H_North_Carolina_State_Shape.zip from https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/NHD/State/Shape/",
                  affects = "NHD stream features (set to NA)", project_dir = project_dir)
      fill_na(cols$nhd)
      coverage <- c(coverage, "NHD flowlines unavailable: stream features are NA (not zero)")
    } else {
      layer_summary$nhd <- dplyr::bind_rows(purrr::map(flow_paths, describe_vector_layer, dataset = "NHD flowlines"))
      message("Loading NHD flowlines from ", length(flow_paths), " shapefile(s)...")
      flowlines <- load_nhd_flowlines(flow_paths, settings$nhd_flowline_ftypes, settings$analysis_crs, extent_4326)
      layers_for_maps$flowlines_n <- nrow(flowlines)

      out$distance_to_stream_m <- nearest_distance_m(points, flowlines)
      out[[paste0("streams_within_", sb)]] <- count_within_m(points, flowlines, settings$stream_buffer_m)
      out[[paste0("streams_within_", ib)]] <- count_within_m(points, flowlines, settings$infrastructure_buffer_m)
      if (isTRUE(settings$compute_stream_density)) {
        out[[paste0("stream_density_km_per_km2_", sb)]] <- stream_length_density(points, flowlines, settings$stream_buffer_m)
      }
      methods <- c(methods, sprintf(
        "NHD HR flowlines (ftype %s) from %d shapefile(s): nearest distance and counts within %s/%s",
        paste(settings$nhd_flowline_ftypes, collapse = "/"), length(flow_paths), sb, ib
      ))
      rm(flowlines)
      gc(verbose = FALSE)
    }
  } else {
    fill_na(cols$nhd)
    coverage <- c(coverage, "NHD features disabled by configuration")
  }

  # --- WBD HUC12 membership ----------------------------------------------
  if (isTRUE(settings$include_wbd_features)) {
    huc_paths <- locate_nhd_layer("WBDHU12", inputs$nhd_dir, inputs$nhd_zip)
    if (length(huc_paths) == 0) {
      fw_log("warning", input = "WBD HUC12", message = "WBDHU12 layer not found in NHD directory or ZIP.",
             affects = "HUC12 membership (set to NA)")
      fill_na(cols$wbd)
      coverage <- c(coverage, "WBD HUC12 unavailable")
    } else {
      layer_summary$wbd <- describe_vector_layer(huc_paths[[1]], "WBD HUC12")
      huc12 <- sf::st_read(huc_paths[[1]], quiet = TRUE) |>
        dplyr::select(huc12, huc12_name = name, huc12_area_km2 = areasqkm) |>
        clean_spatial_layer(settings$analysis_crs)
      joined <- sf::st_join(points["event_id"], huc12, join = sf::st_within, left = TRUE) |>
        sf::st_drop_geometry() |>
        dplyr::distinct(event_id, .keep_all = TRUE)
      out <- dplyr::left_join(out, joined, by = "event_id")
      methods <- c(methods, "WBD HUC12 polygon containing the event point (membership only, not upstream area)")
    }
  }

  # --- NCDOT ---------------------------------------------------------------
  if (isTRUE(settings$include_ncdot_features)) {
    for (kind in c("culvert", "structure")) {
      path <- inputs[[paste0("ncdot_", kind, "s")]]
      prefix <- paste0(kind, "s_within_")
      dist_col <- paste0("distance_to_nearest_", kind, "_m")
      ok <- check_input(path, paste("NCDOT", kind, "s"), required = FALSE,
                        how_to_obtain = "render with download_data: true (NCDOT_Structures ArcGIS service)",
                        affects = paste("NCDOT", kind, "features (set to NA)"), project_dir = project_dir)
      if (!ok) {
        out[[dist_col]] <- NA_real_
        out[[paste0(prefix, eb)]] <- NA_integer_
        out[[paste0(prefix, ib)]] <- NA_integer_
        coverage <- c(coverage, paste0("NCDOT ", kind, "s unavailable: features are NA"))
        next
      }
      layer_summary[[kind]] <- describe_vector_layer(path, paste0("NCDOT ", kind, "s"))
      layer <- load_point_layer(path, settings$analysis_crs)
      out[[dist_col]] <- nearest_distance_m(points, layer)
      out[[paste0(prefix, eb)]] <- count_within_m(points, layer, settings$event_buffer_m)
      out[[paste0(prefix, ib)]] <- count_within_m(points, layer, settings$infrastructure_buffer_m)
    }
    methods <- c(methods, sprintf("NCDOT culverts/structures: nearest distance and counts within %s/%s", eb, ib))
    coverage <- c(coverage, "NCDOT inventory may be incomplete; absence does not prove no asset exists")
  } else {
    fill_na(cols$ncdot)
    coverage <- c(coverage, "NCDOT features disabled by configuration")
  }

  # --- DEM terrain --------------------------------------------------------
  if (isTRUE(settings$include_dem_features)) {
    rasters <- list(
      elevation = list(path = inputs$dem,       point = "elevation_m",       buffer = paste0("elevation_mean_", eb)),
      slope     = list(path = inputs$slope,     point = "slope_degrees",     buffer = paste0("slope_mean_", eb)),
      roughness = list(path = inputs$roughness, point = "terrain_roughness", buffer = paste0("roughness_mean_", eb))
    )
    for (nm in names(rasters)) {
      spec <- rasters[[nm]]
      ok <- check_input(spec$path, paste("3DEP", nm, "raster"), required = FALSE,
                        how_to_obtain = "render with download_data: true (elevatr/AWS terrain tiles, terrain derived with terra)",
                        affects = paste(nm, "features (set to NA)"), project_dir = project_dir)
      if (!ok) {
        fill_na(c(spec$point, spec$buffer))
        coverage <- c(coverage, paste0("3DEP ", nm, " raster unavailable"))
        next
      }
      vals <- extract_raster_features(points, spec$path, spec$point, spec$buffer, settings$event_buffer_m)
      out[[spec$point]] <- vals[[spec$point]]
      out[[spec$buffer]] <- vals[[spec$buffer]]
    }
    res_m <- if (!is.na(inputs$dem) && file.exists(inputs$dem)) round(terra::res(terra::rast(inputs$dem))[1], 1) else NA
    methods <- c(methods, sprintf("DEM-derived terrain (%.1f m cells): point value and mean within %s", res_m, eb))
  } else {
    fill_na(cols$dem)
    coverage <- c(coverage, "DEM features disabled by configuration")
  }

  # --- NLCD imperviousness --------------------------------------------------
  if (isTRUE(settings$include_nlcd_features)) {
    ok <- check_input(inputs$nlcd, "Annual NLCD fractional imperviousness", required = FALSE,
                      how_to_obtain = "render with download_data: true (USGS Annual NLCD ImageServer)",
                      affects = "imperviousness features (set to NA)", project_dir = project_dir)
    if (ok) {
      # Yearly rasters sit next to the configured one: annual_nlcd_fractional_impervious_<YYYY>_NC.tif
      year_files <- list.files(dirname(inputs$nlcd), pattern = "^annual_nlcd_fractional_impervious_\\d{4}_NC\\.tif$", full.names = TRUE)
      year_paths <- stats::setNames(as.list(year_files), stringr::str_extract(basename(year_files), "\\d{4}"))
      if (!isTRUE(settings$nlcd_year_matched) || length(year_paths) == 0) {
        year_paths <- stats::setNames(list(inputs$nlcd), settings$nlcd_vintage)
      }
      vals <- year_matched_raster_features(
        points, points$event_year, year_paths, "impervious_mean_event",
        buffer_names = paste0("impervious_mean_", c(eb, ib)),
        buffer_radii = c(settings$event_buffer_m, settings$infrastructure_buffer_m),
        valid_range  = c(0, 100)
      )
      for (nm in setdiff(names(vals), "vintage")) out[[nm]] <- vals[[nm]]
      out$impervious_vintage <- vals$vintage
      res_m <- round(terra::res(terra::rast(inputs$nlcd))[1], 1)
      yrs <- range(as.integer(names(year_paths)))
      if (length(year_paths) > 1) {
        methods <- c(methods, sprintf(
          "Annual NLCD fractional imperviousness, year-matched %d-%d (%.1f m cells; events after %d use %d): point value and means within %s/%s",
          yrs[1], yrs[2], res_m, yrs[2], yrs[2], eb, ib))
        coverage <- c(coverage, sprintf("NLCD imperviousness is year-matched for %d-%d; later events use the %d layer", yrs[1], yrs[2], yrs[2]))
      } else {
        methods <- c(methods, sprintf(
          "Annual NLCD fractional imperviousness %s (%.1f m cells; single static layer): point value and means within %s/%s",
          names(year_paths), res_m, eb, ib))
        coverage <- c(coverage, paste0("NLCD imperviousness is a single ", names(year_paths),
                                       " layer, not land cover for the event year"))
      }
    } else {
      fill_na(cols$nlcd)
      coverage <- c(coverage, "NLCD imperviousness unavailable: features are NA")
    }
  } else {
    fill_na(cols$nlcd)
    coverage <- c(coverage, "NLCD features disabled by configuration")
  }

  # --- Hydrology (WhiteboxTools rasters from src/R/hydrology.R) -------------
  if (isTRUE(settings$include_hydro_features)) {
    hand_path <- file.path(inputs$hydro_dir, "hand_m.tif")
    acc_path  <- file.path(inputs$hydro_dir, "flow_acc_km2.tif")
    if (!is.na(inputs$hydro_dir) && file.exists(hand_path) && file.exists(acc_path)) {
      hand <- extract_raster_features(points, hand_path, "hand_m", character(), numeric(), valid_range = c(-5, 5000))
      acc  <- extract_raster_features(points, acc_path, "drainage_at_point", paste0("drainage_area_km2_max_", eb),
                                      settings$event_buffer_m, valid_range = c(0, 1e6), fun = max)
      out$hand_m <- pmax(hand$hand_m, 0)
      out[[paste0("drainage_area_km2_max_", eb)]] <- acc[[paste0("drainage_area_km2_max_", eb)]]
      out$log_drainage_area_km2 <- log10(1 + out[[paste0("drainage_area_km2_max_", eb)]])
      # Basins that extend beyond NC are truncated at the state line by the DEM.
      hu8_paths <- locate_nhd_layer("WBDHU8", inputs$nhd_dir, inputs$nhd_zip)
      if (length(hu8_paths) > 0) {
        hu8 <- sf::st_read(hu8_paths[[1]], quiet = TRUE) |> dplyr::select(states) |> clean_spatial_layer(settings$analysis_crs)
        j <- sf::st_join(points["event_id"], hu8, join = sf::st_within, left = TRUE) |> sf::st_drop_geometry() |>
          dplyr::distinct(event_id, .keep_all = TRUE)
        out$hydro_basin_crosses_state <- as.integer(!is.na(j$states[match(out$event_id, j$event_id)]) &
                                                      j$states[match(out$event_id, j$event_id)] != "NC")
      }
      methods <- c(methods, sprintf(
        "DEM hydrology (WhiteboxTools: breached DEM, D8 flow accumulation, streams >= %s km2, elevation above stream): HAND at point, max drainage area within %s",
        settings$stream_threshold_km2 %||% 1, eb))
      coverage <- c(coverage, "Drainage area is underestimated where a basin extends beyond NC (flag hydro_basin_crosses_state)")
    } else {
      fw_log("warning", input = "Hydrology rasters",
             message = paste("Not found in", inputs$hydro_dir, "- run build_hydro_rasters() in src/R/hydrology.R."),
             affects = "hydrology features (set to NA)")
      fill_na(cols$hydro)
      coverage <- c(coverage, "Hydrology rasters unavailable: features are NA")
    }
  } else {
    fill_na(cols$hydro)
  }

  # --- Tract-level social vulnerability (CDC/ATSDR SVI) -------------------
  if (isTRUE(settings$include_svi_features)) {
    svi_files <- list.files(inputs$svi_dir, pattern = "^svi_\\d{4}_nc_tract\\.csv$", full.names = TRUE)
    svi_files <- stats::setNames(as.list(svi_files), stringr::str_extract(basename(svi_files), "\\d{4}"))
    tract_files <- list(`2010` = inputs$tracts_2010, `2020` = inputs$tracts_2020)
    if (length(svi_files) > 0 && all(file.exists(unlist(tract_files)))) {
      svi <- svi_tract_features(points, points$event_year, svi_files, tract_files, settings$analysis_crs)
      for (nm in names(svi)) out[[nm]] <- svi[[nm]]
      methods <- c(methods, sprintf("CDC/ATSDR SVI (tract, releases %s): latest release at or before the event year",
                                    paste(names(svi_files), collapse = "/")))
      coverage <- c(coverage, "SVI percentiles are ranks within one release and one state; do not compare values across releases")
    } else {
      fw_log("warning", input = "CDC/ATSDR SVI", message = "SVI CSVs or tract boundaries missing.",
             affects = "tract SVI features (set to NA)")
      fill_na(cols$svi)
      coverage <- c(coverage, "Tract SVI unavailable: features are NA")
    }
  } else {
    fill_na(cols$svi)
  }

  list(
    features      = out,
    methods       = methods,
    coverage      = coverage,
    layer_summary = dplyr::bind_rows(layer_summary)
  )
}

# ------------------------------------------------------------
# Cache wrapper
# ------------------------------------------------------------
# The feature table is cached as Parquet with an RDS sidecar holding
# the configuration + input-file signature. The cache is reused only
# when the signature matches exactly.

spatial_feature_signature <- function(events, inputs, settings) {
  list(
    settings   = settings,
    inputs     = file_signature(unlist(inputs)),
    nhd_files  = file_signature(list.files(inputs$nhd_dir, pattern = "^(NHDFlowline|WBDHU12|WBDHU8)", recursive = TRUE, full.names = TRUE)),
    nlcd_years = file_signature(list.files(dirname(inputs$nlcd), pattern = "^annual_nlcd_fractional_impervious_\\d{4}_NC\\.tif$", full.names = TRUE)),
    svi_files  = if (!is.null(inputs$svi_dir)) file_signature(list.files(inputs$svi_dir, full.names = TRUE)) else NULL,
    hydro      = if (!is.null(inputs$hydro_dir)) file_signature(list.files(inputs$hydro_dir, pattern = "^(hand_m|flow_acc_km2)\\.tif$", full.names = TRUE)) else NULL,
    event_ids  = digest::digest(sort(events$event_id[!is.na(events$longitude)])),
    coords     = digest::digest(events[!is.na(events$longitude), c("event_id", "longitude", "latitude")])
  )
}

cached_spatial_features <- function(events, inputs, settings, cache_dir, use_cache, refresh, project_dir) {
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  cache_file <- file.path(cache_dir, "event_spatial_features.parquet")
  meta_file  <- file.path(cache_dir, "event_spatial_features_meta.rds")
  signature  <- spatial_feature_signature(events, inputs, settings)

  if (use_cache && !refresh && file.exists(cache_file) && file.exists(meta_file)) {
    meta <- readRDS(meta_file)
    if (identical(meta$signature, signature)) {
      fw_log("info", input = "spatial feature cache",
             message = paste("Reusing cached features from", display_path(cache_file, project_dir)))
      return(list(
        features      = tibble::as_tibble(arrow::read_parquet(cache_file)),
        methods       = meta$methods,
        coverage      = meta$coverage,
        layer_summary = meta$layer_summary,
        from_cache    = TRUE,
        created       = meta$created
      ))
    }
    fw_log("info", input = "spatial feature cache",
           message = "Cached features exist but configuration or inputs changed; recomputing.")
  }

  started <- Sys.time()
  result <- build_spatial_features(events, inputs, settings, project_dir)
  arrow::write_parquet(result$features, cache_file)
  saveRDS(
    list(signature = signature, methods = result$methods, coverage = result$coverage,
         layer_summary = result$layer_summary, created = Sys.time()),
    meta_file
  )
  fw_log("info", input = "spatial features",
         message = sprintf("Computed features for %d events in %.1f minutes.",
                           nrow(result$features), as.numeric(difftime(Sys.time(), started, units = "mins"))))
  result$from_cache <- FALSE
  result$created <- Sys.time()
  result
}
