synthetic_row <- function(swapped = FALSE) {
  row <- data.frame(map_number = 2, pace = 1.1)
  for (window in c("season", "last15")) {
    for (side in c("blue", "red")) {
      value <- if (side == "blue") 1.1 else 0.9
      row[[paste(side, window, "team_games", sep = "_")]] <- 12
      row[[paste(side, window, "attack_ratio", sep = "_")]] <- value
      row[[paste(side, window, "concession_ratio", sep = "_")]] <- 2 - value
      row[[paste(side, window, "kpm_ratio", sep = "_")]] <- value
      row[[paste(side, window, "dpm_ratio", sep = "_")]] <- 2 - value
      row[[paste(side, window, "duration_ratio", sep = "_")]] <- value
      row[[paste(side, window, "total_kills_sd_ratio", sep = "_")]] <- value
      row[[paste(side, window, "league_kills_per_map", sep = "_")]] <- 15
      row[[paste(side, window, "league_deaths_per_map", sep = "_")]] <- 15
      row[[paste(side, window, "league_duration", sep = "_")]] <- 30
    }
  }
  if (swapped) {
    blue <- grep("^blue_", names(row), value = TRUE)
    red <- sub("^blue_", "red_", blue)
    temporary <- row[blue]
    row[blue] <- row[red]
    row[red] <- temporary
  }
  row
}

test_that("synthetic Pinnacle features do not depend on side assignment", {
  first <- build_synthetic_pinnacle_features(synthetic_row())
  second <- build_synthetic_pinnacle_features(synthetic_row(TRUE))
  expect_equal(first, second)
})

test_that("synthetic Pinnacle features contain no market input", {
  features <- build_synthetic_pinnacle_features(synthetic_row())
  expect_false(any(grepl("odds|moneyline|soft|blue|red", names(features))))
  expect_true(all(is.finite(as.matrix(features))))
})

test_that("direct synthetic Pinnacle bundle predicts line and prices", {
  path <- testthat::test_path(
    "..", "..", "app_data", "synthetic_pinnacle_bundle.json"
  )
  skip_if_not(file.exists(path))
  bundle <- jsonlite::read_json(path, simplifyVector = TRUE)
  expect_identical(bundle$target_mode, "direct_line_price")
  expect_identical(bundle$selected_feature_family, "structural_without_roster")
  expect_identical(
    bundle$roster_challenger_status,
    "rejected_on_confirmation_line_mae"
  )
  expect_true(all(c("line_model", "price_model", "hold_model") %in% names(bundle)))
  expect_false(any(grepl(
    "moneyline|odds|soft|side|blue|red|draft",
    bundle$feature_names,
    ignore.case = TRUE
  )))
})
