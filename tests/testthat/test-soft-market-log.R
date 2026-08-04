make_soft_quote <- function() {
  data.frame(
    quoted_at = as.POSIXct("2026-07-29 12:00:00", tz = "UTC"),
    bookmaker = "Soft Example",
    gameid = "game-1",
    league_canonical = "LCK",
    map_number = 1L,
    side = "Over",
    line = 26.5,
    decimal_odds = 2.10,
    pinnacle_line = 27.5,
    pinnacle_decimal_odds = 1.95,
    pinnacle_probability_over = 0.51,
    p_blue = 0.70,
    p_red = 0.30,
    favorite_band = "moderate_favorite",
    model_family = "fundamental",
    model_version = "premap-v1",
    model_probability = 0.52,
    stringsAsFactors = FALSE
  )
}

test_that("soft quote enforces fixed stake and five-percent EV", {
  quote <- prepare_soft_market_quote(make_soft_quote())

  expect_equal(quote$decision, "bet")
  expect_equal(quote$stake, 1)
  expect_equal(quote$expected_value, 0.092)
})

test_that("soft quote storage is idempotent", {
  connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
  quote <- make_soft_quote()

  expect_equal(append_soft_market_quote(connection, quote), 1L)
  expect_equal(append_soft_market_quote(connection, quote), 0L)
})
