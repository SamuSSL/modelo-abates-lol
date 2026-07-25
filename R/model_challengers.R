#' Learn quantile bins from training data only
#'
#' @param data Training data.
#' @param feature_names Numeric features.
#' @param bins Requested number of bins.
#' @return Quantile-bin preprocessing object.
#' @export
fit_quantile_bins <- function(data, feature_names, bins = 5L) {
  if (bins < 2L || !all(feature_names %in% names(data))) {
    stop("Quantile-bin specification is invalid.", call. = FALSE)
  }
  breaks <- lapply(feature_names, function(feature) {
    values <- as.numeric(data[[feature]])
    if (any(!is.finite(values))) {
      stop("Quantile-bin training values must be finite.", call. = FALSE)
    }
    interior <- stats::quantile(
      values,
      probs = seq(0, 1, length.out = bins + 1L)[-c(1L, bins + 1L)],
      names = FALSE,
      type = 8
    )
    unique(c(-Inf, interior, Inf))
  })
  names(breaks) <- feature_names
  structure(
    list(feature_names = feature_names, breaks = breaks),
    class = "lolkills_quantile_bins"
  )
}

#' Apply training quantile bins
#'
#' @param fit Quantile-bin preprocessing object.
#' @param data New data.
#' @return Data frame of fixed-level factors.
#' @export
apply_quantile_bins <- function(fit, data) {
  result <- lapply(fit$feature_names, function(feature) {
    breaks <- fit$breaks[[feature]]
    factor(
      cut(
        as.numeric(data[[feature]]),
        breaks = breaks,
        include.lowest = TRUE,
        labels = FALSE
      ),
      levels = seq_len(length(breaks) - 1L)
    )
  })
  names(result) <- paste0("q_", fit$feature_names)
  as.data.frame(result, stringsAsFactors = TRUE)
}

#' Learn PCA from training features only
#'
#' @param data Training data.
#' @param feature_names Numeric features.
#' @param retained_variance Minimum cumulative explained variance.
#' @return PCA preprocessing object.
#' @export
fit_pca_transform <- function(
  data,
  feature_names,
  retained_variance = 0.9
) {
  if (
    retained_variance <= 0 ||
      retained_variance > 1 ||
      !all(feature_names %in% names(data))
  ) {
    stop("PCA specification is invalid.", call. = FALSE)
  }
  model <- stats::prcomp(
    data[feature_names],
    center = TRUE,
    scale. = TRUE
  )
  explained <- model$sdev^2 / sum(model$sdev^2)
  components <- which(cumsum(explained) >= retained_variance)[[1L]]
  structure(
    list(
      model = model,
      feature_names = feature_names,
      components = components,
      retained_variance = sum(explained[seq_len(components)])
    ),
    class = "lolkills_pca_transform"
  )
}

#' Apply a training PCA transform
#'
#' @param fit PCA preprocessing object.
#' @param data New data.
#' @return Data frame of retained principal components.
#' @export
apply_pca_transform <- function(fit, data) {
  scores <- stats::predict(
    fit$model,
    newdata = data[fit$feature_names]
  )
  scores <- scores[, seq_len(fit$components), drop = FALSE]
  result <- as.data.frame(scores)
  names(result) <- paste0("PC", seq_len(ncol(result)))
  result
}
