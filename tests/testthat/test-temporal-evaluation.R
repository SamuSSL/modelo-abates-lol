make_temporal_games <- function() {
  data.frame(
    gameid = paste0("G", seq_len(8L)),
    league_canonical = rep(c("LCK", "LPL"), 4L),
    competition_role = "target",
    target_valid = TRUE,
    series_eligible = TRUE,
    series_cutoff = as.POSIXct(
      c(
        "2023-01-01 00:00:00",
        "2023-06-01 00:00:00",
        "2024-01-01 00:00:00",
        "2024-06-01 00:00:00",
        "2025-01-15 00:00:00",
        "2025-02-15 00:00:00",
        "2025-04-15 00:00:00",
        "2026-01-15 00:00:00"
      ),
      tz = "UTC"
    ),
    game_datetime = as.POSIXct(
      c(
        "2023-01-01 00:00:00",
        "2023-06-01 00:00:00",
        "2024-01-01 00:00:00",
        "2024-06-01 00:00:00",
        "2025-01-15 00:00:00",
        "2025-02-15 00:00:00",
        "2025-04-15 00:00:00",
        "2026-01-15 00:00:00"
      ),
      tz = "UTC"
    ),
    total_kills_game = c(20L, 22L, 24L, 26L, 28L, 30L, 32L, 34L),
    stringsAsFactors = FALSE
  )
}

test_that("discrete CRPS matches deterministic known cases", {
  expect_equal(discrete_crps(c(1), observed = 0L), 0)
  expect_equal(discrete_crps(c(0, 1), observed = 2L), 1)
  expect_equal(discrete_crps(c(0.5, 0.5), observed = 0L), 0.25)
})

test_that("PMF validation rejects invalid probabilities", {
  expect_error(discrete_crps(c(0.5, -0.5, 1), 1L), "non-negative")
  expect_error(discrete_crps(c(0.2, 0.2), 1L), "sum to one")
})

test_that("training selection never includes validation or holdout", {
  games <- make_temporal_games()
  selected <- select_temporal_training(
    games,
    validation_start = as.POSIXct(
      "2025-04-01 00:00:00",
      tz = "UTC"
    ),
    window_type = "fixed_months",
    window_value = 18
  )

  expect_true(all(
    selected$data$series_cutoff <
      as.POSIXct("2025-04-01 00:00:00", tz = "UTC")
  ))
  expect_true(all(
    selected$data$series_cutoff >=
      as.POSIXct("2023-10-01 00:00:00", tz = "UTC")
  ))
  expect_false(any(selected$data$gameid == "G7"))
  expect_false(any(selected$data$gameid == "G8"))
})

test_that("exponential recency weights decrease into the past", {
  games <- make_temporal_games()
  selected <- select_temporal_training(
    games,
    validation_start = as.POSIXct(
      "2025-04-01 00:00:00",
      tz = "UTC"
    ),
    window_type = "exponential",
    window_value = 180
  )

  ordered <- order(selected$data$series_cutoff)
  expect_true(all(diff(selected$weights[ordered]) > 0))
  expect_true(all(selected$weights > 0 & selected$weights <= 1))
})

test_that("rolling validation excludes the sealed holdout", {
  games <- make_temporal_games()
  folds <- data.frame(
    fold_id = c("q1", "q2"),
    validation_start = as.POSIXct(
      c("2025-01-01 00:00:00", "2025-04-01 00:00:00"),
      tz = "UTC"
    ),
    validation_end = as.POSIXct(
      c("2025-04-01 00:00:00", "2025-07-01 00:00:00"),
      tz = "UTC"
    ),
    stringsAsFactors = FALSE
  )

  result <- build_validation_rows(
    games,
    folds,
    holdout_start = as.POSIXct("2026-01-01 00:00:00", tz = "UTC")
  )

  expect_setequal(result$gameid, c("G5", "G6", "G7"))
  expect_false(any(result$gameid == "G8"))
})

test_that("league empirical PMF shrinks toward global distribution", {
  train <- data.frame(
    league_canonical = c("LCK", "LCK", "LPL", "LPL"),
    total_kills_game = c(1L, 1L, 3L, 3L),
    stringsAsFactors = FALSE
  )

  lck <- predict_league_empirical_pmf(
    train,
    league = "LCK",
    prior_games = 2
  )
  unseen <- predict_league_empirical_pmf(
    train,
    league = "LEC",
    prior_games = 2
  )

  expect_equal(lck, c(0, 0.75, 0, 0.25))
  expect_equal(unseen, c(0, 0.5, 0, 0.5))
  expect_equal(sum(lck), 1)
})

test_that("window candidate grid preserves the pre-registered options", {
  config <- list(
    window_candidates = list(
      fixed_months = c(12, 18),
      calendar = c("current_season", "all_since_2022"),
      exponential_half_life_days = c(90, 180)
    )
  )

  candidates <- build_window_candidate_grid(config)

  expect_equal(
    candidates$candidate_id,
    c(
      "fixed_12m",
      "fixed_18m",
      "current_season",
      "all_since_2022",
      "exponential_hl90d",
      "exponential_hl180d"
    )
  )
})

test_that("window evaluation stores only development predictions", {
  games <- make_temporal_games()
  folds <- data.frame(
    fold_id = "q2",
    validation_start = as.POSIXct(
      "2025-04-01 00:00:00",
      tz = "UTC"
    ),
    validation_end = as.POSIXct(
      "2025-07-01 00:00:00",
      tz = "UTC"
    ),
    stringsAsFactors = FALSE
  )
  candidates <- data.frame(
    candidate_id = "fixed_18m",
    window_type = "fixed_months",
    window_value = 18,
    stringsAsFactors = FALSE
  )

  result <- evaluate_window_candidates(
    games,
    folds,
    candidates,
    holdout_start = as.POSIXct("2026-01-01 00:00:00", tz = "UTC"),
    prior_games = 2
  )

  expect_equal(result$map_metrics$gameid, "G7")
  expect_true(result$map_metrics$prediction_cutoff < result$map_metrics$game_datetime)
  expect_true(is.finite(result$map_metrics$crps))
  expect_true(is.finite(result$map_metrics$log_score))
  expect_false(any(result$map_metrics$gameid == "G8"))
  expect_equal(result$summary$folds_completed, 1L)
})

test_that("paired temporal bootstrap is reproducible and paired by map", {
  metrics <- data.frame(
    gameid = rep(paste0("G", seq_len(6L)), 2L),
    candidate_id = rep(c("candidate", "reference"), each = 6L),
    game_datetime = rep(
      as.POSIXct(
        c(
          "2025-01-01 00:00:00",
          "2025-01-02 00:00:00",
          "2025-01-10 00:00:00",
          "2025-01-11 00:00:00",
          "2025-01-20 00:00:00",
          "2025-01-21 00:00:00"
        ),
        tz = "UTC"
      ),
      2L
    ),
    crps = c(rep(1, 6L), rep(2, 6L)),
    stringsAsFactors = FALSE
  )

  first <- paired_block_bootstrap_crps(
    metrics,
    candidate_id = "candidate",
    reference_id = "reference",
    replicates = 100,
    seed = 42
  )
  second <- paired_block_bootstrap_crps(
    metrics,
    candidate_id = "candidate",
    reference_id = "reference",
    replicates = 100,
    seed = 42
  )

  expect_equal(first, second)
  expect_equal(first$mean_difference, -1)
  expect_equal(first$ci_lower, -1)
  expect_equal(first$ci_upper, -1)
  expect_equal(first$paired_maps, 6L)
})
