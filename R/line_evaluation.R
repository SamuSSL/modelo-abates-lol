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
  probability_over_matrix <- t(vapply(
    map_metrics$pmf,
    function(pmf) {
      cumulative <- cumsum(pmf)
      vapply(lines, function(line) {
        under_index <- min(floor(line) + 1L, length(cumulative))
        1 - cumulative[[under_index]]
      }, numeric(1L))
    },
    numeric(length(lines))
  ))
  line_count <- length(lines)
  observed <- rep(as.integer(map_metrics$observed), each = line_count)
  repeated_lines <- rep(lines, times = nrow(map_metrics))
  over_result <- as.integer(observed > repeated_lines)
  probability_over <- as.vector(t(probability_over_matrix))
  probability_under <- 1 - probability_over
  probability_result <- ifelse(
    over_result == 1L,
    probability_over,
    probability_under
  )
  rows <- data.frame(
    gameid = rep(
      as.character(map_metrics$gameid),
      each = line_count
    ),
    league_canonical = rep(
      as.character(map_metrics$league_canonical),
      each = line_count
    ),
    candidate_id = rep(
      as.character(map_metrics$candidate_id),
      each = line_count
    ),
    fold_id = rep(
      as.character(map_metrics$fold_id),
      each = line_count
    ),
    line = repeated_lines,
    observed = observed,
    probability_over = probability_over,
    probability_under = probability_under,
    probability_push = 0,
    over_result = over_result,
    brier = (probability_over - over_result)^2,
    log_loss = -log(pmax(probability_result, 1e-12)),
    stringsAsFactors = FALSE
  )
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
