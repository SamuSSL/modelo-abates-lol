script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
provider_config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool.yml"
))
evaluation_config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation_config$directed_moneyline_joint_round
aliases <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool-team-aliases.yml"
))
database_path <- file.path(
  project_root,
  "data",
  "processed",
  "lolkills.duckdb"
)
connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = database_path)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
initialize_bettingiscool_store(connection)

fixtures <- DBI::dbReadTable(connection, "market_fixtures")
snapshots <- DBI::dbReadTable(
  connection,
  "market_moneyline_snapshots"
)
maps <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_t15.rds"
))
regular_fixtures <- fixtures[
  tolower(as.character(fixtures$resulting_unit)) == "regular",
  ,
  drop = FALSE
]
selected <- select_bettingiscool_moneyline_snapshots(
  snapshots,
  minimum_minutes = as.numeric(round_config$prediction_lead_minutes),
  maximum_minutes = as.numeric(
    round_config$maximum_snapshot_age_minutes
  )
)
links <- match_bettingiscool_regular_maps(
  regular_fixtures,
  selected,
  maps,
  provider_config$canonical_competitions,
  aliases = aliases
)
if (nrow(links) > 0L) {
  append_bettingiscool_rows(
    connection,
    "game_moneyline_links",
    links,
    "link_id"
  )
}
moneyline_maps <- attach_direct_moneyline_to_maps(
  maps,
  links,
  regular_fixtures,
  selected,
  aliases
)

interim_path <- file.path(
  project_root,
  "data",
  "interim",
  "premap_direct_moneyline_map_features.rds"
)
saveRDS(moneyline_maps, interim_path, version = 3L)
artifact_dir <- file.path(project_root, "artifacts", "premap_model")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

link_coverage <- stats::aggregate(
  rep(1L, nrow(links)),
  links[c("league_canonical", "link_status")],
  sum
)
names(link_coverage)[[3L]] <- "maps"
utils::write.csv(
  link_coverage,
  file.path(
    artifact_dir,
    "direct_moneyline_link_coverage.csv"
  ),
  row.names = FALSE
)

moneyline_maps$calendar_year <- format(
  moneyline_maps$game_datetime,
  "%Y",
  tz = "UTC"
)
map_coverage <- stats::aggregate(
  rep(1L, nrow(moneyline_maps)),
  moneyline_maps[c(
    "calendar_year",
    "league_canonical",
    "favorite_band"
  )],
  sum
)
names(map_coverage)[[4L]] <- "maps"
utils::write.csv(
  map_coverage,
  file.path(
    artifact_dir,
    "direct_moneyline_map_coverage.csv"
  ),
  row.names = FALSE
)

guardrails <- summarize_favoritism_coverage(
  moneyline_maps,
  minimum_total = as.integer(
    round_config$favoritism_minimum_aggregate_maps
  ),
  minimum_league = as.integer(
    round_config$favoritism_minimum_league_maps
  )
)
utils::write.csv(
  guardrails,
  file.path(
    artifact_dir,
    "direct_moneyline_favoritism_guardrails.csv"
  ),
  row.names = FALSE
)

timing_audit <- data.frame(
  raw_snapshots = nrow(snapshots),
  selected_event_periods = nrow(selected),
  direct_links = nrow(links),
  verified_links = sum(links$link_status == "verified"),
  point_in_time_maps = nrow(moneyline_maps),
  post_cutoff_snapshots = sum(
    moneyline_maps$odds_timestamp >
      moneyline_maps$prediction_cutoff
  ),
  median_snapshot_minutes_before_close = stats::median(
    moneyline_maps$snapshot_minutes_before_close,
    na.rm = TRUE
  ),
  min_prediction_cutoff_minus_snapshot_minutes = min(
    as.numeric(difftime(
      moneyline_maps$prediction_cutoff,
      moneyline_maps$odds_timestamp,
      units = "mins"
    )),
    na.rm = TRUE
  ),
  stringsAsFactors = FALSE
)
utils::write.csv(
  timing_audit,
  file.path(
    artifact_dir,
    "direct_moneyline_timing_audit.csv"
  ),
  row.names = FALSE
)
print(timing_audit, row.names = FALSE)
print(link_coverage, row.names = FALSE)
