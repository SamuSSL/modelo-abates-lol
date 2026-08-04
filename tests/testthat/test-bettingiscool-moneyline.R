test_that("kills fixtures pair uniquely to Regular fixtures", {
  fixtures <- data.frame(
    event_id = c("kills-1", "regular-1", "regular-far"),
    league_id = c(10L, 10L, 10L),
    starts = c(
      "2025-05-01T10:00:30Z",
      "2025-05-01T10:00:00Z",
      "2025-05-01T12:00:00Z"
    ),
    runner_home = c("Team A (Kills)", "Team A", "Team A"),
    runner_away = c("Team B (Kills)", "Team B", "Team B"),
    resulting_unit = c("Kills", "Regular", "Regular"),
    stringsAsFactors = FALSE
  )
  links <- match_bettingiscool_regular_events(fixtures)

  expect_equal(links$link_status, "verified")
  expect_equal(links$regular_event_id, "regular-1")
})

test_that("moneyline contract fixes odds1 as home and odds2 as away", {
  odds <- data.frame(
    event_id = "regular-1",
    period = 2L,
    market = "moneyline",
    odds1 = 1.5,
    odds2 = 2.8,
    todds1 = 1.6,
    todds2 = 2.6666667,
    timestamp = "2025-05-01T10:40:00Z",
    cutoff = "2025-05-01T11:00:00Z",
    status = 1L,
    stringsAsFactors = FALSE
  )
  fixture <- data.frame(
    event_id = "regular-1",
    runner_home = "Team A",
    runner_away = "Team B",
    resulting_unit = "Regular"
  )
  normalized <- normalize_bettingiscool_moneyline_odds(
    odds,
    "2025-05-02T00:00:00Z",
    fixture = fixture
  )
  probabilities <- derive_moneyline_favoritism(normalized)

  expect_equal(normalized$odds_home, 1.5)
  expect_equal(normalized$odds_away, 2.8)
  expect_equal(probabilities$p_home + probabilities$p_away, 1)
  expect_gt(probabilities$p_home, probabilities$p_away)
})

test_that("moneyline snapshot is open and between 15 and 30 minutes", {
  snapshots <- data.frame(
    event_id = rep("regular-1", 4L),
    period = rep(1L, 4L),
    odds_timestamp = c(
      "2025-05-01T10:30:00Z",
      "2025-05-01T10:42:00Z",
      "2025-05-01T10:44:00Z",
      "2025-05-01T10:50:00Z"
    ),
    market_cutoff = rep("2025-05-01T11:00:00Z", 4L),
    market_status = c(1L, 1L, 2L, 1L),
    true_odds_home = rep(1.8, 4L),
    true_odds_away = rep(2.25, 4L),
    stringsAsFactors = FALSE
  )
  selected <- select_bettingiscool_moneyline_snapshots(snapshots)

  expect_equal(
    selected$odds_timestamp,
    as.POSIXct("2025-05-01 10:30:00", tz = "UTC")
  )
  expect_equal(
    selected$market_close_time,
    as.POSIXct("2025-05-01 10:50:00", tz = "UTC")
  )
  expect_equal(
    selected$provider_market_cutoff,
    as.POSIXct("2025-05-01 11:00:00", tz = "UTC")
  )
  expect_equal(selected$provider_cutoff_minus_close_minutes, 10)
  expect_equal(selected$market_close_source, "final_main_history_timestamp")
  expect_equal(selected$snapshot_minutes_before_close, 20)
})

test_that("favoritism guardrail blocks small cells", {
  data <- data.frame(
    league_canonical = rep("LCK", 20),
    favorite_band = rep("super_favorite", 20)
  )
  coverage <- summarize_favoritism_coverage(data)

  expect_false(coverage$eligible)
  expect_equal(
    coverage$message,
    "Pouca amostra para esta faixa. Não apostar"
  )
})
