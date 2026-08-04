test_that("request requires the API key without printing a secret", {
  expect_error(
    bettingiscool_request(
      "/api/sports",
      api_key = ""
    ),
    "BETTINGISCOOL_API_KEY"
  )
})

test_that("request records quota and retries 429 responses", {
  attempts <- 0L
  transport <- function(url, api_key) {
    attempts <<- attempts + 1L
    if (attempts == 1L) {
      return(list(
        status_code = 429L,
        headers = list("retry-after" = "0"),
        content = "[]"
      ))
    }
    list(
      status_code = 200L,
      headers = list(
        "x-quota-limit" = "500000",
        "x-quota-remaining" = "499990",
        "x-quota-cost" = "10",
        "x-rows" = "9"
      ),
      content = '[{"sport_id":12,"sport_name":"E Sports"}]'
    )
  }
  response <- bettingiscool_request(
    "/api/sports",
    api_key = "test-only",
    transport = transport,
    sleeper = function(seconds) invisible(seconds)
  )

  expect_equal(attempts, 2L)
  expect_equal(response$quota_remaining, 499990)
  expect_equal(response$row_count, 9)
  expect_equal(response$data$sport_id, 12)
})

test_that("kills contract fixes odds1 as Over and odds2 as Under", {
  raw <- data.frame(
    event_id = 123,
    period = 2,
    market = "totals",
    line = 25.5,
    odds1 = 1.91,
    odds2 = 1.95,
    todds1 = 2.02,
    todds2 = 1.98,
    line_id = 44,
    alt_line_id = NA,
    timestamp = "2026-01-01T12:00:00Z",
    cutoff = "2026-01-01T12:30:00Z",
    stringsAsFactors = FALSE
  )

  normalized <- normalize_bettingiscool_kills_odds(
    raw,
    retrieved_at = "2026-07-28T00:00:00Z"
  )

  expect_equal(normalized$odds_over, 1.91)
  expect_equal(normalized$odds_under, 1.95)
  expect_equal(normalized$true_odds_over, 2.02)
  expect_equal(normalized$true_odds_under, 1.98)
  expect_equal(normalized$period, 2L)
  expect_match(normalized$snapshot_id, "^[a-f0-9]{64}$")
})

test_that("kills contract rejects non-map and non-total markets", {
  raw <- data.frame(
    event_id = 123,
    period = 0,
    market = "moneyline",
    line = 25.5,
    odds1 = 1.91,
    odds2 = 1.95,
    todds1 = 2.02,
    todds2 = 1.98
  )

  expect_error(
    validate_bettingiscool_kills_contract(raw),
    "market=totals"
  )
})

test_that("known LCK kills event confirms the authenticated API contract", {
  skip_if(
    !nzchar(Sys.getenv("BETTINGISCOOL_API_KEY", unset = "")),
    "BETTINGISCOOL_API_KEY is not configured"
  )
  response <- bettingiscool_request(
    "/api/odds",
    query = list(
      event_id = 1609632978L,
      market = "totals",
      full_history = 1L,
      main_lines_only = 1L
    )
  )
  odds <- .bettingiscool_as_data_frame(response$data)
  odds <- odds[as.integer(odds$period) >= 1L, , drop = FALSE]

  expect_true(validate_bettingiscool_kills_contract(odds))
  expect_setequal(unique(as.integer(odds$period)), c(1L, 2L, 3L))
  expect_true(all(as.numeric(odds$todds1) > 1))
  expect_true(all(as.numeric(odds$todds2) > 1))
})
