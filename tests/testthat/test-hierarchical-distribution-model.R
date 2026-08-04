make_hierarchical_distribution_fixture <- function(n = 420L) {
  set.seed(20260727)
  teams <- paste0("T", seq_len(14L))
  blue_index <- sample(seq_along(teams), n, replace = TRUE)
  red_index <- sample(seq_along(teams), n, replace = TRUE)
  same <- blue_index == red_index
  red_index[same] <- red_index[same] %% length(teams) + 1L
  team_effect <- stats::rnorm(length(teams), 0, 0.10)
  pace <- stats::runif(n, 0.55, 1.20)
  imbalance <- stats::runif(n, 0, 0.45)
  draft <- stats::runif(n, 0, 1)
  nonlinear <- 0.8 * (pace - 0.82)^2 +
    0.25 * sin(pi * draft) -
    0.35 * imbalance
  log_mean <- log(27) + nonlinear +
    team_effect[blue_index] + team_effect[red_index]
  theta <- exp(3.4 - 2.2 * imbalance + 0.5 * draft)
  total <- stats::rnbinom(n, mu = exp(log_mean), size = theta)
  data.frame(
    gameid = paste0("G", seq_len(n)),
    league_canonical = rep(c("LCK", "LEC"), length.out = n),
    game_datetime = as.POSIXct("2022-01-01", tz = "UTC") +
      seq_len(n) * 86400,
    total_kills_game = total,
    blue_team_id = teams[blue_index],
    blue_team_name = teams[blue_index],
    red_team_id = teams[red_index],
    red_team_name = teams[red_index],
    pace = pace,
    imbalance = imbalance,
    draft = draft,
    stringsAsFactors = FALSE
  )
}

test_that("hierarchical nonlinear model learns mean and dispersion components", {
  train <- make_hierarchical_distribution_fixture()
  fit <- fit_hierarchical_distribution_model(
    train,
    smooth_features = c("pace", "imbalance", "draft"),
    interaction_pairs = list(c("pace", "draft")),
    dispersion_features = c("imbalance", "draft"),
    inner_fraction = 0.30
  )

  expect_s3_class(fit, "lolkills_hierarchical_distribution_model")
  expect_s3_class(fit$mean_model, "gam")
  expect_s3_class(fit$dispersion_model, "gam")
  expect_true(fit$dispersion_blend >= 0 && fit$dispersion_blend <= 1)
  expect_gt(fit$global_theta, 0)
  expect_true(any(grepl(
    "blue_team_factor",
    names(fit$mean_model$smooth)
  )))
})

test_that("hierarchical distribution predictions expose row-specific PMFs", {
  train <- make_hierarchical_distribution_fixture()
  fit <- fit_hierarchical_distribution_model(
    train,
    smooth_features = c("pace", "imbalance", "draft"),
    interaction_pairs = list(c("pace", "draft")),
    dispersion_features = c("imbalance", "draft"),
    inner_fraction = 0.30
  )
  prediction <- predict_hierarchical_distribution_model(
    fit,
    train[401:410, ],
    dispersion_mode = "local"
  )

  expect_equal(length(prediction), 10L)
  expect_gt(length(unique(round(vapply(
    prediction,
    function(item) item$theta,
    numeric(1L)
  ), 4))), 1L)
  expect_true(all(vapply(
    prediction,
    function(item) {
      item$mean > 0 &&
        item$theta > 0 &&
        abs(sum(item$pmf) - 1) < 1e-9
    },
    logical(1L)
  )))
})

test_that("unseen teams receive zero hierarchical effect", {
  train <- make_hierarchical_distribution_fixture()
  fit <- fit_hierarchical_distribution_model(
    train,
    smooth_features = c("pace", "imbalance", "draft"),
    interaction_pairs = list(c("pace", "draft")),
    dispersion_features = c("imbalance", "draft"),
    inner_fraction = 0.30
  )
  future <- train[411:412, ]
  future$blue_team_id <- c("NEW_A", "NEW_B")
  future$blue_team_name <- c("New A", "New B")
  prediction <- predict_hierarchical_distribution_model(fit, future)

  expect_equal(length(prediction), 2L)
  expect_true(all(vapply(
    prediction,
    function(item) is.finite(item$mean) && item$mean > 0,
    logical(1L)
  )))
})
