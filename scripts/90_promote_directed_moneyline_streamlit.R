script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

evaluation <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation$directed_moneyline_joint_round
model_selection <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "model-selection.yml"
))
interim_dir <- file.path(project_root, "data", "interim")
all_maps <- readRDS(file.path(
  interim_dir,
  "premap_ratio_map_features_t15.rds"
))
moneyline_maps <- readRDS(file.path(
  interim_dir,
  "premap_direct_moneyline_map_features.rds"
))
team_metrics <- readRDS(file.path(interim_dir, "team_map_metrics.rds"))
current_bundle_path <- file.path(
  project_root,
  "app_data",
  "model_bundle.json"
)
current_bundle <- jsonlite::fromJSON(
  current_bundle_path,
  simplifyVector = TRUE
)

team_metrics$game_datetime <- as.POSIXct(
  team_metrics$game_datetime,
  tz = "UTC"
)
result_available_at <- team_metrics$game_datetime +
  as.numeric(team_metrics$game_length_minutes) * 60 +
  evaluation$premap_multiplicative_round$result_lag_minutes * 60
deployment_cutoff <- max(result_available_at, na.rm = TRUE) + 1

training <- all_maps[
  all_maps$game_datetime < deployment_cutoff,
  ,
  drop = FALSE
]
training_age_days <- as.numeric(difftime(
  deployment_cutoff,
  training$game_datetime,
  units = "days"
))
training_weights <- 0.5^(
  training_age_days /
    evaluation$premap_multiplicative_round$
      observation_half_life_days
)
fundamental <- fit_directed_joint_fundamental(
  training,
  windows = c("season", "last15"),
  alpha = round_config$regularization_alpha,
  weights = training_weights,
  inner_fraction = round_config$inner_temporal_validation_fraction,
  dispersion_mode = "global",
  seed = round_config$prediction_seed
)

market_training <- moneyline_maps[
  moneyline_maps$game_datetime < deployment_cutoff &
    is.finite(moneyline_maps$p_blue) &
    is.finite(moneyline_maps$p_red) &
    moneyline_maps$p_blue > 0 &
    moneyline_maps$p_blue < 1 &
    moneyline_maps$p_red > 0 &
    moneyline_maps$p_red < 1,
  ,
  drop = FALSE
]
market_age_days <- as.numeric(difftime(
  deployment_cutoff,
  market_training$game_datetime,
  units = "days"
))
market_weights <- 0.5^(
  market_age_days /
    evaluation$premap_multiplicative_round$
      observation_half_life_days
)
fit <- fit_moneyline_joint_correction(
  fundamental,
  market_training,
  shape = "quadratic",
  interactions = FALSE,
  dispersion_mode = "global",
  weights = market_weights,
  seed = round_config$prediction_seed
)

history <- team_metrics[
  team_metrics$competition_role == "target" &
    !is.na(team_metrics$team_id) &
    nzchar(as.character(team_metrics$team_id)),
  ,
  drop = FALSE
]
history_key <- paste(
  history$league_canonical,
  history$team_id,
  sep = "\u001f"
)
latest_order <- order(
  history_key,
  history$game_datetime,
  decreasing = TRUE
)
latest <- history[latest_order, , drop = FALSE]
latest_key <- paste(
  latest$league_canonical,
  latest$team_id,
  sep = "\u001f"
)
latest <- latest[!duplicated(latest_key), , drop = FALSE]
latest <- latest[
  latest$game_datetime >= deployment_cutoff - 365 * 86400,
  ,
  drop = FALSE
]
synthetic <- latest
synthetic$gameid <- paste0(
  "operational_snapshot_",
  seq_len(nrow(synthetic))
)
synthetic$competition_role <- "operational_snapshot"
synthetic$game_datetime <- deployment_cutoff
synthetic$series_cutoff <- deployment_cutoff
synthetic$map_number <- 1L
synthetic$side <- "Blue"
synthetic$opponent_id <- "__operational_opponent__"
synthetic$opponent_name <- "Operational opponent"
synthetic$series_id <- synthetic$gameid
synthetic$game_length_minutes <- ave(
  history$game_length_minutes,
  history$league_canonical,
  FUN = function(value) stats::median(value, na.rm = TRUE)
)[match(
  synthetic$league_canonical,
  history$league_canonical
)]
synthetic$game_length_minutes[
  !is.finite(synthetic$game_length_minutes) |
    synthetic$game_length_minutes <= 0
] <- stats::median(history$game_length_minutes, na.rm = TRUE)
synthetic$team_kills <- 0
synthetic$team_deaths <- 0

