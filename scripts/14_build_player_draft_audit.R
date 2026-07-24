script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
project_config <- yaml::read_yaml(
  file.path(project_root, "config", "default.yml")
)
manifest <- read_data_manifest(file.path(
  project_root,
  project_config$paths$raw_manifest
))
raw_files <- file.path(
  project_root,
  project_config$paths$raw_oracles_elixir,
  manifest$file_name
)
games <- readRDS(file.path(
  project_root,
  project_config$paths$interim,
  "canonical_games.rds"
))
exclusions <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "game-exclusions.yml"
))
excluded_ids <- vapply(
  exclusions$exclusions,
  function(item) as.character(item$gameid),
  character(1L)
)

batches <- lapply(raw_files, function(path) {
  rows <- data.table::fread(
    path,
    select = player_metric_oe_columns(),
    showProgress = FALSE,
    encoding = "UTF-8",
    na.strings = c("", "NA")
  )
  result <- build_player_map_metrics(rows)
  result$source_file <- basename(path)
  result
})
player_metrics <- do.call(rbind, batches)
rownames(player_metrics) <- NULL
player_metrics <- player_metrics[
  !player_metrics$gameid %in% excluded_ids,
  ,
  drop = FALSE
]
game_match <- match(player_metrics$gameid, games$gameid)
if (anyNA(game_match)) {
  stop("Player rows could not be matched to canonical games.", call. = FALSE)
}
for (column in c(
  "series_id",
  "series_cutoff",
  "series_eligible",
  "target_valid"
)) {
  player_metrics[[column]] <- games[[column]][game_match]
}
output_path <- file.path(
  project_root,
  project_config$paths$interim,
  "player_map_metrics.rds"
)
saveRDS(player_metrics, output_path, version = 3L)

target <- player_metrics[
  player_metrics$competition_role == "target",
  ,
  drop = FALSE
]
target$missing_player_id <- is.na(target$player_id) |
  !nzchar(target$player_id)
target$missing_champion <- is.na(target$champion) |
  !nzchar(target$champion)
season_groups <- split(target, target$source_season)
season_summary <- do.call(rbind, lapply(
  season_groups,
  function(data) {
    data.frame(
      season = data$source_season[[1L]],
      maps = length(unique(data$gameid)),
      player_rows = nrow(data),
      players = length(unique(data$player_id)),
      champions = length(unique(data$champion)),
      missing_player_ids = sum(data$missing_player_id),
      missing_champions = sum(data$missing_champion),
      stringsAsFactors = FALSE
    )
  }
))
map_groups <- split(target, target$gameid)
map_audit <- do.call(rbind, lapply(map_groups, function(data) {
  data.frame(
    gameid = data$gameid[[1L]],
    season = data$source_season[[1L]],
    player_rows = nrow(data),
    unique_players = length(unique(data$player_id)),
    unique_champions = length(unique(data$champion)),
    canonical_positions = length(unique(data$position)),
    missing_required = any(
      data$missing_player_id | data$missing_champion
    ),
    stringsAsFactors = FALSE
  )
}))
all_champions <- sort(unique(target$champion))
champions_2026 <- sort(unique(
  target$champion[target$source_season == 2026L]
))
champion_coverage <- data.frame(
  champion = all_champions,
  observed_2026 = all_champions %in% champions_2026,
  observed_before_2026 = all_champions %in% unique(
    target$champion[target$source_season < 2026L]
  ),
  maps_all = vapply(
    all_champions,
    function(champion) sum(target$champion == champion),
    integer(1L)
  ),
  maps_2026 = vapply(
    all_champions,
    function(champion) sum(
      target$champion == champion &
        target$source_season == 2026L
    ),
    integer(1L)
  ),
  stringsAsFactors = FALSE
)
missing_player_ids <- target[
  target$missing_player_id,
  c(
    "gameid",
    "game_datetime",
    "league_canonical",
    "side",
    "position",
    "player_name",
    "team_name",
    "champion"
  ),
  drop = FALSE
]

artifact_dir <- file.path(
  project_root,
  project_config$paths$artifacts,
  "research"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
outputs <- list(
  player_draft_season_summary = season_summary,
  player_draft_map_audit = map_audit,
  champion_catalog_coverage = champion_coverage,
  player_missing_ids = missing_player_ids
)
for (name in names(outputs)) {
  utils::write.csv(
    outputs[[name]],
    file.path(artifact_dir, paste0(name, ".csv")),
    row.names = FALSE
  )
}

print(season_summary, row.names = FALSE)
cat("\nMapas com estrutura inválida:\n")
print(
  map_audit[
    map_audit$player_rows != 10L |
      map_audit$unique_players != 10L |
      map_audit$unique_champions != 10L |
      map_audit$canonical_positions != 5L,
    ,
    drop = FALSE
  ],
  row.names = FALSE
)
cat("\nCampeões históricos ausentes em 2026:\n")
print(
  champion_coverage$champion[
    !champion_coverage$observed_2026
  ]
)
