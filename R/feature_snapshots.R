#' Build a current team feature snapshot
#'
#' @param team_metrics Historical team-map metrics.
#' @param metric_names Metrics to estimate.
#' @param snapshot_cutoff Timestamp after the latest allowed result.
#' @param half_life_days Exponential-decay half-life.
#' @param prior_games League-prior strength.
#' @return One frozen feature row per team.
#' @export
build_team_feature_snapshot <- function(
  team_metrics,
  metric_names,
  snapshot_cutoff,
  half_life_days = 60,
  prior_games = 10
) {
  rows <- team_metrics[
    team_metrics$competition_role %in% c("target", "auxiliary"),
    ,
    drop = FALSE
  ]
  rows <- rows[
    order(rows$game_datetime, rows$gameid, rows$side),
    ,
    drop = FALSE
  ]
  key <- vapply(seq_len(nrow(rows)), function(index) {
    .rolling_team_key(
      rows$team_id[[index]],
      rows$team_name[[index]]
    )
  }, character(1L))
  latest <- !duplicated(key, fromLast = TRUE)
  synthetic <- rows[latest, , drop = FALSE]
  synthetic$gameid <- paste0("SNAPSHOT_TEAM_", seq_len(nrow(synthetic)))
  synthetic$game_datetime <- as.POSIXct(snapshot_cutoff, tz = "UTC")
  synthetic$series_cutoff <- as.POSIXct(snapshot_cutoff, tz = "UTC")
  synthetic$competition_role <- "target"
  for (metric in metric_names) {
    synthetic[[metric]] <- NA_real_
  }
  combined <- rbind(rows, synthetic)
  features <- build_team_rolling_features(
    combined,
    metric_names,
    half_life_days,
    prior_games
  )
  features[
    startsWith(features$gameid, "SNAPSHOT_TEAM_"),
    ,
    drop = FALSE
  ]
}

#' Build a current player feature snapshot
#'
#' @param player_metrics Historical player-map metrics.
#' @param metric_names Metrics to estimate.
#' @param snapshot_cutoff Timestamp after the latest allowed result.
#' @param half_life_days Exponential-decay half-life.
#' @param prior_games League-position prior strength.
#' @return One frozen feature row per player and position.
#' @export
build_player_feature_snapshot <- function(
  player_metrics,
  metric_names,
  snapshot_cutoff,
  half_life_days = 60,
  prior_games = 10
) {
  rows <- player_metrics[
    player_metrics$competition_role %in% c("target", "auxiliary"),
    ,
    drop = FALSE
  ]
  rows <- rows[
    order(
      rows$game_datetime,
      rows$gameid,
      rows$side,
      rows$position
    ),
    ,
    drop = FALSE
  ]
  key <- vapply(seq_len(nrow(rows)), function(index) {
    .rolling_player_key(
      rows$player_id[[index]],
      rows$player_name[[index]],
      rows$position[[index]]
    )
  }, character(1L))
  latest <- !duplicated(key, fromLast = TRUE)
  synthetic <- rows[latest, , drop = FALSE]
  synthetic$gameid <- paste0(
    "SNAPSHOT_PLAYER_",
    seq_len(nrow(synthetic))
  )
  synthetic$game_datetime <- as.POSIXct(snapshot_cutoff, tz = "UTC")
  synthetic$series_cutoff <- as.POSIXct(snapshot_cutoff, tz = "UTC")
  synthetic$competition_role <- "target"
  for (metric in metric_names) {
    synthetic[[metric]] <- NA_real_
  }
  combined <- rbind(rows, synthetic)
  features <- build_player_rolling_features(
    combined,
    metric_names,
    half_life_days,
    prior_games
  )
  features[
    startsWith(features$gameid, "SNAPSHOT_PLAYER_"),
    ,
    drop = FALSE
  ]
}
