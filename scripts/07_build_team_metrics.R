script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(
  file.path(project_root, "config", "default.yml")
)
exclusion_config <- yaml::read_yaml(
  file.path(project_root, "config", "game-exclusions.yml")
)
excluded_ids <- vapply(
  exclusion_config$exclusions,
  function(exclusion) as.character(exclusion$gameid),
  character(1L)
)

raw_dir <- file.path(
  project_root,
  config$paths$raw_oracles_elixir
)
manifest <- read_data_manifest(
  file.path(project_root, config$paths$raw_manifest)
)
validate_data_manifest(manifest, raw_dir)
batches <- vector("list", nrow(manifest))

for (index in seq_len(nrow(manifest))) {
  file_name <- manifest$file_name[[index]]
  message("Construindo métricas de equipe: ", file_name)
  rows <- data.table::fread(
    file.path(raw_dir, file_name),
    select = team_metric_oe_columns(),
    showProgress = FALSE,
    encoding = "UTF-8",
    na.strings = c("", "NA")
  )
  rows <- rows[
    tolower(as.character(rows$position)) == "team",
    ,
    drop = FALSE
  ]
  batch <- build_team_map_metrics(rows)
  batch$source_file <- file_name
  batches[[index]] <- batch
}

team_metrics <- do.call(rbind, batches)
rownames(team_metrics) <- NULL
team_metrics <- team_metrics[
  !team_metrics$gameid %in% excluded_ids,
  ,
  drop = FALSE
]
canonical_games <- readRDS(
  file.path(
    project_root,
    config$paths$interim,
    "canonical_games.rds"
  )
)
canonical_match <- match(team_metrics$gameid, canonical_games$gameid)
if (anyNA(canonical_match)) {
  stop("Team metrics contain games absent from canonical games.", call. = FALSE)
}
team_metrics$series_id <- canonical_games$series_id[canonical_match]
team_metrics$series_cutoff <- canonical_games$series_cutoff[canonical_match]
duplicate_keys <- duplicated(
  paste(team_metrics$gameid, team_metrics$side, sep = "|")
)
if (any(duplicate_keys)) {
  stop("Duplicated game-team rows in team metrics.", call. = FALSE)
}

interim_dir <- file.path(project_root, config$paths$interim)
processed_dir <- file.path(project_root, config$paths$processed)
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "research"
)
dir.create(interim_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(processed_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(
  team_metrics,
  file.path(interim_dir, "team_map_metrics.rds"),
  version = 3L
)

database_path <- file.path(processed_dir, "lolkills.duckdb")
parquet_path <- file.path(processed_dir, "team_map_metrics.parquet")
if (file.exists(parquet_path)) {
  unlink(parquet_path)
}
connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = database_path
)
DBI::dbWriteTable(
  connection,
  "team_map_metrics",
  team_metrics,
  overwrite = TRUE
)
escaped_path <- gsub(
  "'",
  "''",
  normalizePath(parquet_path, winslash = "/", mustWork = FALSE),
  fixed = TRUE
)
DBI::dbExecute(
  connection,
  paste0(
    "COPY team_map_metrics TO '",
    escaped_path,
    "' (FORMAT PARQUET)"
  )
)
DBI::dbDisconnect(connection, shutdown = TRUE)

summary <- aggregate(
  rep(1L, nrow(team_metrics)),
  by = list(
    source_season = team_metrics$source_season,
    league_canonical = team_metrics$league_canonical,
    competition_role = team_metrics$competition_role
  ),
  FUN = sum
)
names(summary)[[4L]] <- "team_map_rows"
utils::write.csv(
  summary,
  file.path(artifact_dir, "team_metric_coverage.csv"),
  row.names = FALSE
)
cat(
  "team_map_rows=", nrow(team_metrics),
  " games=", length(unique(team_metrics$gameid)),
  "\n",
  sep = ""
)
