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
exclusions <- do.call(
  rbind,
  lapply(exclusion_config$exclusions, function(exclusion) {
    data.frame(
      gameid = as.character(exclusion$gameid),
      reason_code = as.character(exclusion$reason_code),
      rationale = as.character(exclusion$rationale),
      reviewed_at = as.character(exclusion$reviewed_at),
      stringsAsFactors = FALSE
    )
  })
)

raw_dir <- file.path(
  project_root,
  config$paths$raw_oracles_elixir
)
manifest_path <- file.path(
  project_root,
  config$paths$raw_manifest
)
interim_dir <- file.path(project_root, config$paths$interim)
artifact_dir <- file.path(project_root, config$paths$artifacts)
dir.create(interim_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

manifest <- read_data_manifest(manifest_path)
validate_data_manifest(manifest, raw_dir)

game_batches <- vector("list", nrow(manifest))
quality_batches <- vector("list", nrow(manifest))

for (index in seq_len(nrow(manifest))) {
  file_name <- manifest$file_name[[index]]
  source_path <- file.path(raw_dir, file_name)
  message("Construindo mapas canônicos de: ", file_name)

  rows <- data.table::fread(
    source_path,
    select = required_oe_columns(),
    showProgress = FALSE,
    encoding = "UTF-8",
    na.strings = c("", "NA")
  )
  result <- build_canonical_games(rows)
  result$games$source_file <- file_name
  result$games$source_season <- manifest$season[[index]]
  result$quality_events$source_file <- file_name
  result$quality_events$source_season <- manifest$season[[index]]
  game_batches[[index]] <- result$games
  quality_batches[[index]] <- result$quality_events
}

games <- do.call(rbind, game_batches)
rownames(games) <- NULL
quality_events <- do.call(rbind, quality_batches)
rownames(quality_events) <- NULL

duplicated_gameids <- unique(games$gameid[duplicated(games$gameid)])
if (length(duplicated_gameids) > 0L) {
  stop(
    "Game IDs duplicados entre arquivos: ",
    paste(head(duplicated_gameids, 20L), collapse = ", "),
    call. = FALSE
  )
}

exclusion_result <- apply_game_exclusions(
  games,
  quality_events,
  exclusions
)
games <- derive_series_metadata(exclusion_result$games)
quality_events <- exclusion_result$quality_events
excluded_games <- exclusion_result$excluded_games
saveRDS(
  games,
  file.path(interim_dir, "canonical_games.rds"),
  version = 3L
)
saveRDS(
  excluded_games,
  file.path(interim_dir, "excluded_games.rds"),
  version = 3L
)
saveRDS(
  quality_events,
  file.path(interim_dir, "game_quality_events.rds"),
  version = 3L
)

summary <- data.frame(
  metric = c(
    "canonical_games",
    "target_games",
    "auxiliary_games",
    "valid_targets",
    "invalid_targets",
    "eligible_series_games",
    "ambiguous_series_games",
    "quality_events",
    "excluded_games"
  ),
  value = c(
    nrow(games),
    sum(games$competition_role == "target"),
    sum(games$competition_role == "auxiliary"),
    sum(games$target_valid),
    sum(!games$target_valid),
    sum(games$series_eligible),
    sum(!games$series_eligible),
    nrow(quality_events),
    nrow(excluded_games)
  ),
  stringsAsFactors = FALSE
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "canonical_games_summary.csv"),
  row.names = FALSE
)

league_summary <- aggregate(
  list(
    games = rep(1L, nrow(games)),
    valid_targets = as.integer(games$target_valid),
    series_eligible = as.integer(games$series_eligible)
  ),
  by = list(
    source_season = games$source_season,
    league = games$league_canonical,
    role = games$competition_role
  ),
  FUN = sum
)
utils::write.csv(
  league_summary,
  file.path(artifact_dir, "canonical_games_by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  excluded_games,
  file.path(artifact_dir, "excluded_games.csv"),
  row.names = FALSE
)

print(summary, row.names = FALSE)
