test_that("matching accepts a unique inverted-team map and validates settlement", {
  fixtures <- data.frame(
    event_id = "10", league_id = 192553, starts = as.POSIXct(
      "2026-01-01 10:00:00", tz = "UTC"
    ),
    runner_home = "Red Team (Kills)", runner_away = "Blue-Team (Kills)"
  )
  periods <- data.frame(event_id = "10", period = 2L)
  games <- data.frame(
    gameid = "game-2", league_canonical = "LCK", map_number = 2L,
    game_datetime = as.POSIXct("2026-01-01 11:00:00", tz = "UTC"),
    blue_team_name = "Blue Team", red_team_name = "Red Team",
    blue_kills = 12, red_kills = 8
  )
  settlements <- data.frame(
    event_id = "10", period = 2L, result_status = 1L,
    score_home = 8, score_away = 12
  )
  manifest <- list(list(
    bettingiscool_league_id = 192553,
    canonical_league = "LCK",
    competition = "LCK"
  ))
  links <- match_bettingiscool_games(
    fixtures, periods, games, manifest, settlements = settlements
  )

  expect_equal(links$link_status, "verified")
  expect_equal(links$gameid, "game-2")
})

test_that("matching marks settlement disagreement as conflict", {
  fixtures <- data.frame(
    event_id = "10", league_id = 192553,
    starts = as.POSIXct("2026-01-01 10:00:00", tz = "UTC"),
    runner_home = "A", runner_away = "B"
  )
  periods <- data.frame(event_id = "10", period = 1L)
  games <- data.frame(
    gameid = "g", league_canonical = "LCK", map_number = 1L,
    game_datetime = as.POSIXct("2026-01-01 10:10:00", tz = "UTC"),
    blue_team_name = "A", red_team_name = "B",
    blue_kills = 10, red_kills = 5
  )
  settlements <- data.frame(
    event_id = "10", period = 1L, result_status = 1L,
    score_home = 11, score_away = 5
  )
  manifest <- list(list(
    bettingiscool_league_id = 192553,
    canonical_league = "LCK",
    competition = "LCK"
  ))
  links <- match_bettingiscool_games(
    fixtures, periods, games, manifest, settlements = settlements
  )

  expect_equal(links$link_status, "conflict")
})

test_that("matching keeps only the latest fixture version for each event", {
  fixtures <- data.frame(
    event_id = c("10", "10"),
    league_id = c(192553, 192553),
    starts = as.POSIXct(
      c("2026-01-01 10:00:00", "2026-01-01 10:00:00"),
      tz = "UTC"
    ),
    runner_home = c("A", "A"),
    runner_away = c("B", "B"),
    version = c("1", "2"),
    retrieved_at = as.POSIXct(
      c("2026-01-01 09:00:00", "2026-01-01 09:05:00"),
      tz = "UTC"
    )
  )
  periods <- data.frame(event_id = "10", period = 1L)
  games <- data.frame(
    gameid = "g", league_canonical = "LCK", map_number = 1L,
    game_datetime = as.POSIXct("2026-01-01 10:10:00", tz = "UTC"),
    blue_team_name = "A", red_team_name = "B",
    blue_kills = 10, red_kills = 5
  )
  manifest <- list(list(
    bettingiscool_league_id = 192553,
    canonical_league = "LCK",
    competition = "LCK"
  ))

  links <- match_bettingiscool_games(fixtures, periods, games, manifest)

  expect_equal(nrow(links), 1L)
  expect_equal(links$link_status, "verified")
})

test_that("BettingIsCool aliases configuration is valid UTF-8 YAML", {
  aliases <- yaml::read_yaml(testthat::test_path(
    "..", "..", "config", "bettingiscool-team-aliases.yml"
  ))

  expect_equal(aliases$aliases[["Barca"]], "Barca eSports")
})