snapshot_rows <- build_premap_ratio_features(
  rbind(team_metrics, synthetic),
  cutoff_mode = "map",
  prediction_lead_minutes = 0,
  result_lag_minutes = evaluation$premap_multiplicative_round$
    result_lag_minutes,
  prior_games = evaluation$premap_multiplicative_round$
    rating_prior_games,
  history_roles = "target",
  prediction_roles = "operational_snapshot"
)
snapshot_rows <- snapshot_rows[
  grepl("^operational_snapshot_", snapshot_rows$gameid),
  ,
  drop = FALSE
]

pace_snapshot <- build_team_feature_snapshot(
  history,
  metric_names = "combined_kills_per_minute",
  snapshot_cutoff = deployment_cutoff,
  half_life_days = evaluation$approved_recency$half_life_days,
  prior_games = evaluation$team_feature_research$default_prior_games
)
portable_team_key <- function(team_id, team_name) {
  ifelse(
    !is.na(team_id) & nzchar(as.character(team_id)),
    paste0("id:", as.character(team_id)),
    paste0("name:", tolower(trimws(as.character(team_name))))
  )
}
pace_snapshot_key <- portable_team_key(
  pace_snapshot$team_id,
  pace_snapshot$team_name
)

old_teams <- current_bundle$teams
old_by_id <- setNames(
  seq_len(nrow(old_teams)),
  paste(old_teams$league_canonical, old_teams$team_id, sep = "\u001f")
)
old_by_name <- setNames(
  seq_len(nrow(old_teams)),
  paste(
    old_teams$league_canonical,
    tolower(trimws(old_teams$team_name)),
    sep = "\u001f"
  )
)

portable_coefficients <- function(model, lambda = NULL) {
  matrix <- if (is.null(lambda)) {
    as.matrix(stats::coef(model))
  } else {
    as.matrix(stats::coef(model, s = lambda))
  }
  values <- as.numeric(matrix[, 1L])
  names(values) <- rownames(matrix)
  as.list(values)
}

team_rows <- lapply(seq_len(nrow(snapshot_rows)), function(index) {
  row <- snapshot_rows[index, , drop = FALSE]
  id_key <- paste(
    row$league_canonical,
    row$team_id,
    sep = "\u001f"
  )
  name_key <- paste(
    row$league_canonical,
    tolower(trimws(row$team_name)),
    sep = "\u001f"
  )
  old_index <- unname(old_by_id[id_key])
  if (is.null(old_index) || is.na(old_index)) {
    old_index <- unname(old_by_name[name_key])
  }
  old <- if (!is.null(old_index) && !is.na(old_index)) {
    old_teams[old_index, , drop = FALSE]
  } else {
    NULL
  }
  fresh_pace_index <- match(
    portable_team_key(row$team_id, row$team_name),
    pace_snapshot_key
  )
  metric_columns <- grep(
    "^(season|last15)_",
    names(row),
    value = TRUE
  )
  metrics <- lapply(metric_columns, function(column) {
    as.numeric(row[[column]])
  })
  names(metrics) <- metric_columns
  team_id <- as.character(row$team_id)
  team_name <- as.character(row$team_name)
  list(
    key = if (nzchar(team_id)) {
      paste0("id:", team_id)
    } else {
      paste0("name:", tolower(trimws(team_name)))
    },
    team_id = if (nzchar(team_id)) team_id else NULL,
    team_name = team_name,
    latest_team_name = team_name,
    league_canonical = as.character(row$league_canonical),
    last_game_datetime = format(
      latest$game_datetime[match(
        paste(row$league_canonical, row$team_id, sep = "\u001f"),
        paste(latest$league_canonical, latest$team_id, sep = "\u001f")
      )],
      tz = "UTC",
      usetz = TRUE
    ),
    effective_team_games = if (!is.na(fresh_pace_index)) {
      as.numeric(
        pace_snapshot$effective_combined_kills_per_minute_games[
          fresh_pace_index
        ]
      )
    } else if (!is.null(old)) {
      as.numeric(old$effective_team_games)
    } else {
      as.numeric(row$last15_team_games)
    },
    hist_pace = if (!is.na(fresh_pace_index)) {
      as.numeric(
        pace_snapshot$hist_combined_kills_per_minute[
          fresh_pace_index
        ]
      )
    } else if (!is.null(old)) {
      as.numeric(old$hist_pace)
    } else {
      mean(c(
        as.numeric(row$last15_kpm_ratio),
        as.numeric(row$last15_dpm_ratio)
      ))
    },
    ratings = metrics
  )
})

