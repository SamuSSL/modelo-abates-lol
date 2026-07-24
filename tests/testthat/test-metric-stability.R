make_stability_fixture <- function() {
  dates <- as.POSIXct("2024-01-01", tz = "UTC") +
    seq.int(0, by = 86400, length.out = 16L)
  data.frame(
    gameid = paste0("G", seq_len(16L)),
    game_datetime = dates,
    league_canonical = rep(c("LCK", "LPL"), each = 8L),
    competition_role = "target",
    team_id = rep(c("A", "B"), each = 8L),
    team_name = rep(c("A", "B"), each = 8L),
    kills_per_minute = c(
      rep(c(0.2, 0.4, 0.6, 0.8), each = 2L),
      rep(c(0.3, 0.5, 0.7, 0.9), each = 2L)
    ),
    combined_kills_per_minute = c(
      rep(c(0.4, 0.6, 0.8, 1.0), each = 2L),
      rep(c(0.5, 0.7, 0.9, 1.1), each = 2L)
    ),
    total_kills_game = c(
      rep(c(20, 24, 28, 32), each = 2L),
      rep(c(22, 26, 30, 34), each = 2L)
    ),
    stringsAsFactors = FALSE
  )
}

test_that("stability pairs use complete consecutive past blocks", {
  result <- evaluate_metric_stability(
    make_stability_fixture(),
    metric_names = "kills_per_minute",
    block_size = 2L
  )

  expect_equal(nrow(result$block_metrics), 8L)
  expect_equal(nrow(result$pairs), 6L)
  expect_true(all(
    result$pairs$previous_block_end <
      result$pairs$next_block_start
  ))
  expect_equal(result$summary$pairs, 6L)
  expect_true(result$summary$stability_spearman > 0.9)
  expect_true(result$summary$future_intensity_spearman > 0.9)
})

test_that("stability study rejects unknown metrics", {
  expect_error(
    evaluate_metric_stability(
      make_stability_fixture(),
      metric_names = "unknown_metric",
      block_size = 2L
    ),
    "Unknown metrics"
  )
})
