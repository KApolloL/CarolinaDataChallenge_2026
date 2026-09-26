# ============================================================
# Blue Ridge FloodWatch — shared helpers
# ============================================================
#
# Sourced by analysis.qmd and by the other scripts in scripts/.
# Contains path handling, package checks, input validation,
# a run log for warnings/fallbacks, and geometry cleaning.
# No function in this file downloads or modifies raw data.

# ------------------------------------------------------------
# Run log
# ------------------------------------------------------------
# Every missing input, disabled section, and fallback is recorded
# here so the rendered report can show a single, complete table.

fw_log_env <- new.env(parent = emptyenv())

fw_log_reset <- function() {
  fw_log_env$entries <- data.frame(
    level    = character(),
    input    = character(),
    message  = character(),
    affects  = character(),
    stringsAsFactors = FALSE
  )
  invisible(NULL)
}

fw_log_reset()

fw_log <- function(level = c("info", "warning", "error"),
                   input,
                   message,
                   affects = NA_character_) {
  level <- match.arg(level)
  fw_log_env$entries <- rbind(
    fw_log_env$entries,
    data.frame(
      level   = level,
      input   = input,
      message = message,
      affects = affects,
      stringsAsFactors = FALSE
    )
  )
  text <- sprintf("[%s] %s", input, message)
  if (level == "warning") warning(text, call. = FALSE)
  if (level == "info") message(text)
  invisible(NULL)
}

fw_log_table <- function() {
  tibble::as_tibble(fw_log_env$entries)
}

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

is_blank <- function(x) {
  is.null(x) || length(x) == 0 || all(is.na(x)) || identical(trimws(as.character(x)), "")
}

# Resolve a path relative to project_dir unless it is already absolute.
resolve_path <- function(path, project_dir) {
  if (is_blank(path)) {
    return(NA_character_)
  }
  path <- path.expand(as.character(path))
  if (fs::is_absolute_path(path)) {
    path
  } else {
    file.path(project_dir, path)
  }
}

# Path relative to a base directory, for display in the report.
display_path <- function(path, project_dir) {
  out <- rep(NA_character_, length(path))
  ok <- !is.na(path)
  out[ok] <- as.character(fs::path_rel(path[ok], start = project_dir))
  out
}

# ------------------------------------------------------------
# Packages
# ------------------------------------------------------------

# Load required packages (stop if any are missing) and report which
# optional packages are available (warn, never stop).
load_packages <- function(required, optional = character()) {
  missing_required <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing_required) > 0) {
    stop(
      "Required R packages are not installed: ",
      paste(missing_required, collapse = ", "),
      "\nInstall them with install.packages(c(",
      paste0('"', missing_required, '"', collapse = ", "),
      "))",
      call. = FALSE
    )
  }
  suppressPackageStartupMessages(
    invisible(lapply(required, library, character.only = TRUE))
  )

  optional_available <- vapply(optional, requireNamespace, logical(1), quietly = TRUE)
  for (pkg in optional[!optional_available]) {
    fw_log(
      "warning",
      input   = paste0("R package '", pkg, "'"),
      message = "Optional package not installed; sections that need it are skipped.",
      affects = pkg
    )
  }
  optional_available
}

# ------------------------------------------------------------
# Input validation
# ------------------------------------------------------------

# Check whether an input exists. Required inputs stop the render with
# instructions; optional inputs are logged and the caller decides what
# to skip.
check_input <- function(path,
                        label,
                        required = FALSE,
                        how_to_obtain = NA_character_,
                        affects = NA_character_,
                        project_dir = NULL) {
  exists <- !is.na(path) && file.exists(path)
  if (exists) {
    return(TRUE)
  }

  shown <- if (is.null(project_dir) || is.na(path)) path else display_path(path, project_dir)
  text <- paste0(
    if (required) "REQUIRED" else "Optional",
    " input missing. Expected at: ", shown, ".",
    if (!is.na(how_to_obtain)) paste0(" To obtain it: ", how_to_obtain) else ""
  )

  if (required) {
    fw_log("error", input = label, message = text, affects = affects)
    stop(paste0("[", label, "] ", text, " Affects: ", affects), call. = FALSE)
  }

  fw_log("warning", input = label, message = paste0(text, " Skipped: ", affects), affects = affects)
  FALSE
}

# One row of file metadata for the input inventory table.
file_inventory_row <- function(path, dataset, required, used_for, project_dir) {
  exists <- !is.na(path) && file.exists(path)
  is_dir <- exists && dir.exists(path)
  size <- if (!exists) {
    NA_real_
  } else if (is_dir) {
    sum(file.info(list.files(path, recursive = TRUE, full.names = TRUE))$size, na.rm = TRUE)
  } else {
    file.info(path)$size
  }
  tibble::tibble(
    dataset   = dataset,
    path      = display_path(path, project_dir),
    required  = required,
    status    = if (exists) "found" else "missing",
    size_mb   = round(size / 1024^2, 1),
    modified  = if (exists) format(file.info(path)$mtime, "%Y-%m-%d") else NA_character_,
    used_for  = used_for
  )
}

# Signature of a set of files (path, size, mtime). Used to decide
# whether cached derived tables are still valid.
file_signature <- function(paths) {
  paths <- paths[!is.na(paths) & file.exists(paths)]
  info <- file.info(paths)
  paste(basename(paths), info$size, format(info$mtime, "%Y%m%d%H%M%S"), collapse = "|")
}

# ------------------------------------------------------------
# Geometry
# ------------------------------------------------------------

# Drop Z/M dimensions, repair invalid geometries, and project.
# GEOS cannot operate on XYM/XYZM geometries (e.g. NHD flowlines).
clean_spatial_layer <- function(x, target_crs) {
  x |>
    sf::st_zm(drop = TRUE, what = "ZM") |>
    sf::st_make_valid() |>
    sf::st_transform(target_crs)
}

# Column-name suffix for a buffer distance: 250 -> "250m", 1000 -> "1km".
buffer_label <- function(meters) {
  meters <- as.numeric(meters)
  ifelse(
    meters %% 1000 == 0,
    paste0(meters / 1000, "km"),
    paste0(meters, "m")
  )
}

# ------------------------------------------------------------
# Small data helpers
# ------------------------------------------------------------

# First non-missing, non-blank value in a vector. Returns an NA of the
# same type (and class, e.g. POSIXct) when nothing is available.
first_nonmissing <- function(x) {
  valid <- x[!is.na(x)]
  if (is.character(valid)) {
    valid <- valid[trimws(valid) != ""]
  }
  if (length(valid) == 0) {
    return(x[NA_integer_][1])
  }
  valid[1]
}

# Maximum that returns NA (not -Inf) when every value is missing.
max_or_na <- function(x) {
  x <- suppressWarnings(as.numeric(x))
  if (all(is.na(x))) {
    return(NA_real_)
  }
  max(x, na.rm = TRUE)
}

format_dollars <- function(x) {
  dplyr::case_when(
    is.na(x) ~ NA_character_,
    x >= 1e9 ~ paste0("$", round(x / 1e9, 2), "B"),
    x >= 1e6 ~ paste0("$", round(x / 1e6, 1), "M"),
    x >= 1e3 ~ paste0("$", round(x / 1e3, 0), "K"),
    TRUE     ~ paste0("$", round(x, 0))
  )
}
