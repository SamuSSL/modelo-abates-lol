\name{build_synthetic_pinnacle_features}
\alias{build_synthetic_pinnacle_features}
\title{Build side-invariant pre-opening features}
\usage{
build_synthetic_pinnacle_features(data, windows = c("season", "last15"))
}
\arguments{
\item{data}{Map rows with leakage-safe team ratings.}
\item{windows}{Rating windows to include.}
}
\value{A data frame of numeric pre-opening features.}
\description{
Builds symmetric team-pair features for forecasting the last prematch
Pinnacle distribution without moneyline, side assignment, or soft-book prices.
}
