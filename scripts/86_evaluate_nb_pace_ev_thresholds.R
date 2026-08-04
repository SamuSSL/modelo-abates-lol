script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

artifact_dir <- file.path(
  project_root,
  "artifacts",
  "bettingiscool",
  "nb_pace_ev_thresholds"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

metrics <- readRDS(file.path(
  project_root,
  "artifacts",
  "premap_joint_model",
  "map_metrics.rds"
))
metrics <- metrics[
  metrics$candidate_id == "nb_pace" &
    is.finite(metrics$probability_over) &
    !is.na(metrics$observed_over),
  ,
  drop = FALSE
]

database_path <- file.path(
  project_root,
  "data",
  "processed",
  "lolkills.duckdb"
)
connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = database_path,
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

snapshots <- DBI::dbReadTable(connection, "market_odds_snapshots")
links <- DBI::dbReadTable(connection, "game_market_links")
selected <- select_bettingiscool_map_snapshots(
  snapshots,
  minutes_before_close = 15
)
selected <- selected[
  selected$snapshot_minutes_before_close <= 30 &
    abs(selected$line %% 1 - 0.5) < 1e-12,
  ,
  drop = FALSE
]
verified_links <- links[
  links$link_status == "verified",
  c("gameid", "event_id", "period"),
  drop = FALSE
]
market <- merge(
  verified_links,
  selected,
  by = c("event_id", "period")
)
market <- market[!duplicated(market$gameid), , drop = FALSE]
market$market_line <- market$line
market <- market[c(
  "gameid",
  "market_line",
  "odds_over",
  "odds_under",
  "true_odds_over",
  "true_odds_under",
  "odds_timestamp",
  "snapshot_minutes_before_close"
)]

data <- merge(metrics, market, by = "gameid")
data <- data[
  is.finite(data$odds_over) &
    data$odds_over > 1 &
    is.finite(data$odds_under) &
    data$odds_under > 1,
  ,
  drop = FALSE
]
if (
  nrow(data) == 0L ||
    any(abs(data$line - data$market_line) > 1e-12)
) {
  stop(
    "As linhas do backtest não correspondem ao snapshot de mercado.",
    call. = FALSE
  )
}
if (any(duplicated(data[c("gameid", "fold_id")]))) {
  stop("Há mapas duplicados no backtest de EV.", call. = FALSE)
}

data$ev_over <- data$probability_over * data$odds_over - 1
data$ev_under <- (
  1 - data$probability_over
) * data$odds_under - 1
data$selected_side <- ifelse(
  data$ev_over >= data$ev_under,
  "over",
  "under"
)
data$selected_ev <- pmax(data$ev_over, data$ev_under)
data$selected_odds <- ifelse(
  data$selected_side == "over",
  data$odds_over,
  data$odds_under
)
data$selected_probability <- ifelse(
  data$selected_side == "over",
  data$probability_over,
  1 - data$probability_over
)
data$selected_win <- ifelse(
  data$selected_side == "over",
  data$observed_over,
  !data$observed_over
)
data$selected_profit <- ifelse(
  data$selected_win,
  data$selected_odds - 1,
  -1
)

maximum_drawdown <- function(profit, datetime) {
  ordered <- profit[order(datetime)]
  cumulative <- cumsum(ordered)
  running_peak <- cummax(c(0, cumulative))[-1L]
  abs(min(cumulative - running_peak, 0))
}

threshold_eligible <- function(expected_value, threshold) {
  if (threshold == 0) {
    return(expected_value > 0)
  }
  expected_value >= threshold
}

summarize_threshold <- function(data, threshold, sample_name) {
  bets <- data[
    threshold_eligible(data$selected_ev, threshold),
    ,
    drop = FALSE
  ]
  if (nrow(bets) == 0L) {
    return(data.frame(
      sample = sample_name,
      minimum_ev = threshold,
      eligible_maps = nrow(data),
      bets = 0L,
      bet_rate = 0,
      over_bets = 0L,
      under_bets = 0L,
      wins = 0L,
      hit_rate = NA_real_,
      average_odds = NA_real_,
      average_predicted_probability = NA_real_,
      average_break_even_probability = NA_real_,
      probability_calibration_gap = NA_real_,
      average_predicted_ev = NA_real_,
      profit_units = 0,
      yield = NA_real_,
      maximum_drawdown_units = 0,
      stringsAsFactors = FALSE
    ))
  }
  data.frame(
    sample = sample_name,
    minimum_ev = threshold,
    eligible_maps = nrow(data),
    bets = nrow(bets),
    bet_rate = nrow(bets) / nrow(data),
    over_bets = sum(bets$selected_side == "over"),
    under_bets = sum(bets$selected_side == "under"),
    wins = sum(bets$selected_win),
    hit_rate = mean(bets$selected_win),
    average_odds = mean(bets$selected_odds),
    average_predicted_probability = mean(
      bets$selected_probability
    ),
    average_break_even_probability = mean(
      1 / bets$selected_odds
    ),
    probability_calibration_gap = mean(bets$selected_win) -
      mean(bets$selected_probability),
    average_predicted_ev = mean(bets$selected_ev),
    profit_units = sum(bets$selected_profit),
    yield = mean(bets$selected_profit),
    maximum_drawdown_units = maximum_drawdown(
      bets$selected_profit,
      bets$game_datetime
    ),
    stringsAsFactors = FALSE
  )
}

samples <- c(
  list(combined = data),
  split(data, data$fold_id)
)
thresholds <- c(0, 0.05, 0.10, 0.15, 0.20)
summary_rows <- lapply(names(samples), function(sample_name) {
  do.call(rbind, lapply(thresholds, function(threshold) {
    summarize_threshold(
      samples[[sample_name]],
      threshold,
      sample_name
    )
  }))
})
threshold_summary <- do.call(rbind, summary_rows)
rownames(threshold_summary) <- NULL

set.seed(20260730L)
bootstrap_rows <- list()
bootstrap_index <- 0L
for (sample_name in names(samples)) {
  sample_data <- samples[[sample_name]]
  month <- format(sample_data$game_datetime, "%Y-%m", tz = "UTC")
  block_id <- paste(month, sample_data$series_id, sep = "|")
  blocks <- split(seq_len(nrow(sample_data)), block_id)
  for (threshold in thresholds) {
    estimates <- replicate(2000L, {
      sampled_blocks <- sample(
        seq_along(blocks),
        length(blocks),
        replace = TRUE
      )
      sampled_rows <- unlist(
        blocks[sampled_blocks],
        use.names = FALSE
      )
      draw <- sample_data[sampled_rows, , drop = FALSE]
      bets <- draw[
        threshold_eligible(draw$selected_ev, threshold),
        ,
        drop = FALSE
      ]
      c(
        bets = nrow(bets),
        profit_units = sum(bets$selected_profit),
        yield = if (nrow(bets) > 0L) {
          mean(bets$selected_profit)
        } else {
          NA_real_
        }
      )
    })
    bootstrap_index <- bootstrap_index + 1L
    bootstrap_rows[[bootstrap_index]] <- data.frame(
      sample = sample_name,
      minimum_ev = threshold,
      blocks = length(blocks),
      replicates = ncol(estimates),
      yield_lower_95 = stats::quantile(
        estimates["yield", ],
        0.025,
        na.rm = TRUE,
        names = FALSE
      ),
      yield_upper_95 = stats::quantile(
        estimates["yield", ],
        0.975,
        na.rm = TRUE,
        names = FALSE
      ),
      profit_lower_95 = stats::quantile(
        estimates["profit_units", ],
        0.025,
        na.rm = TRUE,
        names = FALSE
      ),
      profit_upper_95 = stats::quantile(
        estimates["profit_units", ],
        0.975,
        na.rm = TRUE,
        names = FALSE
      ),
      stringsAsFactors = FALSE
    )
  }
}
bootstrap_summary <- do.call(rbind, bootstrap_rows)
rownames(bootstrap_summary) <- NULL

ev_positive <- data[
  threshold_eligible(data$selected_ev, 0),
  ,
  drop = FALSE
]
subgroup_definitions <- c(
  split(
    ev_positive,
    paste0("side=", ev_positive$selected_side)
  ),
  split(
    ev_positive,
    paste0("league=", ev_positive$league_canonical)
  ),
  split(
    ev_positive,
    paste0(
      "league=",
      ev_positive$league_canonical,
      "|side=",
      ev_positive$selected_side
    )
  )
)
set.seed(20260730L)
subgroup_bootstrap_rows <- lapply(
  names(subgroup_definitions),
  function(subgroup_id) {
    group <- subgroup_definitions[[subgroup_id]]
    month <- format(group$game_datetime, "%Y-%m", tz = "UTC")
    block_id <- paste(month, group$series_id, sep = "|")
    blocks <- split(seq_len(nrow(group)), block_id)
    estimates <- replicate(2000L, {
      sampled_blocks <- sample(
        seq_along(blocks),
        length(blocks),
        replace = TRUE
      )
      sampled_rows <- unlist(
        blocks[sampled_blocks],
        use.names = FALSE
      )
      draw <- group[sampled_rows, , drop = FALSE]
      c(
        profit_units = sum(draw$selected_profit),
        yield = mean(draw$selected_profit)
      )
    })
    data.frame(
      subgroup = subgroup_id,
      bets = nrow(group),
      blocks = length(blocks),
      profit_units = sum(group$selected_profit),
      yield = mean(group$selected_profit),
      yield_lower_95 = stats::quantile(
        estimates["yield", ],
        0.025,
        names = FALSE
      ),
      yield_upper_95 = stats::quantile(
        estimates["yield", ],
        0.975,
        names = FALSE
      ),
      stringsAsFactors = FALSE
    )
  }
)
subgroup_bootstrap_summary <- do.call(
  rbind,
  subgroup_bootstrap_rows
)
rownames(subgroup_bootstrap_summary) <- NULL

league_rows <- lapply(names(samples), function(sample_name) {
  sample_data <- samples[[sample_name]]
  do.call(rbind, lapply(thresholds, function(threshold) {
    bets <- sample_data[
      threshold_eligible(sample_data$selected_ev, threshold),
      ,
      drop = FALSE
    ]
    if (nrow(bets) == 0L) {
      return(NULL)
    }
    groups <- split(bets, bets$league_canonical)
    do.call(rbind, lapply(groups, function(group) {
      data.frame(
        sample = sample_name,
        minimum_ev = threshold,
        league_canonical = group$league_canonical[[1L]],
        bets = nrow(group),
        profit_units = sum(group$selected_profit),
        yield = mean(group$selected_profit),
        stringsAsFactors = FALSE
      )
    }))
  }))
})
league_summary <- do.call(rbind, league_rows)
rownames(league_summary) <- NULL

side_rows <- lapply(names(samples), function(sample_name) {
  sample_data <- samples[[sample_name]]
  do.call(rbind, lapply(thresholds, function(threshold) {
    bets <- sample_data[
      threshold_eligible(sample_data$selected_ev, threshold),
      ,
      drop = FALSE
    ]
    if (nrow(bets) == 0L) {
      return(NULL)
    }
    groups <- split(bets, bets$selected_side)
    do.call(rbind, lapply(groups, function(group) {
      data.frame(
        sample = sample_name,
        minimum_ev = threshold,
        side = group$selected_side[[1L]],
        bets = nrow(group),
        wins = sum(group$selected_win),
        average_predicted_ev = mean(group$selected_ev),
        profit_units = sum(group$selected_profit),
        yield = mean(group$selected_profit),
        stringsAsFactors = FALSE
      )
    }))
  }))
})
side_summary <- do.call(rbind, side_rows)
rownames(side_summary) <- NULL

league_side_rows <- lapply(names(samples), function(sample_name) {
  sample_data <- samples[[sample_name]]
  do.call(rbind, lapply(thresholds, function(threshold) {
    bets <- sample_data[
      threshold_eligible(sample_data$selected_ev, threshold),
      ,
      drop = FALSE
    ]
    if (nrow(bets) == 0L) {
      return(NULL)
    }
    groups <- split(
      bets,
      interaction(
        bets$league_canonical,
        bets$selected_side,
        drop = TRUE,
        lex.order = TRUE
      )
    )
    do.call(rbind, lapply(groups, function(group) {
      data.frame(
        sample = sample_name,
        minimum_ev = threshold,
        league_canonical = group$league_canonical[[1L]],
        side = group$selected_side[[1L]],
        bets = nrow(group),
        wins = sum(group$selected_win),
        hit_rate = mean(group$selected_win),
        average_odds = mean(group$selected_odds),
        profit_units = sum(group$selected_profit),
        yield = mean(group$selected_profit),
        stringsAsFactors = FALSE
      )
    }))
  }))
})
league_side_summary <- do.call(rbind, league_side_rows)
rownames(league_side_summary) <- NULL

utils::write.csv(
  threshold_summary,
  file.path(artifact_dir, "threshold_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap_summary,
  file.path(artifact_dir, "threshold_bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  subgroup_bootstrap_summary,
  file.path(artifact_dir, "ev_positive_subgroup_bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  league_summary,
  file.path(artifact_dir, "threshold_by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  side_summary,
  file.path(artifact_dir, "threshold_by_side.csv"),
  row.names = FALSE
)
utils::write.csv(
  league_side_summary,
  file.path(artifact_dir, "threshold_by_league_and_side.csv"),
  row.names = FALSE
)
saveRDS(
  data,
  file.path(artifact_dir, "eligible_map_metrics.rds"),
  version = 3L
)

print(threshold_summary, row.names = FALSE)
print(bootstrap_summary, row.names = FALSE)