duration_model <- fit$fundamental$duration
intensity_model <- fit$fundamental$intensity
model_hash <- substr(
  digest::digest(
    list(
      portable_coefficients(
        duration_model$model,
        duration_model$lambda
      ),
      portable_coefficients(
        intensity_model$model,
        intensity_model$lambda
      ),
      stats::coef(fit$intensity_correction),
      fit$duration_correction$coefficients,
      fit$dispersion$global_theta,
      deployment_cutoff,
      "joint_ml_quadratic_global"
    ),
    algo = "sha256"
  ),
  1L,
  12L
)

bundle <- list(
  metadata = list(
    model_version = paste0("directed-ml-", model_hash),
    selected_candidate_id = "joint_ml_quadratic_global",
    model_status = "historical_validation_only",
    data_cutoff = format(
      deployment_cutoff,
      tz = "UTC",
      usetz = TRUE
    ),
    bundle_refreshed_at = format(
      Sys.time(),
      format = "%Y-%m-%dT%H:%M:%SZ",
      tz = "UTC",
      usetz = FALSE
    ),
    training_maps = fit$fundamental$training_maps,
    moneyline_training_maps = fit$training_maps,
    moneyline_snapshot = "T-15 a T-30 do mapa",
    backtest_maps = 153L,
    backtest_brier = 0.2769,
    backtest_line_log_loss = 0.7542,
    backtest_yield = -0.0954,
    backtest_context = paste(
      "confirmacao historica de junho-julho de 2026;",
      "EV minimo de 10% contra odds live Pinnacle;",
      "nao representa execucao em casa soft"
    ),
    prospective_test = FALSE
  ),
  model = list(
    type = "directed_moneyline",
    distribution = "lognormal_duration_negative_binomial_total",
    windows = as.list(as.character(fit$fundamental$windows)),
    league_levels = as.list(
      as.character(duration_model$league_levels)
    ),
    duration = list(
      feature_names = as.list(
        as.character(duration_model$feature_names)
      ),
      x_columns = as.list(
        as.character(duration_model$x_columns)
      ),
      coefficients = portable_coefficients(
        duration_model$model,
        duration_model$lambda
      ),
      residual_sd_log = as.numeric(
        duration_model$residual_sd_log
      )
    ),
    intensity = list(
      feature_names = as.list(
        as.character(intensity_model$feature_names)
      ),
      x_columns = as.list(
        as.character(intensity_model$x_columns)
      ),
      coefficients = portable_coefficients(
        intensity_model$model,
        intensity_model$lambda
      )
    ),
    moneyline = list(
      shape = fit$shape,
      interactions = fit$interactions,
      duration_coefficients = as.list(
        fit$duration_correction$coefficients
      ),
      intensity_coefficients = as.list(
        stats::coef(fit$intensity_correction)
      )
    ),
    theta = as.numeric(fit$dispersion$global_theta),
    allocation_concentration = as.numeric(
      fit$allocation_concentration
    ),
    quadrature_nodes = 32L
  ),
  fallback_model = if (
    identical(current_bundle$model$type, "directed_moneyline")
  ) {
    current_bundle$fallback_model
  } else {
    current_bundle$model
  },
  teams = team_rows,
  taxonomy = list(),
  champion_samples = list(),
  sample_limits = model_selection$sample_limits
)
write_portable_model_bundle(bundle, current_bundle_path)

