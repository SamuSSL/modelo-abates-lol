script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(file.path(project_root, "config", "default.yml"))
evaluation <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation$joint_team_monte_carlo_round
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "kill_market_map_features.rds"
))

parse_datetime <- function(value) {
  as.POSIXct(as.character(value), tz = "UTC")
}
folds <- do.call(rbind, lapply(
  evaluation[[round_config$fold_set]]$folds,
  function(fold) {
    data.frame(
      fold_id = fold$id,
      validation_start = parse_datetime(fold$validation_start),
      validation_end = parse_datetime(fold$validation_end),
      stringsAsFactors = FALSE
    )
  }
))
development_start <- parse_datetime(round_config$development_start)
development_end <- parse_datetime(round_config$development_end)
team_features <- as.character(unlist(round_config$team_features))
duration_features <- as.character(unlist(round_config$duration_features))
directed_names <- names(build_directed_team_maps(maps[1L, , drop = FALSE]))
missing_team <- setdiff(team_features, directed_names)
missing_duration <- setdiff(duration_features, names(maps))
if (length(missing_team) > 0L || length(missing_duration) > 0L) {
  stop(
    "Missing pre-registered joint features: ",
    paste(c(missing_team, missing_duration), collapse = ", "),
    call. = FALSE
  )
}

fit_period_model <- function(train, weights) {
  fit_joint_team_monte_carlo_model(
    train,
    team_feature_names = team_features,
    duration_feature_names = duration_features,
    weights = weights,
    alpha = round_config$regularization_alpha,
    inner_fraction =
      round_config$inner_temporal_validation_fraction,
    include_team_effects =
      round_config$include_team_and_opponent_effects,
    copula_shrinkage = round_config$copula_shrinkage
  )
}

temporal_weights <- function(data, cutoff) {
  age_days <- as.numeric(difftime(
    cutoff,
    data$series_cutoff,
    units = "days"
  ))
  0.5^(pmax(age_days, 0) /
    round_config$observation_half_life_days)
}

score_predictions <- function(
  validation,
  predictions,
  candidate_id,
  fold,
  training_games,
  effective_training_games
) {
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    scored <- .score_count_map(
      validation[index, , drop = FALSE],
      predictions[[index]],
      candidate_id,
      if (grepl("^historical", candidate_id)) {
        "historical_monte_carlo"
      } else {
        "joint_negative_binomial"
      },
      "team_intensity_duration_dependency",
      fold,
      training_games,
      effective_training_games
    )
    scored$pmf <- I(list(predictions[[index]]$pmf))
    scored$blue_prediction_mean <- predictions[[index]]$blue_mean
    scored$red_prediction_mean <- predictions[[index]]$red_mean
    scored$duration_prediction_mean <-
      predictions[[index]]$duration_mean
    scored
  })
  do.call(rbind, rows)
}

blend_prediction_sets <- function(parametric, historical, weight) {
  lapply(seq_along(parametric), function(index) {
    pmf <- blend_predictive_pmfs(
      parametric[[index]]$pmf,
      historical[[index]]$pmf,
      weight
    )
    support <- seq.int(0L, length(pmf) - 1L)
    result <- historical[[index]]
    result$pmf <- pmf
    result$mean <- sum(support * pmf)
    result$method <- paste0(
      "hybrid_",
      historical[[index]]$method,
      "_",
      format(weight, trim = TRUE)
    )
    result
  })
}

select_inner_maps <- function(data, maximum) {
  if (nrow(data) <= maximum) {
    return(data)
  }
  leagues <- split(seq_len(nrow(data)), data$league_canonical)
  selected <- unique(unlist(lapply(leagues, function(index) {
    size <- max(1L, round(maximum * length(index) / nrow(data)))
    index[unique(round(seq(1, length(index), length.out = size)))]
  })))
  data[head(selected, maximum), , drop = FALSE]
}

