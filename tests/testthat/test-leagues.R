test_that("league mapping preserves the canonical targets", {
  expect_equal(
    canonical_target_leagues(),
    c("LCK", "LPL", "LEC", "CBLOL", "LCS", "LFL", "LES", "TCL", "PRM")
  )

  raw <- c(
    "LCK", "LVP SL", "LES", "LTA N", "LTA S", "TCL", "PRM", "LTA", "MSI"
  )
  expect_equal(
    canonicalize_league(raw),
    c("LCK", "LES", "LES", "LCS", "CBLOL", "TCL", "PRM", NA, NA)
  )
})

test_that("cross-LTA and international competitions remain auxiliary", {
  raw <- c("LTA N", "LTA S", "LTA", "MSI", "WLDs", "LCKC")

  expect_equal(
    classify_competition_role(raw),
    c("target", "target", "auxiliary", "auxiliary", "auxiliary", "excluded")
  )
})

test_that("project and packaged league configurations remain identical", {
  project_path <- testthat::test_path(
    "..",
    "..",
    "config",
    "leagues.yml"
  )
  testthat::skip_if_not(
    file.exists(project_path),
    "Operational project config is not included in the built package."
  )
  project_config <- yaml::read_yaml(project_path)
  packaged_config <- yaml::read_yaml(
    testthat::test_path("..", "..", "inst", "config", "leagues.yml")
  )

  expect_equal(project_config, packaged_config)
})