fixture_candidates <- snapshot_rows[
  snapshot_rows$league_canonical == "LCK",
  ,
  drop = FALSE
]
if (nrow(fixture_candidates) < 2L) {
  fixture_candidates <- snapshot_rows[
    snapshot_rows$league_canonical ==
      snapshot_rows$league_canonical[[1L]],
    ,
    drop = FALSE
  ]
}
blue_fixture <- fixture_candidates[1L, , drop = FALSE]
red_fixture <- fixture_candidates[2L, , drop = FALSE]
fixture_map <- data.frame(
  gameid = "portable_directed_moneyline_parity",
  game_datetime = deployment_cutoff,
  league_canonical = as.character(
    blue_fixture$league_canonical
  ),
  map_number = 1L,
  pace = mean(c(
    bundle$teams[[match(
      as.character(blue_fixture$team_id),
      vapply(bundle$teams, function(team) {
        as.character(team$team_id)
      }, character(1L))
    )]]$hist_pace,
    bundle$teams[[match(
      as.character(red_fixture$team_id),
      vapply(bundle$teams, function(team) {
        as.character(team$team_id)
      }, character(1L))
    )]]$hist_pace
  )),
  blue_team_kills = 0,
  red_team_kills = 0,
  total_kills_game = 0,
  game_length_minutes = 30,
  stringsAsFactors = FALSE
)
fixture_metric_columns <- grep(
  "^(season|last15)_",
  names(snapshot_rows),
  value = TRUE
)
for (column in fixture_metric_columns) {
  fixture_map[[paste0("blue_", column)]] <- as.numeric(
    blue_fixture[[column]]
  )
  fixture_map[[paste0("red_", column)]] <- as.numeric(
    red_fixture[[column]]
  )
}
fixture_map <- derive_multiplicative_expectations(
  fixture_map,
  fit$fundamental$windows
)
fixture_map$p_blue <- 0.65
fixture_map$p_red <- 0.35
fixture_map$favorite_imbalance <- abs(stats::qlogis(
  fixture_map$p_blue
))
fixture_prediction <- predict_moneyline_joint_model(
  fit,
  fixture_map,
  draws = 100000L,
  seed = round_config$prediction_seed
)[[1L]]
fixture_line <- 24.5
fixture_under <- sum(
  fixture_prediction$pmf[
    seq_len(floor(fixture_line) + 1L)
  ]
)
fixture <- list(
  request = list(
    league = as.character(fixture_map$league_canonical),
    planned_at = "2026-08-01T12:00:00+00:00",
    map_number = 1L,
    line = fixture_line,
    moneyline_blue_odds = 1 / fixture_map$p_blue,
    moneyline_red_odds = 1 / fixture_map$p_red,
    blue = list(
      team_name = as.character(blue_fixture$team_name),
      team_id = as.character(blue_fixture$team_id)
    ),
    red = list(
      team_name = as.character(red_fixture$team_name),
      team_id = as.character(red_fixture$team_id)
    )
  ),
  expected = list(
    mean = fixture_prediction$mean,
    duration_mean = fixture_prediction$duration_mean,
    blue_mean = fixture_prediction$blue_mean,
    red_mean = fixture_prediction$red_mean,
    probability_under = fixture_under,
    probability_over = 1 - fixture_under
  ),
  tolerance = list(
    mean = 0.08,
    duration_mean = 0.08,
    team_mean = 0.08,
    probability = 0.003
  )
)
jsonlite::write_json(
  fixture,
  file.path(project_root, "app_data", "parity_fixture.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  digits = NA
)

cat(
  "Modelo dirigido + moneyline promovido para teste.\n",
  "Bundle:", normalizePath(current_bundle_path, winslash = "/"), "\n",
  "Versao:", bundle$metadata$model_version, "\n",
  "Cutoff:", bundle$metadata$data_cutoff, "\n",
  "Mapas fundamentais:", bundle$metadata$training_maps, "\n",
  "Mapas com moneyline:", bundle$metadata$moneyline_training_maps, "\n",
  "Equipes no snapshot:", length(bundle$teams), "\n"
)
