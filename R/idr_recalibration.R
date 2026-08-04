#' Recalibrate OOF count PMFs with prior-fold IDR
#'
#' Each validation fold is recalibrated only with OOF predictions from folds
#' that ended earlier. The first fold remains unchanged as a cold start.
#'
#' @param metrics OOF map metrics for one candidate.
#' @param candidate_id Identifier for recalibrated rows.
#' @return Recalibrated OOF metrics with PMFs.
#' @export
recalibrate_oof_idr <- function(metrics, candidate_id = "idr") {
  if (!requireNamespace("isodistrreg", quietly = TRUE)) {
    stop("Package isodistrreg is required.", call. = FALSE)
  }
  required <- c(
    "fold_id", "game_datetime", "observed", "prediction_mean", "pmf"
  )
  missing <- setdiff(required, names(metrics))
  if (length(missing) > 0L) {
    stop("Metricas sem campos IDR: ", paste(missing, collapse = ", "))
  }
  fold_order <- stats::aggregate(
    metrics$game_datetime,
    list(fold_id = metrics$fold_id),
    min
  )
  fold_order <- fold_order[order(fold_order$x), , drop = FALSE]
  output <- list()
  prior <- metrics[FALSE, , drop = FALSE]
  for (fold_index in seq_len(nrow(fold_order))) {
    fold <- as.character(fold_order$fold_id[[fold_index]])
    current <- metrics[metrics$fold_id == fold, , drop = FALSE]
    if (nrow(prior) >= 200L) {
      fit <- isodistrreg::idr(
        y = prior$observed,
        X = data.frame(prediction_mean = prior$prediction_mean),
        progress = FALSE
      )
      prediction <- stats::predict(
        fit,
        data = data.frame(prediction_mean = current$prediction_mean)
      )
      maximum <- max(c(metrics$observed, 80L), na.rm = TRUE)
      cdfs <- isodistrreg::cdf(prediction, 0:maximum)
      pmfs <- lapply(seq_len(nrow(cdfs)), function(index) {
        pmf <- diff(c(0, as.numeric(cdfs[index, ])))
        pmf[pmf < 0 & pmf > -1e-10] <- 0
        pmf <- pmax(pmf, 0)
        pmf / sum(pmf)
      })
    } else {
      pmfs <- current$pmf
    }
    for (index in seq_len(nrow(current))) {
      pmf <- pmfs[[index]]
      observed <- as.integer(current$observed[[index]])
      probability <- if (observed < length(pmf)) {
        pmf[[observed + 1L]]
      } else {
        0
      }
      current$candidate_id[[index]] <- candidate_id
      current$distribution[[index]] <- "idr_recalibrated"
      current$feature_block[[index]] <- "prior_oof_idr"
      current$prediction_mean[[index]] <- sum(
        (seq_along(pmf) - 1L) * pmf
      )
      current$prediction_median[[index]] <- .pmf_quantile(pmf, 0.5)
      current$lower_50[[index]] <- .pmf_quantile(pmf, 0.25)
      current$upper_50[[index]] <- .pmf_quantile(pmf, 0.75)
      current$lower_80[[index]] <- .pmf_quantile(pmf, 0.10)
      current$upper_80[[index]] <- .pmf_quantile(pmf, 0.90)
      current$lower_90[[index]] <- .pmf_quantile(pmf, 0.05)
      current$upper_90[[index]] <- .pmf_quantile(pmf, 0.95)
      current$probability_observed[[index]] <- probability
      current$crps[[index]] <- discrete_crps(pmf, observed)
      current$log_score[[index]] <- -log(max(probability, 1e-12))
      current$pmf[[index]] <- pmf
    }
    output[[fold_index]] <- current
    prior <- rbind(prior, metrics[metrics$fold_id == fold, , drop = FALSE])
  }
  result <- do.call(rbind, output)
  rownames(result) <- NULL
  result
}
