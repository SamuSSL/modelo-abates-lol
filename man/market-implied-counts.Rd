\name{market-implied-counts}
\alias{invert_market_count_mean}
\alias{estimate_historical_team_kill_dispersion}
\alias{derive_market_implied_team_kills}
\alias{score_market_implied_team_kills}
\title{Derive and score market-implied count expectations}
\description{
Utilities for inverting no-vig market probabilities into count expectations,
estimating historical Negative-Binomial dispersion before a fixed cutoff, and
scoring Poisson or Negative-Binomial predictive distributions.
}
\usage{
invert_market_count_mean(
  line,
  probability_over,
  distribution = c("poisson", "negative_binomial"),
  theta = NA_real_,
  tolerance = 1e-10
)

estimate_historical_team_kill_dispersion(
  games,
  cutoff = as.POSIXct("2025-05-01 00:00:00", tz = "UTC"),
  minimum_maps = 500L
)

derive_market_implied_team_kills(
  data,
  distribution = c("poisson", "negative_binomial"),
  theta = NA_real_
)

score_market_implied_team_kills(
  data,
  distribution = c("poisson", "negative_binomial"),
  theta = NA_real_,
  mean_distribution = distribution,
  tail_tolerance = 1e-10
)
}
\arguments{
  \item{line}{Offered count line.}
  \item{probability_over}{No-vig Over probability.}
  \item{distribution}{Either \code{poisson} or
  \code{negative_binomial}.}
  \item{theta}{Scalar or row-specific Negative-Binomial size parameter.}
  \item{tolerance}{Root-finding tolerance.}
  \item{games}{Canonical map records.}
  \item{cutoff}{Latest excluded timestamp for dispersion training.}
  \item{minimum_maps}{Minimum number of eligible maps.}
  \item{data}{Normalized team-total observations.}
  \item{mean_distribution}{Distribution inverted to obtain the mean.}
  \item{tail_tolerance}{Maximum unrepresented PMF tail probability.}
}
\value{
\code{invert_market_count_mean()} returns a numeric mean.
\code{estimate_historical_team_kill_dispersion()} returns estimates and
training metadata. The derivation and scoring functions return data frames
with market probabilities, implied means, and predictive diagnostics.
}
