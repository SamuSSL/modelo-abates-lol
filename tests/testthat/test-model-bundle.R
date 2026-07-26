test_that("champion sample snapshot decays completed picks", {
  metrics <- data.frame(
    champion = c("A", "A", "B"),
    game_datetime = as.POSIXct(
      c("2025-01-01", "2025-01-02", "2025-01-02"),
      tz = "UTC"
    ),
    competition_role = "target",
    stringsAsFactors = FALSE
  )
  snapshot <- build_champion_sample_snapshot(
    metrics,
    as.POSIXct("2025-01-03", tz = "UTC"),
    half_life_days = 60
  )

  expect_equal(snapshot$raw_champion_games[snapshot$champion == "A"], 2L)
  expect_true(
    snapshot$effective_champion_games[snapshot$champion == "A"] >
      snapshot$effective_champion_games[snapshot$champion == "B"]
  )
})

test_that("portable bundle contains model and lookup contracts", {
  fit <- structure(
    list(
      model = list(coefficients = c("(Intercept)" = 3, pace = 0.2)),
      distribution = "negative_binomial",
      feature_names = "pace",
      scaling = list(pace = list(center = 0.8, scale = 0.1)),
      league_levels = "LCK",
      theta = 10
    ),
    class = "lolkills_count_regression"
  )
  team_snapshot <- data.frame(
    team_id = "team",
    team_name = "Team",
    latest_team_name = "Team",
    latest_history_datetime = as.POSIXct(
      "2026-02-01 12:00:00",
      tz = "UTC"
    ),
    hist_combined_kills_per_minute = 0.8,
    effective_combined_kills_per_minute_games = 5,
    stringsAsFactors = FALSE
  )
  taxonomy <- data.frame(
    champion = "A",
    tank = TRUE,
    fighter = FALSE,
    assassin = FALSE,
    mage = FALSE,
    marksman = FALSE,
    support = FALSE,
    attack = 0.5,
    defense = 0.5,
    magic = 0.5,
    difficulty = 0.5,
    stringsAsFactors = FALSE
  )
  champion_samples <- data.frame(
    champion = "A",
    effective_champion_games = 3,
    stringsAsFactors = FALSE
  )

  bundle <- build_portable_model_bundle(
    fit,
    team_snapshot,
    taxonomy,
    champion_samples,
    metadata = list(
      model_version = "test",
      data_cutoff = "2026-01-01"
    ),
    sample_limits = list(
      team_effective_games = 1,
      champion_effective_games = 1
    )
  )

  expect_equal(bundle$model$feature_names, "pace")
  expect_equal(bundle$teams[[1L]]$key, "id:team")
  expect_equal(bundle$teams[[1L]]$latest_team_name, "Team")
  expect_match(
    bundle$teams[[1L]]$last_game_datetime,
    "^2026-02-01"
  )
  expect_false("players" %in% names(bundle))
  expect_equal(bundle$champion_samples$A, 3)
})
