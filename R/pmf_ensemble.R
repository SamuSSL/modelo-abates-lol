#' Build a fixed-weight probabilistic ensemble
#'
#' @param map_metrics Out-of-fold metrics with PMF list-column.
#' @param candidate_ids Candidate IDs to combine.
#' @param weights Non-negative fixed weights summing to one.
#' @param ensemble_id Output candidate ID.
#' @return One scored ensemble row per paired map.
#' @export
build_pmf_ensemble <- function(
  map_metrics,
  candidate_ids,
  weights,
  ensemble_id = "ensemble"
) {
  if (
    length(candidate_ids) < 2L ||
      length(weights) != length(candidate_ids) ||
      any(!is.finite(weights)) ||
      any(weights < 0) ||
      abs(sum(weights) - 1) > 1e-12
  ) {
    stop("Ensemble candidates and weights are invalid.", call. = FALSE)
  }
  candidates <- lapply(candidate_ids, function(candidate_id) {
    rows <- map_metrics[
      map_metrics$candidate_id == candidate_id,
      ,
      drop = FALSE
    ]
    rows[order(rows$gameid), , drop = FALSE]
  })
  game_ids <- Reduce(intersect, lapply(candidates, `[[`, "gameid"))
  if (length(game_ids) == 0L) {
    stop("Ensemble candidates have no paired maps.", call. = FALSE)
  }
  candidates <- lapply(candidates, function(rows) {
    rows[match(game_ids, rows$gameid), , drop = FALSE]
  })
  base <- candidates[[1L]]
  results <- lapply(seq_along(game_ids), function(index) {
    pmfs <- lapply(candidates, function(rows) rows$pmf[[index]])
    support_length <- max(vapply(pmfs, length, integer(1L)))
    padded <- lapply(pmfs, function(pmf) {
      c(pmf, rep(0, support_length - length(pmf)))
    })
    pmf <- Reduce(`+`, Map(`*`, padded, weights))
    pmf <- pmf / sum(pmf)
    observed <- as.integer(base$observed[[index]])
    probability_observed <- if (observed < length(pmf)) {
      pmf[[observed + 1L]]
    } else {
      0
    }
    row <- base[index, , drop = FALSE]
    row$candidate_id <- ensemble_id
    if ("distribution" %in% names(row)) {
      row$distribution <- "ensemble"
    }
    if ("feature_block" %in% names(row)) {
      row$feature_block <- paste(candidate_ids, collapse = "+")
    }
    row$prediction_mean <- sum((seq_along(pmf) - 1L) * pmf)
    row$prediction_median <- .pmf_quantile(pmf, 0.5)
    row$lower_50 <- .pmf_quantile(pmf, 0.25)
    row$upper_50 <- .pmf_quantile(pmf, 0.75)
    row$lower_80 <- .pmf_quantile(pmf, 0.10)
    row$upper_80 <- .pmf_quantile(pmf, 0.90)
    row$lower_90 <- .pmf_quantile(pmf, 0.05)
    row$upper_90 <- .pmf_quantile(pmf, 0.95)
    row$probability_observed <- probability_observed
    row$tail_mass <- sum(vapply(
      candidates,
      function(rows) rows$tail_mass[[index]],
      numeric(1L)
    ) * weights)
    row$crps <- discrete_crps(pmf, observed)
    row$log_score <- -log(max(probability_observed, 1e-12))
    row$pmf <- I(list(pmf))
    row
  })
  result <- do.call(rbind, results)
  rownames(result) <- NULL
  result
}
