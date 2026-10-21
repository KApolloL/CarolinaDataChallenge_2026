# Real raster values for the risk explorer's map grid.
#
# build_explorer_grid(grid_lonlat_csv, out_csv) reads a CSV with columns
# i, j, lat, lon (WGS84), samples the project rasters at each point, and
# writes i, j, lat, lon, elevation_m_real, slope_degrees_real, impervious_real,
# local_relief_5km. Points outside North Carolina stay NA. Raw data is only read.
#
#   Rscript -e 'source("src/R/explorer_grid.R"); build_explorer_grid("grid.csv", "data/derived/explorer_grid.csv")'

build_explorer_grid <- function(grid_lonlat_csv, out_csv, project_dir = ".",
                                nlcd_year = 2023, relief_radius_m = 5000) {
  stopifnot(requireNamespace("terra", quietly = TRUE), requireNamespace("sf", quietly = TRUE))
  p <- function(...) file.path(project_dir, ...)
  grid <- read.csv(grid_lonlat_csv)
  stopifnot(all(c("i", "j", "lat", "lon") %in% names(grid)))

  dem   <- terra::rast(p("data/raw/dem_3dep/3dep_dem_north_carolina_epsg32119.tif"))
  slope <- terra::rast(p("data/raw/dem_3dep/slope_degrees_epsg32119.tif"))
  imp   <- terra::rast(p("data/raw/nlcd", sprintf("annual_nlcd_fractional_impervious_%d_NC.tif", nlcd_year)))

  pts_ll <- terra::vect(grid[, c("lon", "lat")], geom = c("lon", "lat"), crs = "EPSG:4326")
  pts_dem <- terra::project(pts_ll, terra::crs(dem))
  pts_imp <- terra::project(pts_ll, terra::crs(imp))

  elev  <- terra::extract(dem, pts_dem, ID = FALSE)[[1]]
  slp   <- terra::extract(slope, pts_dem, ID = FALSE)[[1]]
  imperv <- terra::extract(imp, pts_imp, ID = FALSE)[[1]]
  imperv[!is.na(imperv) & imperv > 100] <- NA_real_   # NLCD fill values

  # 5 km local relief: max minus min DEM elevation inside a 5,000 m buffer
  # (same definition as the report's relief-5km chunk)
  buffers <- terra::buffer(pts_dem, width = relief_radius_m)
  hi <- terra::extract(dem, buffers, fun = max, na.rm = TRUE, ID = FALSE)[[1]]
  lo <- terra::extract(dem, buffers, fun = min, na.rm = TRUE, ID = FALSE)[[1]]
  relief <- hi - lo
  relief[!is.finite(relief)] <- NA_real_

  # keep nulls outside NC: mask point-level values by the NC boundary
  nc <- sf::st_read(p("data/raw/nlcd/north_carolina_boundary.gpkg"), quiet = TRUE)
  nc <- sf::st_transform(sf::st_make_valid(nc), 4326)
  inside <- lengths(sf::st_intersects(sf::st_as_sf(grid, coords = c("lon", "lat"), crs = 4326, remove = FALSE),
                                      sf::st_union(nc))) > 0
  elev[!inside] <- NA_real_; slp[!inside] <- NA_real_; imperv[!inside] <- NA_real_
  relief[!inside] <- NA_real_

  out <- data.frame(i = grid$i, j = grid$j, lat = grid$lat, lon = grid$lon,
                    elevation_m_real = elev, slope_degrees_real = slp,
                    impervious_real = imperv, local_relief_5km = relief)
  dir.create(dirname(out_csv), showWarnings = FALSE, recursive = TRUE)
  write.csv(out, out_csv, row.names = FALSE, na = "")
  message(sprintf("Wrote %d cells to %s (non-NA: elev %d, slope %d, imperv %d, relief %d; inside NC %d)",
                  nrow(out), out_csv, sum(!is.na(elev)), sum(!is.na(slp)), sum(!is.na(imperv)),
                  sum(!is.na(relief)), sum(inside)))
  invisible(out)
}
