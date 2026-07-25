test_that("constant time series remains normalized at one hundred", {
  periods <- as.Date("2024-01-01") + 7 * 0:15
  result <- compute_time_series_indicators(
    periods,
    rep(25, length(periods)),
    short_span = 3,
    long_span = 8,
    trend_window = 5,
    volatility_window = 5
  )

  expect_equal(result$normalized_index, rep(100, length(periods)))
  expect_equal(result$momentum_percent, rep(0, length(periods)))
  expect_equal(tail(result$trend_per_week, 1), 0)
  expect_equal(tail(result$volatility_percent, 1), 0)
  expect_equal(tail(result$regime, 1), "balanced")
})

test_that("rising series has positive causal momentum and trend", {
  periods <- as.Date("2024-01-01") + 7 * 0:19
  values <- seq(20, 39)
  result <- compute_time_series_indicators(
    periods,
    values,
    short_span = 3,
    long_span = 10,
    trend_window = 6,
    volatility_window = 6
  )

  expect_gt(tail(result$normalized_index, 1), 100)
  expect_gt(tail(result$momentum_percent, 1), 0)
  expect_gt(tail(result$trend_per_week, 1), 0)
  expect_equal(tail(result$regime, 1), "hot_accelerating")

  changed <- values
  changed[[length(changed)]] <- 500
  changed_result <- compute_time_series_indicators(
    periods,
    changed,
    short_span = 3,
    long_span = 10,
    trend_window = 6,
    volatility_window = 6
  )
  expect_equal(
    head(result$normalized_index, -1),
    head(changed_result$normalized_index, -1)
  )
})

test_that("tracking builder returns league and team weekly series", {
  dates <- as.POSIXct(
    "2024-01-01 12:00:00",
    tz = "UTC"
  ) + 7 * 86400 * 0:11
  games <- data.frame(
    gameid = paste0("G", seq_along(dates)),
    game_datetime = dates,
    league_canonical = "LCK",
    competition_role = "target",
    target_valid = TRUE,
    total_kills_game = seq(20, 31),
    game_length_seconds = rep(1800, length(dates)),
    stringsAsFactors = FALSE
  )
  team_metrics <- do.call(rbind, lapply(seq_along(dates), function(index) {
    data.frame(
      gameid = games$gameid[[index]],
      game_datetime = dates[[index]],
      league_canonical = "LCK",
      competition_role = "target",
      team_id = c("A", "B"),
      team_name = c("A", "B"),
      kills_per_minute = c(0.5, 0.3),
      deaths_per_minute = c(0.3, 0.5),
      combined_kills_per_minute = 0.8,
      game_length_minutes = 30,
      stringsAsFactors = FALSE
    )
  }))
  ratings <- team_metrics
  ratings$series_cutoff <- ratings$game_datetime
  ratings$rating_attack_league <- rep(c(110, 90), length(dates))
  ratings$rating_defense_league <- rep(c(105, 95), length(dates))
  ratings$rating_attack_global <- rep(c(108, 92), length(dates))
  ratings$rating_defense_global <- rep(c(104, 96), length(dates))
  ratings$aggression_ahead_league <- rep(c(106, 94), length(dates))
  ratings$aggression_behind_league <- rep(c(103, 97), length(dates))
  ratings$snowball_index_league <- rep(c(107, 93), length(dates))

  result <- build_tracking_time_series(
    games,
    team_metrics,
    ratings,
    min_date = as.Date("2024-01-01")
  )

  expect_true(all(c(
    "period",
    "entity_type",
    "league_canonical",
    "entity_name",
    "metric",
    "value",
    "normalized_index",
    "momentum_percent",
    "trend_per_week",
    "volatility_percent",
    "regime"
  ) %in% names(result)))
  expect_true(all(c("league", "team") %in% result$entity_type))
  expect_true("total_kills" %in% result$metric)
  expect_true("rating_attack_league" %in% result$metric)
})

test_that("model tracking features use only completed prior weeks", {
  maps <- data.frame(
    league_canonical = c("LCK", "LCK"),
    series_cutoff = as.POSIXct(
      c("2024-01-15 12:00:00", "2024-01-22 12:00:00"),
      tz = "UTC"
    ),
    blue_team_name.x = c("A", "A"),
    red_team_name.x = c("B", "B"),
    stringsAsFactors = FALSE
  )
  tracking <- do.call(rbind, lapply(
    c("total_kills", "combined_kills_per_minute",
      "rating_attack_league", "rating_defense_league"),
    function(metric) {
      entities <- if (metric == "total_kills") "LCK" else c("A", "B")
      do.call(rbind, lapply(entities, function(entity) {
        data.frame(
          period = as.Date(c("2024-01-08", "2024-01-15")),
          entity_type = if (metric == "total_kills") "league" else "team",
          league_canonical = "LCK",
          entity_name = entity,
          metric = metric,
          normalized_index = c(90, 110),
          momentum_percent = c(-10, 10),
          trend_per_week = c(-1, 1),
          volatility_percent = c(2, 3),
          stringsAsFactors = FALSE
        )
      }))
    }
  ))

  result <- attach_tracking_features_to_maps(maps, tracking)

  expect_equal(result$tracking_league_kills_index, c(90, 110))
  expect_equal(result$tracking_matchup_bloodiness_momentum, c(-10, 10))

  changed <- tracking
  changed$normalized_index[
    changed$period == as.Date("2024-01-15")
  ] <- 999
  changed_result <- attach_tracking_features_to_maps(maps, changed)
  expect_equal(
    result$tracking_league_kills_index[[1L]],
    changed_result$tracking_league_kills_index[[1L]]
  )
})
