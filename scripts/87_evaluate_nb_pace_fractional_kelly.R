script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

input_path <- file.path(
  project_root,
  "artifacts",
  "bettingiscool",
  "nb_pace_ev_thresholds",
  "eligible_map_metrics.rds"
)
data <- readRDS(input_path)
data <- data[order(data$game_datetime, data$gameid), , drop = FALSE]

artifact_dir <- file.path(
  project_root,
  "artifacts",
  "bettingiscool",
  "nb_pace_fractional_kelly"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

strategies <- data.frame(
  strategy_id = c(
    "fixed_1u",
    "quarter_kelly_cap_1u",
    "quarter_kelly_cap_2u",
    "quarter_kelly_cap_5u",
    "half_kelly_cap_5u",
    "full_kelly_cap_5u",
    "quarter_kelly_haircut_10pp_cap_1u",
    "quarter_kelly_haircut_10pp_cap_2u",
    "quarter_kelly_haircut_15pp_cap_1u",
    "quarter_kelly_haircut_15pp_cap_2u",
    "eighth_kelly_haircut_10pp_cap_1u"
  ),
  kelly_fraction = c(
    NA,
    0.25,
    0.25,
    0.25,
    0.50,
    1,
    0.25,
    0.25,
    0.25,
    0.25,
    0.125
  ),
  maximum_stake_units = c(1, 1, 2, 5, 5, 5, 1, 2, 1, 2, 1),
  ev_haircut = c(
    0,
    0,
    0,
    0,
    0,
    0,
    0.10,
    0.10,
    0.15,
    0.15,
    0.10
  ),
  fixed_stake_units = c(1, rep(NA_real_, 10L)),
  stringsAsFactors = FALSE
)
thresholds <- c(0.05, 0.10, 0.15, 0.20)
starting_bankroll <- 100

simulate_strategy <- function(
  data,
  minimum_ev,
  strategy,
  sample_name
) {
  eligible <- data[data$selected_ev >= minimum_ev, , drop = FALSE]
  bankroll <- starting_bankroll
  peak_bankroll <- bankroll
  maximum_drawdown_units <- 0
  maximum_drawdown_fraction <- 0
  rows <- vector("list", nrow(eligible))
  for (index in seq_len(nrow(eligible))) {
    bet <- eligible[index, , drop = FALSE]
    adjusted_ev <- max(
      as.numeric(bet$selected_ev) -
        as.numeric(strategy$ev_haircut),
      0
    )
    full_kelly_fraction <- if (adjusted_ev > 0) {
      adjusted_ev / (as.numeric(bet$selected_odds) - 1)
    } else {
      0
    }
    requested_stake <- if (
      is.finite(strategy$fixed_stake_units)
    ) {
      as.numeric(strategy$fixed_stake_units)
    } else {
      as.numeric(strategy$kelly_fraction) *
        full_kelly_fraction *
        bankroll
    }
    stake <- min(
      requested_stake,
      as.numeric(strategy$maximum_stake_units),
      bankroll
    )
    profit <- stake * if (
      isTRUE(as.logical(bet$selected_win))
    ) {
      as.numeric(bet$selected_odds) - 1
    } else {
      -1
    }
    bankroll_before <- bankroll
    bankroll <- bankroll + profit
    peak_bankroll <- max(peak_bankroll, bankroll)
    drawdown_units <- peak_bankroll - bankroll
    drawdown_fraction <- if (peak_bankroll > 0) {
      drawdown_units / peak_bankroll
    } else {
      NA_real_
    }
    maximum_drawdown_units <- max(
      maximum_drawdown_units,
      drawdown_units
    )
    maximum_drawdown_fraction <- max(
      maximum_drawdown_fraction,
      drawdown_fraction,
      na.rm = TRUE
    )
    rows[[index]] <- data.frame(
      sample = sample_name,
      strategy_id = as.character(strategy$strategy_id),
      minimum_ev = minimum_ev,
      gameid = as.character(bet$gameid),
      series_id = as.character(bet$series_id),
      game_datetime = bet$game_datetime,
      selected_side = as.character(bet$selected_side),
      raw_ev = as.numeric(bet$selected_ev),
      adjusted_ev = adjusted_ev,
      full_kelly_fraction = full_kelly_fraction,
      requested_stake_units = requested_stake,
      stake_units = stake,
      selected_odds = as.numeric(bet$selected_odds),
      selected_win = as.logical(bet$selected_win),
      profit_units = profit,
      bankroll_before = bankroll_before,
      bankroll_after = bankroll,
      stringsAsFactors = FALSE
    )
  }
  path <- if (length(rows) > 0L) {
    do.call(rbind, rows)
  } else {
    data.frame()
  }
  total_staked <- if (nrow(path) > 0L) {
    sum(path$stake_units)
  } else {
    0
  }
  profit <- bankroll - starting_bankroll
  summary <- data.frame(
    sample = sample_name,
    strategy_id = as.character(strategy$strategy_id),
    minimum_ev = minimum_ev,
    eligible_bets = nrow(eligible),
    placed_bets = if (nrow(path) > 0L) {
      sum(path$stake_units > 0)
    } else {
      0L
    },
    starting_bankroll_units = starting_bankroll,
    ending_bankroll_units = bankroll,
    profit_units = profit,
    total_staked_units = total_staked,
    staking_yield = if (total_staked > 0) {
      profit / total_staked
    } else {
      NA_real_
    },
    average_stake_units = if (nrow(path) > 0L) {
      mean(path$stake_units[path$stake_units > 0])
    } else {
      NA_real_
    },
    maximum_stake_units = if (nrow(path) > 0L) {
      max(path$stake_units)
    } else {
      0
    },
    maximum_drawdown_units = maximum_drawdown_units,
    maximum_drawdown_fraction = maximum_drawdown_fraction,
    minimum_bankroll_units = if (nrow(path) > 0L) {
      min(path$bankroll_after)
    } else {
      starting_bankroll
    },
    stringsAsFactors = FALSE
  )
  list(summary = summary, path = path)
}

samples <- c(
  list(combined = data),
  split(data, data$fold_id)
)
summary_rows <- list()
path_rows <- list()
result_index <- 0L
for (sample_name in names(samples)) {
  for (threshold in thresholds) {
    for (strategy_index in seq_len(nrow(strategies))) {
      strategy <- strategies[strategy_index, , drop = FALSE]
      result <- simulate_strategy(
        samples[[sample_name]],
        threshold,
        strategy,
        sample_name
      )
      result_index <- result_index + 1L
      summary_rows[[result_index]] <- result$summary
      path_rows[[result_index]] <- result$path
    }
  }
}
summary <- do.call(rbind, summary_rows)
rownames(summary) <- NULL
non_empty_paths <- path_rows[
  !vapply(path_rows, function(path) nrow(path) == 0L, logical(1L))
]
paths <- do.call(rbind, non_empty_paths)
rownames(paths) <- NULL

utils::write.csv(
  summary,
  file.path(artifact_dir, "kelly_summary.csv"),
  row.names = FALSE
)
saveRDS(
  paths,
  file.path(artifact_dir, "kelly_bankroll_paths.rds"),
  version = 3L
)
utils::write.csv(
  strategies,
  file.path(artifact_dir, "kelly_strategy_contract.csv"),
  row.names = FALSE
)

print(
  summary[
    summary$sample == "combined",
    ,
    drop = FALSE
  ],
  row.names = FALSE
)
