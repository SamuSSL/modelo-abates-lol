.safe_spearman <- function(x, y) {
  valid <- is.finite(x) & is.finite(y)
  if (
    sum(valid) < 3L ||
    stats::sd(x[valid]) == 0 ||
    stats::sd(y[valid]) == 0
  ) {
    return(NA_real_)
  }
  suppressWarnings(stats::cor(x[valid], y[valid], method = "spearman"))
}

.mean_or_na <- function(values) {
  values <- as.numeric(values)
  if (all(is.na(values))) {
    NA_real_
  } else {
    mean(values, na.rm = TRUE)
  }
}

.build_stability_blocks <- function(data, metrics, block_size) {
  team_key <- ifelse(
    !is.na(data$team_id) & nzchar(as.character(data$team_id)),
    as.character(data$team_id),
    as.character(data$team_name)
  )
  group_key <- paste(data$league_canonical, team_key, sep = "|")
  groups <- split(seq_len(nrow(data)), group_key)
  rows <- list()
  row_index <- 0L

  for (key in names(groups)) {
    index <- groups[[key]]
    index <- index[order(data$game_datetime[index], data$gameid[index])]
    block_number <- (seq_along(index) - 1L) %/% block_size + 1L
    block_groups <- split(index, block_number)
    for (block_name in names(block_groups)) {
      block_index <- block_groups[[block_name]]
      if (length(block_index) != block_size) {
        next
      }
      row_index <- row_index + 1L
      row <- data.frame(
        group_key = key,
        team_key = team_key[block_index[[1L]]],
        league_canonical = as.character(
          data$league_canonical[block_index[[1L]]]
        ),
        block_number = as.integer(block_name),
        games = length(block_index),
        block_start = min(data$game_datetime[block_index]),
        block_end = max(data$game_datetime[block_index]),
        stringsAsFactors = FALSE
      )
      for (metric in metrics) {
        row[[metric]] <- .mean_or_na(data[[metric]][block_index])
      }
      rows[[row_index]] <- row
    }
  }
  if (length(rows) == 0L) {
    return(data.frame())
  }
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

.pair_stability_blocks <- function(blocks, metrics) {
  groups <- split(seq_len(nrow(blocks)), blocks$group_key)
  rows <- list()
  row_index <- 0L
  for (key in names(groups)) {
    index <- groups[[key]]
    index <- index[order(blocks$block_number[index])]
    if (length(index) < 2L) {
      next
    }
    for (position in seq.int(2L, length(index))) {
      previous <- blocks[index[[position - 1L]], , drop = FALSE]
      next_block <- blocks[index[[position]], , drop = FALSE]
      if (
        next_block$block_number[[1L]] !=
          previous$block_number[[1L]] + 1L
      ) {
        next
      }
      row_index <- row_index + 1L
      row <- data.frame(
        group_key = key,
        team_key = previous$team_key[[1L]],
        league_canonical = previous$league_canonical[[1L]],
        previous_block = previous$block_number[[1L]],
        next_block = next_block$block_number[[1L]],
        previous_block_end = previous$block_end[[1L]],
        next_block_start = next_block$block_start[[1L]],
        stringsAsFactors = FALSE
      )
      for (metric in metrics) {
        row[[paste0("previous_", metric)]] <- previous[[metric]][[1L]]
        row[[paste0("next_", metric)]] <- next_block[[metric]][[1L]]
      }
      rows[[row_index]] <- row
    }
  }
  if (length(rows) == 0L) {
    return(data.frame())
  }
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

.summarize_stability_pairs <- function(pairs, metric_names) {
  rows <- lapply(metric_names, function(metric) {
    previous <- pairs[[paste0("previous_", metric)]]
    next_value <- pairs[[paste0("next_", metric)]]
    next_intensity <- pairs$next_combined_kills_per_minute
    next_total <- pairs$next_total_kills_game
    valid_pairs <- sum(is.finite(previous) & is.finite(next_value))
    data.frame(
      metric = metric,
      pairs = valid_pairs,
      stability_spearman = .safe_spearman(previous, next_value),
      future_intensity_spearman = .safe_spearman(
        previous,
        next_intensity
      ),
      future_total_spearman = .safe_spearman(previous, next_total),
      stringsAsFactors = FALSE
    )
  })
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

#' Evaluate stickiness and future relevance of team metrics
#'
#' @param team_metrics Team-map metric table.
#' @param metric_names Candidate metric columns.
#' @param block_size Number of consecutive games per complete block.
#' @return Blocks, adjacent pairs, global summary, and league summary.
#' @export
evaluate_metric_stability <- function(
  team_metrics,
  metric_names,
  block_size = 10L
) {
  required <- c(
    "gameid",
    "game_datetime",
    "league_canonical",
    "competition_role",
    "team_id",
    "team_name",
    "combined_kills_per_minute",
    "total_kills_game"
  )
  missing <- setdiff(required, names(team_metrics))
  if (length(missing) > 0L) {
    stop(
      "Missing stability columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  unknown <- setdiff(metric_names, names(team_metrics))
  if (length(unknown) > 0L) {
    stop(
      "Unknown metrics: ",
      paste(unknown, collapse = ", "),
      call. = FALSE
    )
  }
  if (block_size < 2L) {
    stop("block_size must be at least two games.", call. = FALSE)
  }
  data <- team_metrics[
    team_metrics$competition_role == "target" &
      !is.na(team_metrics$game_datetime),
    ,
    drop = FALSE
  ]
  study_metrics <- unique(c(
    metric_names,
    "combined_kills_per_minute",
    "total_kills_game"
  ))
  blocks <- .build_stability_blocks(
    data,
    study_metrics,
    as.integer(block_size)
  )
  if (nrow(blocks) == 0L) {
    stop("No complete stability blocks.", call. = FALSE)
  }
  pairs <- .pair_stability_blocks(blocks, study_metrics)
  if (nrow(pairs) == 0L) {
    stop("No adjacent stability blocks.", call. = FALSE)
  }
  summary <- .summarize_stability_pairs(pairs, metric_names)
  league_groups <- split(pairs, pairs$league_canonical)
  by_league <- do.call(
    rbind,
    lapply(names(league_groups), function(league) {
      result <- .summarize_stability_pairs(
        league_groups[[league]],
        metric_names
      )
      result$league_canonical <- league
      result
    })
  )
  rownames(by_league) <- NULL
  list(
    block_metrics = blocks,
    pairs = pairs,
    summary = summary,
    by_league = by_league
  )
}
