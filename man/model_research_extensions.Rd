\name{model_research_extensions}
\alias{build_claude_challenger_features}
\alias{recalibrate_oof_idr}
\title{Model research extensions}
\description{
Point-in-time challenger features and prior-fold isotonic distributional
recalibration used by the kill-total research pipeline.
}
\usage{
build_claude_challenger_features(maps, rw_gain = 0.2)

recalibrate_oof_idr(metrics, candidate_id = "idr")
}
\arguments{
\item{maps}{Frozen point-in-time map feature rows.}
\item{rw_gain}{Fixed update gain for the weekly RW1 state.}
\item{metrics}{Out-of-fold probabilistic map metrics.}
\item{candidate_id}{Identifier for recalibrated predictions.}
}
\value{
A data frame containing leakage-safe features or recalibrated OOF map metrics.
}
