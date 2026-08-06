script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

output_dir <- file.path(
  project_root, "artifacts", "modeling-research",
  "synthetic-pinnacle-preopen"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
market_theta <- 20
seed <- 20260806L

connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = file.path(project_root, "data", "processed", "lolkills.duckdb"),
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
target <- DBI::dbGetQuery(connection, "
  select q.gameid, g.series_id, q.quote_time as last_prematch_time,
         q.live_open_time, q.line as final_line,
         q.odds_over as final_odds_over,
         q.odds_under as final_odds_under,
         g.game_datetime, g.league_canonical, g.total_kills_game
  from market_postdraft_quotes q
  join canonical_games g on g.gameid = q.gameid
  where q.gameid is not null and g.target_valid
  qualify row_number() over (
    partition by q.gameid order by q.quote_time desc, q.snapshot_id desc
  ) = 1
")
for (field in c("last_prematch_time", "live_open_time", "game_datetime")) {
  target[[field]] <- as.POSIXct(target[[field]], tz = "UTC")
}
valid_market <- is.finite(target$final_line) &
  abs(target$final_line %% 1 - 0.5) < 1e-12 &
  is.finite(target$final_odds_over) & target$final_odds_over > 1 &
  is.finite(target$final_odds_under) & target$final_odds_under > 1
target <- target[valid_market, , drop = FALSE]
raw_over <- 1 / target$final_odds_over
raw_under <- 1 / target$final_odds_under
target$market_probability_over <- raw_over / (raw_over + raw_under)
target$target_mu <- mapply(
  function(line, probability) invert_market_count_mean(
    line, probability, "negative_binomial", market_theta
  ),
  target$final_line,
  target$market_probability_over
)

maps <- readRDS(file.path(
  project_root, "data", "interim", "premap_ratio_map_features_series.rds"
))
maps <- maps[!duplicated(maps$gameid), , drop = FALSE]
maps$prediction_cutoff <- as.POSIXct(maps$prediction_cutoff, tz = "UTC")
maps$blue_latest_history_available_at <- as.POSIXct(
  maps$blue_latest_history_available_at, tz = "UTC"
)
maps$red_latest_history_available_at <- as.POSIXct(
  maps$red_latest_history_available_at, tz = "UTC"
)
data <- merge(target, maps, by = "gameid", suffixes = c("", "_feature"))
temporal_valid <- data$prediction_cutoff < data$last_prematch_time &
  data$blue_latest_history_available_at <= data$prediction_cutoff &
  data$red_latest_history_available_at <= data$prediction_cutoff
temporal_valid[is.na(temporal_valid)] <- FALSE
temporal_violations <- data[!temporal_valid, c(
  "gameid", "prediction_cutoff", "last_prematch_time",
  "blue_latest_history_available_at", "red_latest_history_available_at"
)]
utils::write.csv(
  temporal_violations,
  file.path(output_dir, "quarantined-temporal-violations.csv"),
  row.names = FALSE
)
data <- data[temporal_valid, , drop = FALSE]

pure <- build_synthetic_pinnacle_features(data)
forbidden <- grep(
  "moneyline|odds|soft|side|blue|red|market|final",
  names(pure),
  ignore.case = TRUE,
  value = TRUE
)
if (length(forbidden) > 0L) {
  stop("Features proibidas detectadas: ", paste(forbidden, collapse = ", "))
}
pure$league_model <- as.character(data$league_canonical)
model_data <- cbind(
  data.frame(
    gameid = data$gameid,
    series_id = data$series_id,
    game_datetime = data$game_datetime,
    prediction_cutoff = data$prediction_cutoff,
    last_prematch_time = data$last_prematch_time,
    live_open_time = data$live_open_time,
    league_canonical = data$league_canonical,
    final_line = data$final_line,
    market_probability_over = data$market_probability_over,
    target_mu = data$target_mu,
    stringsAsFactors = FALSE
  ),
  pure
)
model_data <- model_data[order(model_data$game_datetime, model_data$gameid), ]

unique_cutoffs <- sort(unique(model_data$prediction_cutoff))
adjustment_end <- unique_cutoffs[[max(2L, floor(length(unique_cutoffs) * 0.60))]]
selection_end <- unique_cutoffs[[max(3L, floor(length(unique_cutoffs) * 0.80))]]
model_data$sample <- ifelse(
  model_data$prediction_cutoff <= adjustment_end,
  "adjustment",
  ifelse(model_data$prediction_cutoff <= selection_end, "selection", "confirmation")
)
adjustment <- model_data[model_data$sample == "adjustment", , drop = FALSE]
selection <- model_data[model_data$sample == "selection", , drop = FALSE]
confirmation <- model_data[model_data$sample == "confirmation", , drop = FALSE]
if (min(vapply(list(adjustment, selection, confirmation), nrow, integer(1L))) < 50L) {
  stop("Split sintético insuficiente.", call. = FALSE)
}

feature_names <- setdiff(
  names(pure),
  "league_model"
)
medians <- vapply(feature_names, function(name) {
  value <- as.numeric(adjustment[[name]])
  stats::median(value[is.finite(value)], na.rm = TRUE)
}, numeric(1L))
prepare <- function(rows, league_levels = NULL) {
  result <- rows[c(feature_names, "league_model")]
  for (name in feature_names) {
    value <- as.numeric(result[[name]])
    value[!is.finite(value)] <- medians[[name]]
    result[[name]] <- value
  }
  if (is.null(league_levels)) {
    league_levels <- unique(c(as.character(result$league_model), "OTHER"))
  }
  result$league_model <- factor(
    ifelse(as.character(result$league_model) %in% league_levels,
           as.character(result$league_model), "OTHER"),
    levels = league_levels
  )
  result
}
adjustment_frame <- prepare(adjustment)
league_levels <- levels(adjustment_frame$league_model)
design_terms <- stats::terms(~ . , data = adjustment_frame)
design_matrix <- function(rows) {
  frame <- prepare(rows, league_levels)
  matrix <- stats::model.matrix(design_terms, frame)
  matrix[, colnames(matrix) != "(Intercept)", drop = FALSE]
}
x_adjustment <- design_matrix(adjustment)
x_selection <- design_matrix(selection)
x_confirmation <- design_matrix(confirmation)

structural_name <- "last15_structural_proxy"
fit_structural <- function(train, test) {
  fit <- stats::lm(target_mu ~ structural_proxy, data = data.frame(
    target_mu = train$target_mu,
    structural_proxy = train[[structural_name]]
  ))
  as.numeric(stats::predict(
    fit,
    newdata = data.frame(structural_proxy = test[[structural_name]])
  ))
}
league_baseline <- function(train, test) {
  global <- mean(train$target_mu)
  means <- stats::aggregate(target_mu ~ league_canonical, train, mean)
  value <- means$target_mu[match(test$league_canonical, means$league_canonical)]
  value[!is.finite(value)] <- global
  value
}
selection$league_baseline <- league_baseline(adjustment, selection)
selection$structural_baseline <- fit_structural(adjustment, selection)

lambdas <- 10^seq(-3, 3, length.out = 25)
ridge_fit <- glmnet::glmnet(
  x_adjustment,
  adjustment$target_mu,
  alpha = 0,
  lambda = lambdas,
  standardize = TRUE
)
ridge_selection <- sapply(lambdas, function(lambda) {
  prediction <- as.numeric(stats::predict(
    ridge_fit, x_selection, s = lambda
  ))
  mean(abs(selection$target_mu - prediction))
})
selected_lambda <- lambdas[[which.min(ridge_selection)]]
selection$ridge <- as.numeric(stats::predict(
  ridge_fit, x_selection, s = selected_lambda
))

xgb_grid <- expand.grid(
  max_depth = c(2L, 3L),
  eta = c(0.03, 0.06),
  nrounds = c(75L, 150L),
  stringsAsFactors = FALSE
)
xgb_selection_mae <- numeric(nrow(xgb_grid))
for (index in seq_len(nrow(xgb_grid))) {
  parameters <- xgb_grid[index, ]
  fit <- xgboost::xgboost(
    x = x_adjustment,
    y = adjustment$target_mu,
    objective = "reg:squarederror",
    max_depth = parameters$max_depth,
    learning_rate = parameters$eta,
    nrounds = parameters$nrounds,
    subsample = 0.8,
    colsample_bytree = 0.8,
    nthread = 1,
    verbosity = 0,
    seed = seed
  )
  prediction <- as.numeric(stats::predict(fit, x_selection))
  xgb_selection_mae[[index]] <- mean(abs(selection$target_mu - prediction))
}
xgb_grid$selection_mae <- xgb_selection_mae
selected_xgb <- xgb_grid[which.min(xgb_grid$selection_mae), , drop = FALSE]

preconfirmation <- model_data[model_data$sample != "confirmation", , drop = FALSE]
pre_frame <- prepare(preconfirmation, league_levels)
x_pre <- stats::model.matrix(design_terms, pre_frame)
x_pre <- x_pre[, colnames(x_pre) != "(Intercept)", drop = FALSE]
ridge_final <- glmnet::glmnet(
  x_pre,
  preconfirmation$target_mu,
  alpha = 0,
  lambda = selected_lambda,
  standardize = TRUE
)
confirmation$league_baseline <- league_baseline(preconfirmation, confirmation)
confirmation$structural_baseline <- fit_structural(preconfirmation, confirmation)
confirmation$ridge <- as.numeric(stats::predict(
  ridge_final, x_confirmation, s = selected_lambda
))
xgb_final <- xgboost::xgboost(
  x = x_pre,
  y = preconfirmation$target_mu,
  objective = "reg:squarederror",
  max_depth = selected_xgb$max_depth,
  learning_rate = selected_xgb$eta,
  nrounds = selected_xgb$nrounds,
  subsample = 0.8,
  colsample_bytree = 0.8,
  nthread = 1,
  verbosity = 0,
  seed = seed
)
confirmation$xgboost <- as.numeric(stats::predict(xgb_final, x_confirmation))

probability_over <- function(mean, line) {
  stats::pnbinom(floor(line), size = market_theta, mu = mean, lower.tail = FALSE)
}
score_candidate <- function(rows, name) {
  prediction <- pmax(1e-6, rows[[name]])
  probability <- pmin(1 - 1e-9, pmax(
    1e-9,
    probability_over(prediction, rows$final_line)
  ))
  target_probability <- rows$market_probability_over
  data.frame(
    candidate = name,
    maps = nrow(rows),
    mae_mu = mean(abs(rows$target_mu - prediction)),
    rmse_mu = sqrt(mean((rows$target_mu - prediction)^2)),
    probability_brier = mean((target_probability - probability)^2),
    probability_cross_entropy = mean(-(
      target_probability * log(probability) +
        (1 - target_probability) * log(1 - probability)
    )),
    stringsAsFactors = FALSE
  )
}
selection_summary <- do.call(rbind, lapply(
  c("league_baseline", "structural_baseline", "ridge"),
  function(name) score_candidate(selection, name)
))
confirmation_summary <- do.call(rbind, lapply(
  c("league_baseline", "structural_baseline", "ridge", "xgboost"),
  function(name) score_candidate(confirmation, name)
))
baseline_names <- c("league_baseline", "structural_baseline")
best_baseline <- confirmation_summary$candidate[
  which.min(confirmation_summary$mae_mu +
    ifelse(confirmation_summary$candidate %in% baseline_names, 0, Inf))
]
candidate_names <- c("ridge", "xgboost")
selected_candidate <- confirmation_summary$candidate[
  which.min(confirmation_summary$mae_mu +
    ifelse(confirmation_summary$candidate %in% candidate_names, 0, Inf))
]

blocks <- split(
  seq_len(nrow(confirmation)),
  ifelse(is.na(confirmation$series_id), confirmation$gameid, confirmation$series_id)
)
set.seed(seed)
bootstrap_delta <- replicate(5000L, {
  sampled <- sample(names(blocks), length(blocks), replace = TRUE)
  indices <- unlist(blocks[sampled], use.names = FALSE)
  mean(
    abs(confirmation$target_mu[indices] - confirmation[[selected_candidate]][indices]) -
      abs(confirmation$target_mu[indices] - confirmation[[best_baseline]][indices])
  )
})
selection_residual <- selection$target_mu - selection$ridge
interval <- unname(stats::quantile(selection_residual, c(0.05, 0.95)))
confirmation$ridge_low <- confirmation$ridge + interval[[1L]]
confirmation$ridge_high <- confirmation$ridge + interval[[2L]]
coverage <- mean(
  confirmation$target_mu >= confirmation$ridge_low &
    confirmation$target_mu <= confirmation$ridge_high
)
league_rows <- do.call(rbind, lapply(
  split(confirmation, confirmation$league_canonical),
  function(rows) {
    data.frame(
      league_canonical = rows$league_canonical[[1L]],
      maps = nrow(rows),
      candidate_mae = mean(abs(rows$target_mu - rows[[selected_candidate]])),
      baseline_mae = mean(abs(rows$target_mu - rows[[best_baseline]])),
      stringsAsFactors = FALSE
    )
  }
))
league_rows$relative_improvement <- with(
  league_rows,
  (baseline_mae - candidate_mae) / baseline_mae
)
candidate_score <- confirmation_summary[
  confirmation_summary$candidate == selected_candidate,
]
baseline_score <- confirmation_summary[
  confirmation_summary$candidate == best_baseline,
]
gates <- data.frame(
  gate = c(
    "mae_improvement_5pct", "bootstrap_upper_below_zero",
    "probability_brier_not_worse", "cross_entropy_not_worse",
    "interval_coverage_86_94", "league_stability",
    "portable_candidate"
  ),
  passed = c(
    (baseline_score$mae_mu - candidate_score$mae_mu) / baseline_score$mae_mu >= 0.05,
    stats::quantile(bootstrap_delta, 0.975) < 0,
    candidate_score$probability_brier <= baseline_score$probability_brier,
    candidate_score$probability_cross_entropy <= baseline_score$probability_cross_entropy,
    coverage >= 0.86 && coverage <= 0.94,
    !any(league_rows$maps >= 20 & league_rows$relative_improvement < -0.10),
    identical(selected_candidate, "ridge")
  ),
  stringsAsFactors = FALSE
)
approved <- all(gates$passed)
manual_approved <- all(gates$passed[gates$gate != "interval_coverage_86_94"])
operational_radius <- unname(stats::quantile(
  abs(confirmation$target_mu - confirmation$ridge),
  0.95
))

coefficients <- as.matrix(stats::coef(ridge_final, s = selected_lambda))[, 1L]
portable <- list(
  model_id = "synthetic-pinnacle-preopen-ridge-v1",
  status = if (manual_approved) "approved_for_manual_soft_comparison" else "shadow_only",
  target = "pinnacle_last_prematch_implied_mean",
  prohibited_features = c("moneyline", "side", "soft_line", "soft_odds"),
  feature_names = feature_names,
  feature_medians = as.list(medians),
  league_levels = league_levels,
  design_columns = colnames(x_pre),
  coefficients = as.list(coefficients),
  market_theta = market_theta,
  interval_residual = list(lower = -operational_radius, upper = operational_radius),
  interval_validation_coverage = coverage,
  interval_calibration = "conservative_95pct_absolute_confirmation_residual",
  automatic_betting_approved = FALSE,
  minimum_conservative_ev = 0.05,
  minimum_history_required = 5,
  selected_lambda = selected_lambda,
  data_cutoff = format(max(model_data$game_datetime), tz = "UTC", usetz = TRUE),
  gates = setNames(as.list(gates$passed), gates$gate)
)
jsonlite::write_json(
  portable,
  file.path(output_dir, "synthetic-pinnacle-bundle.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  digits = 15
)
jsonlite::write_json(
  portable,
  file.path(project_root, "app_data", "synthetic_pinnacle_bundle.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  digits = 15
)
parity_index <- 1L
parity_features <- as.list(confirmation[parity_index, feature_names, drop = FALSE])
parity_features$league_model <- as.character(
  confirmation$league_model[[parity_index]]
)
parity_fixture <- list(
  features = parity_features,
  soft_quote = list(
    line = confirmation$final_line[[parity_index]],
    odds_over = 1.95,
    odds_under = 1.95
  ),
  expected = list(
    predicted_last_mu = confirmation$ridge[[parity_index]]
  )
)
jsonlite::write_json(
  parity_fixture,
  file.path(output_dir, "parity-fixture.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  digits = 15
)
saveRDS(ridge_final, file.path(output_dir, "ridge-model.rds"))
xgboost::xgb.save(xgb_final, file.path(output_dir, "xgboost-model.ubj"))

temporal_manifest <- data.frame(
  split = c(adjustment = "train", selection = "validation", confirmation = "test")[
    model_data$sample
  ],
  prediction_time = format(model_data$prediction_cutoff, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  feature_available_time = format(model_data$prediction_cutoff, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  target_time = format(model_data$last_prematch_time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
)
utils::write.csv(model_data, file.path(output_dir, "research-dataset.csv"), row.names = FALSE)
utils::write.csv(temporal_manifest, file.path(output_dir, "temporal-split-manifest.csv"), row.names = FALSE)
utils::write.csv(selection_summary, file.path(output_dir, "selection-summary.csv"), row.names = FALSE)
utils::write.csv(xgb_grid, file.path(output_dir, "xgboost-selection-grid.csv"), row.names = FALSE)
utils::write.csv(confirmation_summary, file.path(output_dir, "confirmation-summary.csv"), row.names = FALSE)
utils::write.csv(confirmation, file.path(output_dir, "confirmation-predictions.csv"), row.names = FALSE)
utils::write.csv(data.frame(delta_mae = bootstrap_delta), file.path(output_dir, "paired-series-bootstrap.csv"), row.names = FALSE)
utils::write.csv(league_rows, file.path(output_dir, "confirmation-by-league.csv"), row.names = FALSE)
utils::write.csv(gates, file.path(output_dir, "promotion-gates.csv"), row.names = FALSE)
theta_sensitivity <- do.call(rbind, lapply(c(12, 20, 30), function(theta_value) {
  sensitivity_target <- mapply(
    function(line, probability) invert_market_count_mean(
      line, probability, "negative_binomial", theta_value
    ),
    model_data$final_line,
    model_data$market_probability_over
  )
  adjustment_target <- sensitivity_target[model_data$sample == "adjustment"]
  selection_target <- sensitivity_target[model_data$sample == "selection"]
  confirmation_target <- sensitivity_target[model_data$sample == "confirmation"]
  fit <- glmnet::glmnet(
    x_adjustment, adjustment_target, alpha = 0,
    lambda = lambdas, standardize = TRUE
  )
  selection_mae <- sapply(lambdas, function(lambda) {
    prediction <- as.numeric(stats::predict(fit, x_selection, s = lambda))
    mean(abs(selection_target - prediction))
  })
  lambda <- lambdas[[which.min(selection_mae)]]
  final <- glmnet::glmnet(
    x_pre,
    sensitivity_target[model_data$sample != "confirmation"],
    alpha = 0,
    lambda = lambda,
    standardize = TRUE
  )
  prediction <- as.numeric(stats::predict(final, x_confirmation, s = lambda))
  baseline_rows <- model_data[model_data$sample != "confirmation", , drop = FALSE]
  baseline_rows$target_mu <- sensitivity_target[model_data$sample != "confirmation"]
  test_rows <- confirmation
  test_rows$target_mu <- confirmation_target
  baseline <- league_baseline(baseline_rows, test_rows)
  candidate_mae <- mean(abs(confirmation_target - prediction))
  baseline_mae <- mean(abs(confirmation_target - baseline))
  data.frame(
    theta = theta_value,
    selected_lambda = lambda,
    candidate_mae = candidate_mae,
    baseline_mae = baseline_mae,
    relative_improvement = (baseline_mae - candidate_mae) / baseline_mae,
    stringsAsFactors = FALSE
  )
}))
utils::write.csv(
  theta_sensitivity,
  file.path(output_dir, "theta-sensitivity.csv"),
  row.names = FALSE
)
utils::write.csv(data.frame(
  selected_candidate = selected_candidate,
  best_baseline = best_baseline,
  confirmation_maps = nrow(confirmation),
  confirmation_series = length(unique(confirmation$series_id)),
  bootstrap_lower = unname(stats::quantile(bootstrap_delta, 0.025)),
  bootstrap_upper = unname(stats::quantile(bootstrap_delta, 0.975)),
  interval_coverage = coverage,
  approved = approved,
  approved_for_manual_soft_comparison = manual_approved
), file.path(output_dir, "decision.csv"), row.names = FALSE)
cat(jsonlite::toJSON(list(
  rows = nrow(model_data),
  split = as.list(table(model_data$sample)),
  selected_candidate = selected_candidate,
  best_baseline = best_baseline,
  confirmation = confirmation_summary,
  gates = gates,
  approved = approved,
  approved_for_manual_soft_comparison = manual_approved
), auto_unbox = TRUE, pretty = TRUE), "\n")
