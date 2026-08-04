script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

artifact_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "nb-pace-calibration-blend"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

decisions <- readRDS(file.path(
  artifact_dir,
  "structural_bet_decisions.rds"
))
candidate_id <- "joint_ml_quadratic_global"
development <- decisions[
  decisions$sample == "2025_q3_development" &
    decisions$candidate_id == candidate_id &
    decisions$bet,
  ,
  drop = FALSE
]
secondary <- decisions[
  decisions$sample == "2026_secondary" &
    decisions$candidate_id == candidate_id,
  ,
  drop = FALSE
]

if (nrow(development) < 100L || nrow(secondary) < 100L) {
  stop("Amostra insuficiente para o EV conservador.", call. = FALSE)
}

central_fit <- fit_binary_probability_calibrator(
  development$selected_probability,
  development$selected_win,
  method = "platt"
)
secondary$calibrated_probability <-
  predict_binary_probability_calibrator(
    central_fit,
    secondary$selected_probability
  )

month <- format(development$game_datetime, "%Y-%m", tz = "UTC")
block_id <- paste(month, development$series_id, sep = "|")
blocks <- split(seq_len(nrow(development)), block_id)
set.seed(20260731L)
bootstrap_predictions <- replicate(1000L, {
  sampled_blocks <- sample(
    seq_along(blocks),
    length(blocks),
    replace = TRUE
  )
  rows <- unlist(blocks[sampled_blocks], use.names = FALSE)
  draw <- development[rows, , drop = FALSE]
  fit <- tryCatch(
    fit_binary_probability_calibrator(
      draw$selected_probability,
      draw$selected_win,
      method = "platt"
    ),
    error = function(condition) NULL
  )
  if (is.null(fit)) {
    return(rep(NA_real_, nrow(secondary)))
  }
  predict_binary_probability_calibrator(
    fit,
    secondary$selected_probability
  )
})
valid_replicates <- colSums(is.finite(bootstrap_predictions)) ==
  nrow(secondary)
bootstrap_predictions <- bootstrap_predictions[
  ,
  valid_replicates,
  drop = FALSE
]
if (ncol(bootstrap_predictions) < 900L) {
  stop("Bootstrap de calibracao instavel.", call. = FALSE)
}
secondary$conservative_probability <- apply(
  bootstrap_predictions,
  1L,
  function(value) {
    stats::quantile(
      value,
      probs = 0.05,
      names = FALSE,
      na.rm = TRUE
    )
  }
)

secondary$raw_ev <- secondary$selected_ev
secondary$calibrated_ev <-
  secondary$selected_odds * secondary$calibrated_probability - 1
secondary$conservative_ev <-
  secondary$selected_odds * secondary$conservative_probability - 1

summarize_rule <- function(data, ev_column, probability_column, rule_id) {
  acted <- data[data[[ev_column]] > 0, , drop = FALSE]
  data.frame(
    rule_id = rule_id,
    eligible_maps = nrow(data),
    bets = nrow(acted),
    over_bets = sum(acted$selected_side == "over"),
    under_bets = sum(acted$selected_side == "under"),
    wins = sum(acted$selected_win),
    hit_rate = if (nrow(acted) > 0L) {
      mean(acted$selected_win)
    } else {
      NA_real_
    },
    average_odds = if (nrow(acted) > 0L) {
      mean(acted$selected_odds)
    } else {
      NA_real_
    },
    average_ev = if (nrow(acted) > 0L) {
      mean(acted[[ev_column]])
    } else {
      NA_real_
    },
    probability_gap = if (nrow(acted) > 0L) {
      mean(acted$selected_win - acted[[probability_column]])
    } else {
      NA_real_
    },
    profit_units = sum(acted$selected_profit),
    yield = if (nrow(acted) > 0L) {
      mean(acted$selected_profit)
    } else {
      NA_real_
    },
    stringsAsFactors = FALSE
  )
}

summary <- rbind(
  summarize_rule(
    secondary,
    "raw_ev",
    "selected_probability",
    "raw_ev_positive"
  ),
  summarize_rule(
    secondary,
    "calibrated_ev",
    "calibrated_probability",
    "calibrated_ev_positive"
  ),
  summarize_rule(
    secondary,
    "conservative_ev",
    "conservative_probability",
    "conservative_lower_95_ev_positive"
  )
)

set.seed(20260731L)
bootstrap_rows <- lapply(seq_len(nrow(summary)), function(index) {
  rule <- summary$rule_id[[index]]
  ev_column <- switch(
    rule,
    raw_ev_positive = "raw_ev",
    calibrated_ev_positive = "calibrated_ev",
    conservative_lower_95_ev_positive = "conservative_ev"
  )
  acted <- secondary[secondary[[ev_column]] > 0, , drop = FALSE]
  month <- format(acted$game_datetime, "%Y-%m", tz = "UTC")
  block_id <- paste(month, acted$series_id, sep = "|")
  blocks <- split(seq_len(nrow(acted)), block_id)
  estimates <- replicate(2000L, {
    sampled_blocks <- sample(
      seq_along(blocks),
      length(blocks),
      replace = TRUE
    )
    rows <- unlist(blocks[sampled_blocks], use.names = FALSE)
    draw <- acted[rows, , drop = FALSE]
    mean(draw$selected_profit)
  })
  data.frame(
    rule_id = rule,
    bets = nrow(acted),
    blocks = length(blocks),
    yield_lower_95 = stats::quantile(
      estimates,
      0.025,
      names = FALSE
    ),
    yield_upper_95 = stats::quantile(
      estimates,
      0.975,
      names = FALSE
    ),
    stringsAsFactors = FALSE
  )
})
bootstrap_summary <- do.call(rbind, bootstrap_rows)
rownames(bootstrap_summary) <- NULL

fit_summary <- data.frame(
  training_period = "2025_q3_development",
  training_bets = nrow(development),
  training_blocks = length(blocks),
  platt_intercept = unname(stats::coef(central_fit$fit)[[1L]]),
  platt_slope = unname(stats::coef(central_fit$fit)[[2L]]),
  bootstrap_replicates = ncol(bootstrap_predictions),
  conservative_quantile = 0.05,
  stringsAsFactors = FALSE
)

utils::write.csv(
  summary,
  file.path(artifact_dir, "conservative_ev_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap_summary,
  file.path(artifact_dir, "conservative_ev_bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  fit_summary,
  file.path(artifact_dir, "conservative_ev_fit.csv"),
  row.names = FALSE
)
saveRDS(
  secondary,
  file.path(artifact_dir, "conservative_ev_map_decisions.rds"),
  version = 3L
)

print(fit_summary, row.names = FALSE)
print(summary, row.names = FALSE)
print(bootstrap_summary, row.names = FALSE)
