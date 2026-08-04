script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
interim_dir <- file.path(project_root, "data", "interim")
processed_dir <- file.path(project_root, "data", "processed")
database_path <- file.path(processed_dir, "lolkills.duckdb")
canonical <- readRDS(file.path(interim_dir, "canonical_games.rds"))
team_metrics <- readRDS(file.path(interim_dir, "team_map_metrics.rds"))
connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = database_path)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

reconcile_table <- function(table, data, parquet_name, key_columns) {
  before <- if (table %in% DBI::dbListTables(connection)) {
    DBI::dbGetQuery(
      connection,
      paste0(
        "SELECT COUNT(*) AS rows FROM ",
        DBI::dbQuoteIdentifier(connection, table)
      )
    )$rows[[1L]]
  } else {
    0
  }
  database_keys <- if (before > 0L) {
    DBI::dbReadTable(connection, table)[key_columns]
  } else {
    data.frame()
  }
  source_keys <- data[key_columns]
  key_value <- function(frame) {
    if (nrow(frame) == 0L) {
      return(character())
    }
    do.call(paste, c(frame, sep = "|"))
  }
  matches <- before == nrow(data) &&
    setequal(key_value(database_keys), key_value(source_keys))
  if (!matches) {
    DBI::dbWriteTable(
      connection,
      table,
      data,
      overwrite = TRUE
    )
  }
  parquet_path <- file.path(processed_dir, parquet_name)
  escaped_path <- gsub(
    "'",
    "''",
    normalizePath(parquet_path, winslash = "/", mustWork = FALSE),
    fixed = TRUE
  )
  temporary_path <- paste0(parquet_path, ".reconcile.tmp")
  escaped_temporary <- gsub(
    "'",
    "''",
    normalizePath(
      temporary_path,
      winslash = "/",
      mustWork = FALSE
    ),
    fixed = TRUE
  )
  if (file.exists(temporary_path)) {
    unlink(temporary_path)
  }
  DBI::dbExecute(
    connection,
    paste0(
      "COPY ",
      DBI::dbQuoteIdentifier(connection, table),
      " TO '",
      escaped_temporary,
      "' (FORMAT PARQUET)"
    )
  )
  if (file.exists(parquet_path)) {
    unlink(parquet_path)
  }
  if (!file.rename(temporary_path, parquet_path)) {
    stop("Falha ao substituir ", parquet_name, ".", call. = FALSE)
  }
  after <- DBI::dbGetQuery(
    connection,
    paste0(
      "SELECT COUNT(*) AS rows FROM ",
      DBI::dbQuoteIdentifier(connection, table)
    )
  )$rows[[1L]]
  parquet_rows <- DBI::dbGetQuery(
    connection,
    paste0("SELECT COUNT(*) AS rows FROM read_parquet('", escaped_path, "')")
  )$rows[[1L]]
  data.frame(
    table = table,
    rds_rows = nrow(data),
    database_rows_before = before,
    database_rows_after = after,
    parquet_rows_after = parquet_rows,
    keys_matched_before = matches,
    reconciled = !matches,
    stringsAsFactors = FALSE
  )
}

report <- rbind(
  reconcile_table(
    "canonical_games",
    canonical,
    "canonical_games.parquet",
    "gameid"
  ),
  reconcile_table(
    "team_map_metrics",
    team_metrics,
    "team_map_metrics.parquet",
    c("gameid", "side")
  )
)
artifact_dir <- file.path(project_root, "artifacts", "premap_model")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  report,
  file.path(artifact_dir, "processed_store_reconciliation.csv"),
  row.names = FALSE
)
print(report, row.names = FALSE)