make_inner_bank <- function(train, weights) {
  ordered_cutoffs <- sort(unique(as.numeric(train$series_cutoff)))
  first_index <- max(
    2L,
    floor(length(ordered_cutoffs) *
      (1 - round_config$historical_bank_fraction -
        round_config$historical_selection_fraction))
  )
  second_index <- max(
    first_index + 1L,
    floor(length(ordered_cutoffs) *
      (1 - round_config$historical_selection_fraction))
  )
  core_cutoff <- as.POSIXct(
    ordered_cutoffs[[first_index]],
    origin = "1970-01-01",
    tz = "UTC"
  )
  selection_cutoff <- as.POSIXct(
    ordered_cutoffs[[second_index]],
    origin = "1970-01-01",
    tz = "UTC"
  )
  core <- train[train$series_cutoff < core_cutoff, , drop = FALSE]
  source <- train[
    train$game_datetime > core_cutoff &
      train$game_datetime < selection_cutoff,
    ,
    drop = FALSE
  ]
  selection <- train[
    train$game_datetime > selection_cutoff,
    ,
    drop = FALSE
  ]
  if (nrow(core) < 500L || nrow(source) < 100L || nrow(selection) < 50L) {
    stop("Inner historical periods are too small.", call. = FALSE)
  }
  core_weights <- weights[match(core$gameid, train$gameid)]
  core_fit <- fit_period_model(core, core_weights)
  source_rows <- build_historical_prediction_rows(
    core_fit,
    source,
    core_cutoff
  )
  bank <- fit_historical_monte_carlo_bank(source_rows)
  list(
    fit = core_fit,
    bank = bank,
    source_rows = source_rows,
    selection = select_inner_maps(
      selection,
      as.integer(round_config$maximum_inner_selection_maps)
    ),
    core_cutoff = core_cutoff
  )
}

select_historical_configuration <- function(inner) {
  selection <- inner$selection
  parametric <- predict_joint_team_monte_carlo_model(
    inner$fit,
    selection,
    method = "coherent_total",
    draws = as.integer(round_config$inner_monte_carlo_draws),
    seed = 20260728L
  )
  methods <- as.character(unlist(round_config$historical_candidates))
  neighbor_grid <- as.integer(unlist(round_config$historical_neighbors))
  half_life_grid <- as.numeric(unlist(
    round_config$historical_half_life_days
  ))
  weight_grid <- as.numeric(unlist(round_config$historical_weight_grid))
  rows <- list()
  predictions <- list()
  index <- 0L
  for (method in methods) {
    method_neighbors <- if (method == "pure") 250L else neighbor_grid
    for (neighbors in method_neighbors) {
      for (half_life in half_life_grid) {
        historical <- predict_historical_monte_carlo_model(
          inner$fit,
          inner$bank,
          selection,
          method = method,
          draws = as.integer(round_config$inner_monte_carlo_draws),
          seed = 20260728L,
          neighbors = neighbors,
          half_life_days = half_life
        )
        for (weight in weight_grid) {
          hybrid <- blend_prediction_sets(
            parametric,
            historical,
            weight
          )
          crps <- vapply(seq_len(nrow(selection)), function(row) {
            discrete_crps(
              hybrid[[row]]$pmf,
              as.integer(selection$total_kills_game[[row]])
            )
          }, numeric(1L))
          index <- index + 1L
          rows[[index]] <- data.frame(
            method = method,
            neighbors = as.integer(neighbors),
            half_life_days = half_life,
            historical_weight = weight,
            mean_crps = mean(crps),
            stringsAsFactors = FALSE
          )
        }
      }
    }
  }
  table <- do.call(rbind, rows)
  selected <- do.call(rbind, lapply(split(table, table$method), function(data) {
    data[which.min(data$mean_crps), , drop = FALSE]
  }))
  rownames(selected) <- NULL
  list(table = table, selected = selected)
}

