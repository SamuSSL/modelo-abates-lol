\name{premap-model}
\alias{build_premap_ratio_features}
\alias{assemble_premap_ratio_map_features}
\alias{derive_multiplicative_expectations}
\alias{fit_premap_multiplicative_model}
\alias{predict_premap_multiplicative_model}
\alias{beta_binomial_kill_allocation}
\alias{fit_regularized_multiplicative_exponents}
\alias{predict_regularized_multiplicative_exponents}
\alias{fit_moneyline_informed_model}
\alias{predict_moneyline_informed_model}
\alias{tilt_pmf_to_kill_market}
\alias{fit_kill_market_tilt_weight}
\alias{predict_kill_market_hybrid}
\title{Pre-map multiplicative and market-informed kill models}
\description{
Builds leakage-safe team ratios, derives coherent directed expectations,
fits Negative Binomial totals with Beta-Binomial allocation, and optionally
adds moneyline and total-market information.
}
\value{
Feature tables, fitted model bundles, or predictive probability mass
functions, depending on the function called.
}
