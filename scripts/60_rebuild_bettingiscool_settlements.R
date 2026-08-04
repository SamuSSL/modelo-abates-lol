script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
raw_dir <- file.path(
  project_root, "data", "raw", "bettingiscool", "api_results"
)
database_path <- file.path(
  project_root, "data", "processed", "lolkills.duckdb"
)
metadata_paths <- list.files(
  raw_dir,
  pattern = "\\.meta\\.json$",
  full.names = TRUE
)
batches <- lapply(metadata_paths, function(metadata_path) {
  metadata <- jsonlite::read_json(metadata_path, simplifyVector = TRUE)
  data <- jsonlite::fromJSON(
    file.path(raw_dir, paste0(metadata$sha256, ".json")),
    simplifyVector = TRUE
  )
  normalize_bettingiscool_settlements(
    data,
    metadata$retrieved_at,
    metadata$sha256
  )
})
rows <- do.call(rbind, batches)
rows <- rows[!duplicated(rows$settlement_id), , drop = FALSE]
connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = database_path)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
initialize_bettingiscool_store(connection)
DBI::dbExecute(connection, "DELETE FROM market_settlements")
append_bettingiscool_rows(
  connection,
  "market_settlements",
  rows,
  "settlement_id"
)
print(table(rows$result_status, useNA = "always"))
