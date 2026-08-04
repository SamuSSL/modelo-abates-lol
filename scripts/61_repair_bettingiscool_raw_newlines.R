raw_root <- file.path("data", "raw", "bettingiscool")
metadata_paths <- list.files(
  raw_root,
  pattern = "\\.meta\\.json$",
  recursive = TRUE,
  full.names = TRUE
)
metadata <- lapply(metadata_paths, function(path) {
  jsonlite::read_json(path, simplifyVector = TRUE)
})
pairs <- unique(data.frame(
  directory = dirname(metadata_paths),
  sha256 = vapply(metadata, `[[`, character(1L), "sha256"),
  stringsAsFactors = FALSE
))
repaired <- 0L
for (index in seq_len(nrow(pairs))) {
  path <- file.path(
    pairs$directory[[index]],
    paste0(pairs$sha256[[index]], ".json")
  )
  if (
    file.exists(path) &&
      !identical(
        digest::digest(file = path, algo = "sha256"),
        pairs$sha256[[index]]
      )
  ) {
    bytes <- readBin(path, what = "raw", n = file.info(path)$size)
    while (length(bytes) > 0L && utils::tail(bytes, 1L) %in% as.raw(c(10, 13))) {
      bytes <- utils::head(bytes, -1L)
    }
    candidate <- digest::digest(bytes, algo = "sha256", serialize = FALSE)
    if (identical(candidate, pairs$sha256[[index]])) {
      connection <- file(path, open = "wb")
      writeBin(bytes, connection)
      close(connection)
      repaired <- repaired + 1L
    }
  }
}
cat("Raw bodies repaired:", repaired, "\n")
