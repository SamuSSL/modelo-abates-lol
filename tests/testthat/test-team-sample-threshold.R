test_that("team sample coverage uses the weaker recent history", {
  maps <- data.frame(
    gameid = c("G1", "G2"),
    blue_effective_combined_kills_per_minute_games = c(8, 20),
    red_effective_combined_kills_per_minute_games = c(5, 25),
    blue_raw_team_games = c(30L, 100L),
    red_raw_team_games = c(12L, 80L),
    stringsAsFactors = FALSE
  )

  result <- derive_team_sample_coverage(maps)

  expect_equal(result$minimum_effective_team_games, c(5, 20))
  expect_equal(result$minimum_raw_team_games, c(12L, 80L))
  expect_equal(result$blue_effective_team_games, c(8, 20))
  expect_equal(result$red_effective_team_games, c(5, 25))
})

test_that("sample threshold selects first reliable separation", {
  dates <- seq(
    as.POSIXct("2024-01-01 12:00:00", tz = "UTC"),
    by = "7 days",
    length.out = 12L
  )
  coverage <- data.frame(
    gameid = paste0("G", seq_along(dates)),
    minimum_effective_team_games = c(rep(1, 4L), rep(5, 8L)),
    minimum_raw_team_games = c(rep(2L, 4L), rep(20L, 8L)),
    stringsAsFactors = FALSE
  )
  make_candidate <- function(candidate_id, crps) {
    data.frame(
      gameid = coverage$gameid,
      candidate_id = candidate_id,
      league_canonical = rep(c("LCK", "LEC"), 6L),
      fold_id = "2024_q1",
      game_datetime = dates,
      crps = crps,
      log_score = crps / 2,
      observed = 25L,
      prediction_mean = 25,
      lower_90 = 10L,
      upper_90 = 40L,
      stringsAsFactors = FALSE
    )
  }
  reference <- rep(5, 12L)
  signal <- c(rep(5.2, 4L), rep(4.5, 8L))
  metrics <- rbind(
    make_candidate("nb_pace", signal),
    make_candidate("nb_league", reference)
  )

  result <- evaluate_team_sample_thresholds(
    map_metrics = metrics,
    coverage = coverage,
    thresholds = c(1, 3, 5),
    signal_candidate_id = "nb_pace",
    reference_candidate_id = "nb_league",
    bootstrap_replicates = 200L,
    bootstrap_seed = 123L
  )

  expect_equal(result$selected$threshold, 3)
  expect_true(result$thresholds$eligible_reliable_gain[
    result$thresholds$threshold == 3
  ])
  expect_false(result$thresholds$blocked_reliable_gain[
    result$thresholds$threshold == 3
  ])
  expect_equal(
    result$thresholds$eligible_maps[
      result$thresholds$threshold == 3
    ],
    8L
  )
})

test_that("sample threshold returns no selection without separation", {
  dates <- seq(
    as.POSIXct("2024-01-01 12:00:00", tz = "UTC"),
    by = "7 days",
    length.out = 10L
  )
  coverage <- data.frame(
    gameid = paste0("G", seq_along(dates)),
    minimum_effective_team_games = seq_len(10L),
    stringsAsFactors = FALSE
  )
  metrics <- do.call(rbind, lapply(
    c("nb_pace", "nb_league"),
    function(candidate_id) {
      data.frame(
        gameid = coverage$gameid,
        candidate_id = candidate_id,
        league_canonical = "LCK",
        fold_id = "2024_q1",
        game_datetime = dates,
        crps = 5,
        log_score = 3,
        observed = 25L,
        prediction_mean = 25,
        lower_90 = 10L,
        upper_90 = 40L,
        stringsAsFactors = FALSE
      )
    }
  ))

  result <- evaluate_team_sample_thresholds(
    map_metrics = metrics,
    coverage = coverage,
    thresholds = c(3, 5),
    signal_candidate_id = "nb_pace",
    reference_candidate_id = "nb_league",
    bootstrap_replicates = 100L,
    bootstrap_seed = 123L
  )

  expect_equal(nrow(result$selected), 0L)
})

test_that("team sample gate blocks the weak side with operational message", {
  blocked <- assess_team_sample_eligibility(
    blue_team = "Blue Team",
    red_team = "Red Team",
    blue_effective_games = 0.8,
    red_effective_games = 5,
    minimum_effective_games = 1
  )
  allowed <- assess_team_sample_eligibility(
    blue_team = "Blue Team",
    red_team = "Red Team",
    blue_effective_games = 1,
    red_effective_games = 5,
    minimum_effective_games = 1
  )

  expect_equal(blocked$status, "blocked")
  expect_equal(blocked$blocked_entities, "Blue Team")
  expect_match(
    blocked$warning,
    "Pouca amostra para Blue Team. Não apostar",
    fixed = TRUE
  )
  expect_equal(allowed$status, "ok")
  expect_length(allowed$blocked_entities, 0L)
  expect_null(allowed$warning)
})

test_that("team sample gate treats missing coverage as insufficient", {
  result <- assess_team_sample_eligibility(
    blue_team = "Blue Team",
    red_team = "Red Team",
    blue_effective_games = NA_real_,
    red_effective_games = 5,
    minimum_effective_games = 1
  )

  expect_equal(result$status, "blocked")
  expect_equal(result$blocked_entities, "Blue Team")
})
