test_that("independent Regular moneylines match without a Kills fixture", {
  fixtures <- data.frame(
    fixture_id = "fixture-1",
    provider = "bettingiscool",
    event_id = "100",
    sport_id = 12L,
    league_id = 10L,
    league_name = "League of Legends - Test",
    starts = as.POSIXct("2025-06-01 12:00:00", tz = "UTC"),
    runner_home = "Alpha",
    runner_away = "Beta",
    live_status = 0L,
    resulting_unit = "Regular",
    parent_id = NA_character_,
    version = "1",
    retrieved_at = as.POSIXct("2026-01-01", tz = "UTC"),
    raw_sha256 = "raw",
    stringsAsFactors = FALSE
  )
  snapshots <- data.frame(
    event_id = "100",
    period = 1L,
    stringsAsFactors = FALSE
  )
  games <- data.frame(
    gameid = "game-1",
    league_canonical = "TEST",
    map_number = 1L,
    game_datetime = as.POSIXct("2025-06-01 12:10:00", tz = "UTC"),
    blue_team_name = "Beta",
    red_team_name = "Alpha",
    blue_kills = 8,
    red_kills = 12,
    stringsAsFactors = FALSE
  )
  manifest <- list(list(
    bettingiscool_league_id = 10L,
    canonical_league = "TEST",
    competition = "Test"
  ))

  links <- match_bettingiscool_regular_maps(
    fixtures,
    snapshots,
    games,
    manifest
  )

  expect_equal(nrow(links), 1L)
  expect_equal(links$link_status, "verified")
  expect_equal(links$gameid, "game-1")
})

test_that("direct attachment preserves home orientation and cutoff", {
  maps <- data.frame(
    gameid = "game-1",
    blue_team_name = "Beta",
    red_team_name = "Alpha",
    prediction_cutoff = as.POSIXct(
      "2025-06-01 11:55:00",
      tz = "UTC"
    ),
    stringsAsFactors = FALSE
  )
  links <- data.frame(
    gameid = "game-1",
    event_id = "100",
    period = 1L,
    link_status = "verified",
    stringsAsFactors = FALSE
  )
  fixtures <- data.frame(
    event_id = "100",
    runner_home = "Alpha",
    runner_away = "Beta",
    retrieved_at = as.POSIXct("2026-01-01", tz = "UTC"),
    stringsAsFactors = FALSE
  )
  moneylines <- data.frame(
    event_id = "100",
    period = 1L,
    true_odds_home = 1.25,
    true_odds_away = 5,
    odds_timestamp = as.POSIXct(
      "2025-06-01 11:54:00",
      tz = "UTC"
    ),
    market_close_time = as.POSIXct(
      "2025-06-01 12:10:00",
      tz = "UTC"
    ),
    stringsAsFactors = FALSE
  )

  attached <- attach_direct_moneyline_to_maps(
    maps,
    links,
    fixtures,
    moneylines
  )

  expect_equal(nrow(attached), 1L)
  expect_equal(attached$p_blue, 0.2)
  expect_equal(attached$p_red, 0.8)
  expect_true(attached$moneyline_is_point_in_time_valid)
})

test_that("direct attachment rejects post-cutoff snapshots", {
  maps <- data.frame(
    gameid = "game-1",
    blue_team_name = "Alpha",
    red_team_name = "Beta",
    prediction_cutoff = as.POSIXct(
      "2025-06-01 11:55:00",
      tz = "UTC"
    ),
    stringsAsFactors = FALSE
  )
  links <- data.frame(
    gameid = "game-1",
    event_id = "100",
    period = 1L,
    link_status = "verified",
    stringsAsFactors = FALSE
  )
  fixtures <- data.frame(
    event_id = "100",
    runner_home = "Alpha",
    runner_away = "Beta",
    retrieved_at = as.POSIXct("2026-01-01", tz = "UTC"),
    stringsAsFactors = FALSE
  )
  moneylines <- data.frame(
    event_id = "100",
    period = 1L,
    true_odds_home = 1.5,
    true_odds_away = 3,
    odds_timestamp = as.POSIXct(
      "2025-06-01 11:56:00",
      tz = "UTC"
    ),
    market_close_time = as.POSIXct(
      "2025-06-01 12:10:00",
      tz = "UTC"
    ),
    stringsAsFactors = FALSE
  )

  attached <- attach_direct_moneyline_to_maps(
    maps,
    links,
    fixtures,
    moneylines
  )

  expect_equal(nrow(attached), 0L)
})

test_that("direct attachment rejects ambiguous event-period matches", {
  maps <- data.frame(
    gameid = c("game-1", "game-2"),
    blue_team_name = c("Alpha", "Alpha"),
    red_team_name = c("Beta", "Beta"),
    prediction_cutoff = as.POSIXct(
      c("2025-06-01 11:55:00", "2025-06-01 11:55:00"),
      tz = "UTC"
    ),
    stringsAsFactors = FALSE
  )
  links <- data.frame(
    gameid = c("game-1", "game-2"),
    event_id = c("100", "100"),
    period = c(1L, 1L),
    link_status = c("verified", "verified"),
    stringsAsFactors = FALSE
  )
  fixtures <- data.frame(
    event_id = "100",
    runner_home = "Alpha",
    runner_away = "Beta",
    retrieved_at = as.POSIXct("2026-01-01", tz = "UTC"),
    stringsAsFactors = FALSE
  )
  moneylines <- data.frame(
    event_id = "100",
    period = 1L,
    true_odds_home = 1.5,
    true_odds_away = 3,
    odds_timestamp = as.POSIXct("2025-06-01 11:54:00", tz = "UTC"),
    market_close_time = as.POSIXct("2025-06-01 12:10:00", tz = "UTC"),
    stringsAsFactors = FALSE
  )

  attached <- attach_direct_moneyline_to_maps(
    maps,
    links,
    fixtures,
    moneylines
  )

  expect_equal(nrow(attached), 0L)
})
