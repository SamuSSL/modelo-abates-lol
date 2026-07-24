#' Evaluate half-kill lines from predictive PMFs
#'
#' @param map_metrics Map predictions with list-column `pmf`.
#' @param lines Numeric lines ending in `.5`.
#' @return Per-line rows and aggregate summaries.
#' @export
evaluate_line_probabilities <- function(map_metrics, lines) {
  required <- c(
    "gameid",
    "league_canonical",
    "candidate_id",
    "fold_id",
    "observed",
    "pmf"
  )
  if (!all(required %in% names(map_metrics))) {
    stop("Map metrics are missing line-evaluation columns.", call. = FALSE)
  }
  lines <- as.numeric(lines)
  if (
    length(lines) == 0L ||
      any(!is.finite(lines)) ||
      any(abs(lines %% 1 - 0.5) > 1e-12)
  ) {
    stop("Evaluation lines must end in .5.", call. = FALSE)
  }
  batches <- lapply(seq_len(nrow(map_metrics)), function(index) {
    row <- map_metrics[index, , drop = FALSE]
    pmf <- row$pmf[[1L]]
    rows <- lapply(lines, function(line) {
      under_max <- floor(line)
      available <- seq.int(0L, min(under_max, length(pmf) - 1L))
      probability_under <- sum(pmf[available + 1L])
      probability_over <- 1 - probability_under
      result <- as.integer(row$observed[[1L]] > line)
      probability_result <- if (result == 1L) {
        probability_over
      } else {
        probability_under
      }
      data.frame(
        gameid = as.character(row$gameid[[1L]]),
        league_canonical = as.character(
          row$league_canonical[[1L]]
        ),
        candidate_id = as.character(row$candidate_id[[1L]]),
        fold_id = as.character(row$fold_id[[1L]]),
        line = line,
        observed = as.integer(row$observed[[1L]]),
        probability_over = probability_over,
        probability_under = probability_under,
        probability_push = 0,
        over_result = result,
        brier = (probability_over - result)^2,
        log_loss = -log(max(probability_result, 1e-12)),
        stringsAsFactors = FALSE
      )
    })
    do.call(rbind, rows)
  })
  rows <- do.call(rbind, batches)
  groups <- split(
    rows,
    interaction(
      rows$candidate_id,
      rows$line,
      drop = TRUE,
      lex.order = TRUE
    )
  )
  summary <- do.call(rbind, lapply(groups, function(group) {
    data.frame(
      candidate_id = group$candidate_id[[1L]],
      line = group$line[[1L]],
      maps = nrow(group),
      mean_probability_over = mean(group$probability_over),
      observed_over_rate = mean(group$over_result),
      mean_brier = mean(group$brier),
      mean_log_loss = mean(group$log_loss),
      calibration_error = mean(group$probability_over) -
        mean(group$over_result),
      stringsAsFactors = FALSE
    )
  }))
  rownames(rows) <- NULL
  rownames(summary) <- NULL
  list(rows = rows, summary = summary)
}
