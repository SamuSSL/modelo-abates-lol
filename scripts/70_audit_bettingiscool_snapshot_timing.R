script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
database_path <- file.path(
  project_root,
  "data",
  "processed",
  "lolkills.duckdb"
)
connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = database_path,
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

snapshots <- DBI::dbReadTable(connection, "market_odds_snapshots")
links <- DBI::dbReadTable(connection, "game_market_links")
maps <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_t15.rds"
))
snapshots$odds_timestamp <- .bettingiscool_utc(
  snapshots$odds_timestamp
)
snapshots$market_cutoff <- .bettingiscool_utc(
  snapshots$market_cutoff
)
snapshots$lead_to_explicit_cutoff <- as.numeric(difftime(
  snapshots$market_cutoff,
  snapshots$odds_timestamp,
  units = "mins"
))

event_period <- paste(
  snapshots$event_id,
  snapshots$period,
  sep = "|"
)
groups <- split(seq_len(nrow(snapshots)), event_period)
group_rows <- lapply(groups, function(index) {
  rows <- snapshots[index, , drop = FALSE]
  valid_cutoff <- rows$market_cutoff[!is.na(rows$market_cutoff)]
  explicit_cutoff <- if (length(valid_cutoff) > 0L) {
    max(valid_cutoff)
  } else {
    as.POSIXct(NA, tz = "UTC")
  }
  final_history_timestamp <- max(rows$odds_timestamp, na.rm = TRUE)
  lead <- as.numeric(difftime(
    explicit_cutoff,
    rows$odds_timestamp,
    units = "mins"
  ))
  eligible <- is.finite(lead) &
    lead >= 15 &
    lead <= 30 &
    (is.na(rows$market_status) |
      !rows$market_status %in% c(2L, 3L))
  data.frame(
    event_id = as.character(rows$event_id[[1L]]),
    period = as.integer(rows$period[[1L]]),
    snapshots = nrow(rows),
    explicit_cutoff = explicit_cutoff,
    final_history_timestamp = final_history_timestamp,
    cutoff_minus_final_history_minutes = as.numeric(difftime(
      explicit_cutoff,
      final_history_timestamp,
      units = "mins"
    )),
    eligible_t15_t30 = sum(eligible),
    stringsAsFactors = FALSE
  )
})
group_audit <- do.call(rbind, group_rows)

verified_links <- links[
  links$link_status == "verified",
  c("gameid", "event_id", "period"),
  drop = FALSE
]
linked <- merge(
  verified_links,
  group_audit,
  by = c("event_id", "period")
)
linked <- merge(
  linked,
  maps[c(
    "gameid",
    "game_datetime",
    "prediction_cutoff",
    "league_canonical",
    "map_number"
  )],
  by = "gameid"
)
linked$cutoff_minus_game_datetime_minutes <- as.numeric(difftime(
  linked$explicit_cutoff,
  linked$game_datetime,
  units = "mins"
))
linked$final_history_minus_game_datetime_minutes <- as.numeric(difftime(
  linked$final_history_timestamp,
  linked$game_datetime,
  units = "mins"
))

quantile_or_na <- function(value, probability) {
  value <- value[is.finite(value)]
  if (length(value) == 0L) {
    return(NA_real_)
  }
  stats::quantile(value, probability, names = FALSE)
}
summary <- data.frame(
  snapshots = nrow(snapshots),
  event_periods = nrow(group_audit),
  snapshots_with_explicit_cutoff = sum(!is.na(snapshots$market_cutoff)),
  event_periods_with_explicit_cutoff = sum(
    !is.na(group_audit$explicit_cutoff)
  ),
  event_periods_with_t15_t30 = sum(group_audit$eligible_t15_t30 > 0),
  verified_linked_event_periods = nrow(linked),
  linked_event_periods_with_t15_t30 = sum(linked$eligible_t15_t30 > 0),
  median_cutoff_minus_final_history_minutes = stats::median(
    group_audit$cutoff_minus_final_history_minutes,
    na.rm = TRUE
  ),
  q05_cutoff_minus_game_datetime_minutes = quantile_or_na(
    linked$cutoff_minus_game_datetime_minutes,
    0.05
  ),
  median_cutoff_minus_game_datetime_minutes = stats::median(
    linked$cutoff_minus_game_datetime_minutes,
    na.rm = TRUE
  ),
  q95_cutoff_minus_game_datetime_minutes = quantile_or_na(
    linked$cutoff_minus_game_datetime_minutes,
    0.95
  ),
  median_final_history_minus_game_datetime_minutes = stats::median(
    linked$final_history_minus_game_datetime_minutes,
    na.rm = TRUE
  ),
  stringsAsFactors = FALSE
)

artifact_dir <- file.path(project_root, "artifacts", "premap_model")
utils::write.csv(
  summary,
  file.path(artifact_dir, "pinnacle_snapshot_timing_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  group_audit,
  file.path(artifact_dir, "pinnacle_snapshot_timing_by_event_period.csv"),
  row.names = FALSE
)
utils::write.csv(
  linked,
  file.path(artifact_dir, "pinnacle_snapshot_timing_linked_maps.csv"),
  row.names = FALSE
)
print(summary, row.names = FALSE)
print(
  utils::head(
    linked[
      order(abs(linked$cutoff_minus_game_datetime_minutes)),
      ,
      drop = FALSE
    ],
    20L
  ),
  row.names = FALSE
)
