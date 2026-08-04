pkgload::load_all(".", quiet = TRUE)
testthat::test_dir(
  "tests/testthat",
  reporter = "summary",
  stop_on_failure = TRUE
)
