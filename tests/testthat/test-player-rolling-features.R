test_that("player histories use only maps before the series cutoff", {
  metrics <- data.frame(
    gameid = c("OLD", "NEW", "FUTURE"),
    game_datetime = as.POSIXct(
      c(
        "2025-01-01 12:00:00",
        "2025-02-01 12:00:00",
        "2025-02-02 12:00:00"
      ),
      tz = "UTC"
    ),
    series_cutoff = as.POSIXct(
      c(
        "2025-01-01 12:00:00",
        "2025-02-01 00:00:00",
        "2025-02-01 00:00:00"
      ),
      tz = "UTC"
    ),
    league_canonical = "LCK",
    competition_role = "target",
    side = "Blue",
    position = "top",
    player_id = "player-1",
    player_name = "Player",
    champion = "A",
    conflict_involvement_per_minute = c(1, 100, 200),
    stringsAsFactors = FALSE
  )

  result <- build_player_rolling_features(
    metrics,
    "conflict_involvement_per_minute",
    half_life_days = 60,
    prior_games = 0
  )

  new_rows <- result[result$gameid %in% c("NEW", "FUTURE"), ]
  expect_equal(
    new_rows$hist_conflict_involvement_per_minute,
    rep(1, 2)
  )
  expect_true(all(
    new_rows$latest_history_datetime < new_rows$series_cutoff
  ))
})

test_that("map player and draft features are symmetric", {
  players <- expand.grid(
    side = c("Blue", "Red"),
    position = c("top", "jng", "mid", "bot", "sup"),
    stringsAsFactors = FALSE
  )
  players$gameid <- "GAME"
  players$player_id <- paste0("p", seq_len(10L))
  players$player_name <- players$player_id
  players$champion <- rep(c("A", "B", "C", "D", "E"), 2L)
  players$raw_player_games <- 10L
  players$raw_champion_games <- 20L
  players$effective_champion_games <- 8
  players$effective_conflict_involvement_per_minute_games <- 5
  players$hist_conflict_involvement_per_minute <- 1
  players$hist_kills_assists_per_minute <- 0.5
  players$hist_deaths_per_minute <- 0.2
  players$hist_damage_per_minute <- 500
  taxonomy <- data.frame(
    champion = c("A", "B", "C", "D", "E"),
    tank = c(TRUE, FALSE, FALSE, FALSE, FALSE),
    fighter = c(FALSE, TRUE, FALSE, FALSE, FALSE),
    assassin = c(FALSE, FALSE, TRUE, FALSE, FALSE),
    mage = c(FALSE, FALSE, TRUE, TRUE, FALSE),
    marksman = c(FALSE, FALSE, FALSE, FALSE, TRUE),
    support = c(FALSE, FALSE, FALSE, FALSE, FALSE),
    attack = c(0.2, 0.6, 0.8, 0.4, 1),
    defense = c(1, 0.6, 0.2, 0.3, 0.2),
    magic = c(0.1, 0.2, 1, 1, 0.1),
    difficulty = rep(0.5, 5L),
    stringsAsFactors = FALSE
  )

  result <- assemble_player_draft_features(players, taxonomy)

  expect_equal(nrow(result), 1L)
  expect_equal(result$player_conflict, 1)
  expect_equal(result$minimum_raw_player_games, 10L)
  expect_equal(result$minimum_effective_champion_games, 8)
  expect_equal(result$draft_frontline_imbalance, 0)
})

test_that("player champion interaction uses strong shrinkage and no future maps", {
  metrics <- data.frame(
    gameid = c("A1", "B1", "A2", "NEXT"),
    game_datetime = as.POSIXct(
      c(
        "2025-01-01 12:00:00",
        "2025-01-10 12:00:00",
        "2025-01-20 12:00:00",
        "2025-02-01 12:00:00"
      ),
      tz = "UTC"
    ),
    series_cutoff = as.POSIXct(
      c(
        "2025-01-01 12:00:00",
        "2025-01-10 12:00:00",
        "2025-01-20 12:00:00",
        "2025-02-01 00:00:00"
      ),
      tz = "UTC"
    ),
    league_canonical = "LCK",
    competition_role = "target",
    side = "Blue",
    position = "mid",
    player_id = "player-1",
    player_name = "Player",
    champion = c("A", "B", "A", "A"),
    conflict_involvement_per_minute = c(2, 1, 2, 100),
    stringsAsFactors = FALSE
  )

  result <- build_player_rolling_features(
    metrics,
    "conflict_involvement_per_minute",
    half_life_days = 60,
    prior_games = 5,
    interaction_prior_games = 30
  )
  next_map <- result[result$gameid == "NEXT", ]

  expect_equal(next_map$raw_player_champion_games, 2L)
  expect_lt(
    next_map$hist_player_champion_conflict_involvement_per_minute,
    2
  )
  expect_gt(
    next_map$hist_player_champion_conflict_involvement_per_minute,
    next_map$hist_conflict_involvement_per_minute
  )
  expect_lt(
    next_map$latest_player_champion_history_datetime,
    next_map$series_cutoff
  )
})