development_batches <- list()
selection_batches <- list()
dependency_rows <- list()
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  train <- maps[
    maps$series_cutoff >= development_start &
      maps$series_cutoff < fold$validation_start[[1L]],
    ,
    drop = FALSE
  ]
  validation <- maps[
    maps$game_datetime >= fold$validation_start[[1L]] &
      maps$game_datetime < fold$validation_end[[1L]] &
      maps$game_datetime < development_end,
    ,
    drop = FALSE
  ]
  weights <- temporal_weights(train, fold$validation_start[[1L]])
  inner <- make_inner_bank(train, weights)
  selection <- select_historical_configuration(inner)
  selection$selected$fold_id <- fold$fold_id[[1L]]
  selection_batches[[fold_index]] <- selection$selected
  selection_rows <- build_historical_prediction_rows(
    inner$fit,
    train[train$game_datetime > max(
      inner$source_rows$game_datetime
    ), , drop = FALSE],
    inner$core_cutoff
  )
  full_bank <- fit_historical_monte_carlo_bank(rbind(
    inner$source_rows,
    selection_rows
  ))
  fit <- fit_period_model(train, weights)
  predictions <- list()
  for (method in as.character(unlist(
    round_config$parametric_candidates
  ))) {
    predictions[[method]] <- predict_joint_team_monte_carlo_model(
      fit,
      validation,
      method = method,
      draws = as.integer(round_config$monte_carlo_draws),
      seed = 20260728L + fold_index
    )
  }
  for (row_index in seq_len(nrow(selection$selected))) {
    selected <- selection$selected[row_index, , drop = FALSE]
    historical <- predict_historical_monte_carlo_model(
      fit,
      full_bank,
      validation,
      method = selected$method,
      draws = as.integer(round_config$monte_carlo_draws),
      seed = 20260828L + fold_index,
      neighbors = selected$neighbors,
      half_life_days = selected$half_life_days
    )
    historical_id <- paste0("historical_", selected$method)
    predictions[[historical_id]] <- historical
    hybrid_id <- paste0("hybrid_", selected$method)
    predictions[[hybrid_id]] <- blend_prediction_sets(
      predictions$coherent_total,
      historical,
      selected$historical_weight
    )
  }
  development_batches[[fold_index]] <- do.call(rbind, lapply(
    names(predictions),
    function(candidate_id) {
      score_predictions(
        validation,
        predictions[[candidate_id]],
        candidate_id,
        fold,
        nrow(train),
        sum(weights)
      )
    }
  ))
  dependency_rows[[fold_index]] <- data.frame(
    fold_id = fold$fold_id[[1L]],
    training_maps = nrow(train),
    raw_copula_correlation = fit$raw_copula_correlation,
    shrunken_copula_correlation = fit$copula_correlation,
    blue_theta = fit$team$theta_by_side[["Blue"]],
    red_theta = fit$team$theta_by_side[["Red"]],
    total_theta = fit$total_theta,
    beta_concentration = fit$beta_concentration,
    stringsAsFactors = FALSE
  )
  cat(
    "Fold conjunto concluido:",
    fold$fold_id[[1L]],
    "com",
    nrow(validation),
    "mapas.\n"
  )
}

new_metrics <- do.call(rbind, development_batches)
selection_table <- do.call(rbind, selection_batches)
dependency <- do.call(rbind, dependency_rows)
reference <- readRDS(file.path(
  artifact_dir,
  "all_development_model_metrics.rds"
))
reference <- reference[
  reference$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
all_columns <- union(names(reference), names(new_metrics))
fill_columns <- function(data) {
  for (column in setdiff(all_columns, names(data))) {
    data[[column]] <- NA
  }
  data[all_columns]
}
comparison <- rbind(fill_columns(reference), fill_columns(new_metrics))
summary <- .summarize_simple_metrics(
  comparison,
  c("candidate_id", "distribution", "feature_block")
)
by_fold <- .summarize_simple_metrics(
  comparison,
  c("candidate_id", "fold_id")
)
by_league <- .summarize_simple_metrics(
  comparison,
  c("candidate_id", "league_canonical")
)
lines <- evaluate_line_probabilities(
  comparison,
  as.numeric(unlist(round_config$line_grid))
)$summary
bootstrap <- do.call(rbind, lapply(
  unique(new_metrics$candidate_id),
  function(candidate_id) {
    paired_block_bootstrap_crps(
      comparison,
      candidate_id,
      "nb_v1_rebuilt",
      replicates = 2000L,
      seed = 20260728L
    )
  }
))

saveRDS(
  new_metrics,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_development_metrics.rds"
  ),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_development_summary.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  by_fold,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_development_by_fold.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_development_by_league.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  lines,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_development_lines.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_development_bootstrap.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  selection_table,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_inner_selection.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  dependency,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_dependency.csv"
  ),
  row.names = FALSE
)
print(summary[order(summary$mean_crps), ], row.names = FALSE)
