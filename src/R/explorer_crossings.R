# NCDOT bridges and culverts for the explorer's road-crossings tab.
# Writes data/derived/explorer/crossings.csv (one row per structure). Only fields NCDOT publishes are
# kept; nothing is modeled here. The explorer joins each crossing to its nearest grid cell.

build_explorer_crossings <- function(project_dir = ".", out_dir = "data/derived/explorer", force = FALSE) {
  suppressPackageStartupMessages(library(sf))
  project_dir <- normalizePath(project_dir, mustWork = TRUE)
  if (!grepl("^(/|[A-Za-z]:)", out_dir)) out_dir <- file.path(project_dir, out_dir)
  f_out <- file.path(out_dir, "crossings.csv")
  srcs <- file.path(project_dir, "data", "raw", "ncdot", c("ncdot_structures_nc.gpkg", "ncdot_culverts_nc.gpkg"))
  if (!force && file.exists(f_out) && file.mtime(f_out) > max(file.mtime(srcs))) return(invisible(f_out))
  read_one <- function(f, kind) {
    d <- sf::st_drop_geometry(sf::st_read(f, quiet = TRUE))
    data.frame(kind = kind, structure_no = as.character(d$BRDG_NBR), crosses = trimws(as.character(d$FTR_INTRSC)),
               road = trimws(as.character(d$F_CARRIED)), county = tools::toTitleCase(tolower(as.character(d$COUNTY))),
               func_class = trimws(as.character(d$FUNC_CLASS)),
               aadt = suppressWarnings(as.numeric(d$AADT)), detour = suppressWarnings(as.numeric(d$DETOUR_LEN)),
               lon = d$LONG_DD, lat = d$LAT_DD, stringsAsFactors = FALSE)
  }
  out <- rbind(read_one(srcs[1], "Bridge"), read_one(srcs[2], "Culvert"))
  out <- out[is.finite(out$lon) & is.finite(out$lat), ]
  out$crosses <- gsub("[^ -~]", "", out$crosses); out$road <- gsub("[^ -~]", "", out$road)
  utils::write.csv(out, f_out, row.names = FALSE, na = "")
  invisible(f_out)
}
