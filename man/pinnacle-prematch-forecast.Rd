\name{pinnacle-prematch-forecast}
\alias{derive_total_market_implied_mean}
\alias{build_prematch_forecast_rows}
\alias{fit_prematch_delta_ridge}
\alias{predict_prematch_delta_ridge}
\alias{evaluate_conservative_soft_value}
\title{Forecast the final prematch Pinnacle market}
\description{Builds point-in-time market rows, fits a compact ridge model for
future implied-mean movement, and evaluates conservative soft-book value.}
\usage{
derive_total_market_implied_mean(line, odds_over, odds_under, theta)

build_prematch_forecast_rows(snapshots, theta_column = "theta")

fit_prematch_delta_ridge(data, formula, lambda = 10)

predict_prematch_delta_ridge(model, new_data)

evaluate_conservative_soft_value(mean_low, mean_high, theta, line,
  odds_over, odds_under, minimum_ev = 0.05)
}
\value{Market-implied means, a fitted ridge object, forecast rows, or a
conservative betting decision depending on the called function.}
