test_that("team signals are symmetric and use only frozen histories", {
  maps <- data.frame(
    gameid = "G1",
    blue_hist_combined_kills_per_minute = 0.8,
    red_hist_combined_kills_per_minute = 1.0,
    blue_hist_kills_per_minute = 0.4,
    red_hist_kills_per_minute = 0.5,
    blue_hist_deaths_per_minute = 0.45,
    red_hist_deaths_per_minute = 0.35,
    blue_hist_damage_per_minute = 2000,
    red_hist_damage_per_minute = 2200,
    blue_hist_damage_taken_per_minute = 2100,
    red_hist_damage_taken_per_minute = 1900,
    stringsAsFactors = FALSE
  )

  result <- derive_team_signal_features(maps)
  swapped <- maps
  names(swapped) <- sub("^blue_", "temporary_", names(swapped))
  names(swapped) <- sub("^red_", "blue_", names(swapped))
  names(swapped) <- sub("^temporary_", "red_", names(swapped))
  swapped_result <- derive_team_signal_features(swapped)

  expect_equal(result$pace, 0.9)
  expect_equal(result$attack, 0.9)
  expect_equal(result$defensive_exposure, 0.8)
  expect_equal(result$attack_defense_balance, 0.1)
  expect_equal(result$damage_output, 2100)
  expect_equal(result$damage_exposure, 2000)
  expect_equal(
    result[c(
      "pace",
      "attack",
      "defensive_exposure",
      "attack_defense_balance",
      "damage_output",
      "damage_exposure"
    )],
    swapped_result[c(
      "pace",
      "attack",
      "defensive_exposure",
      "attack_defense_balance",
      "damage_output",
      "damage_exposure"
    )]
  )
})

test_that("pre-registered candidates are nested in fixed order", {
  config <- list(simple_team_models = list(candidates = list(
    list(
      id = "empirical_league",
      distribution = "empirical",
      feature_block = "league"
    ),
    list(
      id = "poisson_league",
      distribution = "poisson",
      feature_block = "league"
    ),
    list(
      id = "nb_league",
      distribution = "negative_binomial",
      feature_block = "league"
    ),
    list(
      id = "nb_pace",
      distribution = "negative_binomial",
      feature_block = "pace"
    ),
    list(
      id = "nb_attack_defense",
      distribution = "negative_binomial",
      feature_block = "attack_defense"
    ),
    list(
      id = "nb_pressure",
      distribution = "negative_binomial",
      feature_block = "pressure"
    )
  )))

  candidates <- build_simple_model_candidates(config)

  expect_equal(
    candidates$candidate_id,
    c(
      "empirical_league",
      "poisson_league",
      "nb_league",
      "nb_pace",
      "nb_attack_defense",
      "nb_pressure"
    )
  )
  expect_equal(
    unclass(candidates$feature_names),
    list(
      character(),
      character(),
      character(),
      "pace",
      c("pace", "attack_defense_balance"),
      c(
        "pace",
        "attack_defense_balance",
        "damage_output",
        "damage_exposure"
      )
    )
  )
})

test_that("Poisson and Negative Binomial PMFs preserve probability mass", {
  poisson <- make_count_pmf(
    mean = 25,
    distribution = "poisson",
    tail_tolerance = 1e-10
  )
  negative_binomial <- make_count_pmf(
    mean = 25,
    distribution = "negative_binomial",
    theta = 8,
    tail_tolerance = 1e-10
  )

  expect_equal(sum(poisson$pmf), 1, tolerance = 1e-12)
  expect_equal(sum(negative_binomial$pmf), 1, tolerance = 1e-12)
  expect_true(all(poisson$pmf >= 0))
  expect_true(all(negative_binomial$pmf >= 0))
  expect_lte(poisson$tail_mass, 1e-10)
  expect_lte(negative_binomial$tail_mass, 1e-10)
  expect_gt(stats::var(rep(
    seq_along(negative_binomial$pmf) - 1L,
    pmax(0L, round(negative_binomial$pmf * 1e6))
  )), 25)
})

test_that("count regression standardizes from training and predicts valid PMF", {
  train <- data.frame(
    league_canonical = rep(c("LCK", "LEC"), each = 40L),
    total_kills_game = c(
      rep(c(20L, 22L, 24L, 26L), 10L),
      rep(c(24L, 26L, 28L, 30L), 10L)
    ),
    pace = seq(0.7, 1.1, length.out = 80L),
    stringsAsFactors = FALSE
  )
  fit <- fit_count_regression(
    train,
    distribution = "poisson",
    feature_names = "pace",
    weights = rep(1, nrow(train))
  )
  future <- data.frame(
    league_canonical = "LCK",
    pace = 0.95,
    stringsAsFactors = FALSE
  )

  prediction <- predict_count_regression(
    fit,
    future,
    tail_tolerance = 1e-10
  )

  expect_equal(length(prediction), 1L)
  expect_true(is.finite(prediction[[1L]]$mean))
  expect_equal(sum(prediction[[1L]]$pmf), 1, tolerance = 1e-12)
  expect_equal(fit$scaling$pace$center, mean(train$pace))
  expect_error(
    predict_count_regression(
      fit,
      transform(future, league_canonical = "UNKNOWN")
    ),
    "unseen league"
  )
})

test_that("simple evaluation never trains on validation or holdout rows", {
  datetimes <- as.POSIXct(
    c(
      "2022-01-10 12:00:00",
      "2022-02-10 12:00:00",
      "2023-01-10 12:00:00",
      "2026-01-10 12:00:00"
    ),
    tz = "UTC"
  )
  maps <- data.frame(
    gameid = paste0("G", seq_along(datetimes)),
    game_datetime = datetimes,
    series_cutoff = datetimes,
    league_canonical = "LCK",
    total_kills_game = c(20L, 24L, 22L, 100L),
    pace = c(0.8, 0.9, 0.85, 5),
    attack = c(0.4, 0.5, 0.45, 5),
    defensive_exposure = c(0.4, 0.5, 0.45, 5),
    damage_output = c(2000, 2100, 2050, 9999),
    damage_exposure = c(2000, 2100, 2050, 9999),
    stringsAsFactors = FALSE
  )
  folds <- data.frame(
    fold_id = "2023_q1",
    validation_start = "2023-01-01 00:00:00",
    validation_end = "2023-04-01 00:00:00",
    stringsAsFactors = FALSE
  )
  candidates <- data.frame(
    candidate_id = "empirical_league",
    distribution = "empirical",
    feature_block = "league",
    stringsAsFactors = FALSE
  )
  candidates$feature_names <- I(list(character()))

  result <- evaluate_simple_team_models(
    maps,
    folds,
    candidates,
    holdout_start = "2026-01-01 00:00:00",
    training_start = "2022-01-01 00:00:00",
    half_life_days = 60,
    prior_games = 100
  )

  expect_equal(result$map_metrics$gameid, "G3")
  expect_equal(result$map_metrics$training_games, 2L)
  expect_lt(result$map_metrics$prediction_mean, 30)
  expect_false(any(result$map_metrics$game_datetime >=
    as.POSIXct("2026-01-01", tz = "UTC")))
})
