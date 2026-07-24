test_that("Oracle's Elixir schema requires target and identity fields", {
  columns <- required_oe_columns()

  expect_true(validate_oe_schema(columns))
  expect_error(
    validate_oe_schema(setdiff(columns, "teamkills")),
    "Missing required Oracle's Elixir columns: teamkills"
  )
})

test_that("extra columns do not invalidate a known schema", {
  expect_true(validate_oe_schema(c(required_oe_columns(), "future_column")))
})

