#' Compute a file SHA-256 hash
#'
#' @param path Path to an existing file.
#' @return A lowercase SHA-256 hash.
#' @export
compute_file_sha256 <- function(path) {
  if (length(path) != 1L || is.na(path) || !file.exists(path)) {
    stop("File does not exist: ", path, call. = FALSE)
  }

  tolower(digest::digest(file = path, algo = "sha256"))
}

#' Build a manifest for local Oracle's Elixir files
#'
#' @param raw_dir Directory containing the seasonal CSV files.
#' @return A data frame with immutable file metadata.
#' @export
build_data_manifest <- function(raw_dir) {
  if (length(raw_dir) != 1L || is.na(raw_dir) || !dir.exists(raw_dir)) {
    stop("Raw data directory does not exist: ", raw_dir, call. = FALSE)
  }

  pattern <- paste0(
    "^20[0-9]{2}_LoL_esports_match_data_",
    "from_OraclesElixir\\.csv$"
  )
  paths <- list.files(
    raw_dir,
    pattern = pattern,
    full.names = TRUE,
    recursive = FALSE
  )
  paths <- sort(paths)

  if (length(paths) == 0L) {
    stop("No Oracle's Elixir seasonal CSV files found.", call. = FALSE)
  }

  file_names <- basename(paths)
  seasons <- as.integer(substr(file_names, 1L, 4L))
  info <- file.info(paths)

  manifest <- data.frame(
    source_name = rep("Oracle's Elixir", length(paths)),
    season = seasons,
    file_name = file_names,
    sha256 = vapply(paths, compute_file_sha256, character(1L)),
    size_bytes = as.numeric(info$size),
    received_at = format(
      info$mtime,
      tz = "UTC",
      format = "%Y-%m-%dT%H:%M:%SZ"
    ),
    schema_version = rep("pending-audit", length(paths)),
    ingestion_status = rep("registered", length(paths)),
    stringsAsFactors = FALSE
  )

  manifest <- manifest[order(manifest$season), , drop = FALSE]
  rownames(manifest) <- NULL
  manifest
}

#' Validate an Oracle's Elixir data manifest
#'
#' @param manifest Manifest data frame.
#' @param raw_dir Directory containing the files.
#' @return `TRUE` invisibly when valid.
#' @export
validate_data_manifest <- function(manifest, raw_dir) {
  required <- c(
    "source_name",
    "season",
    "file_name",
    "sha256",
    "size_bytes",
    "received_at",
    "schema_version",
    "ingestion_status"
  )
  missing <- setdiff(required, names(manifest))
  if (length(missing) > 0L) {
    stop(
      "Missing manifest columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  if (anyDuplicated(manifest$season)) {
    stop("Duplicate season in data manifest.", call. = FALSE)
  }
  if (anyDuplicated(manifest$file_name)) {
    stop("Duplicate file name in data manifest.", call. = FALSE)
  }
  if (any(grepl("^[A-Za-z]:|^[/\\\\]", manifest$file_name))) {
    stop("Manifest file_name must be relative.", call. = FALSE)
  }
  if (any(!grepl("^[a-f0-9]{64}$", manifest$sha256))) {
    stop("Invalid SHA-256 value in data manifest.", call. = FALSE)
  }

  paths <- file.path(raw_dir, manifest$file_name)
  missing_files <- manifest$file_name[!file.exists(paths)]
  if (length(missing_files) > 0L) {
    stop(
      "Manifest file does not exist: ",
      paste(missing_files, collapse = ", "),
      call. = FALSE
    )
  }

  current_hashes <- vapply(paths, compute_file_sha256, character(1L))
  changed <- manifest$file_name[current_hashes != manifest$sha256]
  if (length(changed) > 0L) {
    stop(
      "SHA-256 mismatch for: ",
      paste(changed, collapse = ", "),
      call. = FALSE
    )
  }

  invisible(TRUE)
}

#' Write a data manifest as YAML
#'
#' @param manifest Valid manifest data frame.
#' @param path Destination YAML path.
#' @return Destination path invisibly.
#' @export
write_data_manifest <- function(manifest, path) {
  if (!is.data.frame(manifest) || nrow(manifest) == 0L) {
    stop("Manifest must be a non-empty data frame.", call. = FALSE)
  }
  parent <- dirname(path)
  if (!dir.exists(parent)) {
    dir.create(parent, recursive = TRUE)
  }

  records <- lapply(seq_len(nrow(manifest)), function(index) {
    as.list(manifest[index, , drop = FALSE])
  })
  yaml::write_yaml(
    list(version = 1L, files = records),
    file = path
  )
  invisible(path)
}

#' Read a YAML data manifest
#'
#' @param path Path to a manifest written by `write_data_manifest()`.
#' @return Manifest data frame.
#' @export
read_data_manifest <- function(path) {
  if (length(path) != 1L || is.na(path) || !file.exists(path)) {
    stop("Manifest file does not exist: ", path, call. = FALSE)
  }

  document <- yaml::read_yaml(path)
  if (
    is.null(document$version) ||
    !identical(as.integer(document$version), 1L) ||
    is.null(document$files) ||
    length(document$files) == 0L
  ) {
    stop("Unsupported or empty data manifest.", call. = FALSE)
  }

  rows <- lapply(document$files, function(record) {
    as.data.frame(record, stringsAsFactors = FALSE)
  })
  manifest <- do.call(rbind, rows)
  rownames(manifest) <- NULL
  manifest$season <- as.integer(manifest$season)
  manifest$size_bytes <- as.numeric(manifest$size_bytes)

  character_columns <- setdiff(
    names(manifest),
    c("season", "size_bytes")
  )
  manifest[character_columns] <- lapply(
    manifest[character_columns],
    as.character
  )
  manifest
}
