test_that("portable inference returns a normalized half-line prediction", {
  taxonomy <- lapply(0:9, function(index) {
    list(
      tank = index == 0,
      fighter = index == 1,
      assassin = index == 2,
      mage = index %in% c(2, 3),
      marksman = index == 4,
      support = index == 5,
      attack = 0.5,
      defense = 0.5,
      magic = 0.5,
      difficulty = 0.5
    )
  })
  names(taxonomy) <- paste0("C", 0:9)
  positions <- c("top", "jng", "mid", "bot", "sup")
  bundle <- list(
    metadata = list(model_version = "test", data_cutoff = "2026-01-01"),
    model = list(
      theta = 10,
      league_levels = "LCK",
      feature_names = "pace",
      coefficients = list("(Intercept)" = log(25), pace = 0),
      scaling = list(pace = list(center = 0.8, scale = 0.1))
    ),
    teams = list(
      list(
        key = "name:blue",
        team_name = "Blue",
        effective_team_games = 5,
        hist_pace = 0.8
      ),
      list(
        key = "name:red",
        team_name = "Red",
        effective_team_games = 5,
        hist_pace = 0.8
      )
    ),
    taxonomy = taxonomy,
    champion_samples = as.list(stats::setNames(rep(10, 10), paste0("C", 0:9))),
    sample_limits = list(
      team_effective_games = 1,
      champion_effective_games = 1
    )
  )
  make_side <- function(side, offset) {
    list(
      team_name = tools::toTitleCase(side),
      champions = lapply(seq_along(positions), function(index) {
        list(
          position = positions[[index]],
          champion = paste0("C", offset + index - 1L)
        )
      })
    )
  }
  request <- list(
    league = "LCK",
    planned_at = "2026-08-01T12:00:00+00:00",
    map_number = 1,
    line = 24.5,
    blue = make_side("blue", 0),
    red = make_side("red", 5)
  )

  result <- predict_portable_request(request, bundle)

  expect_equal(result$status, "ok")
  expect_equal(result$mean, 25, tolerance = 1e-10)
  expect_equal(
    result$probability_over + result$probability_under,
    1,
    tolerance = 1e-12
  )
  expect_equal(result$probability_push, 0)
})

test_that("pace-only portable inference does not require a draft", {
  bundle <- list(
    metadata = list(model_version = "test", data_cutoff = "2026-01-01"),
    model = list(
      theta = 10,
      league_levels = "LCK",
      feature_names = "pace",
      coefficients = list("(Intercept)" = log(25), pace = 0),
      scaling = list(pace = list(center = 0.8, scale = 0.1))
    ),
    teams = list(
      list(
        key = "name:blue",
        team_name = "Blue",
        effective_team_games = 5,
        hist_pace = 0.8
      ),
      list(
        key = "name:red",
        team_name = "Red",
        effective_team_games = 5,
        hist_pace = 0.8
      )
    ),
    taxonomy = list(),
    champion_samples = list(),
    sample_limits = list(
      team_effective_games = 1,
      champion_effective_games = 1
    )
  )
  request <- list(
    league = "LCK",
    planned_at = "2026-08-01T12:00:00+00:00",
    map_number = 1,
    line = 24.5,
    blue = list(team_name = "Blue"),
    red = list(team_name = "Red")
  )

  result <- predict_portable_request(request, bundle)

  expect_equal(result$status, "ok")
  expect_equal(result$features$pace, 0.8)
})
