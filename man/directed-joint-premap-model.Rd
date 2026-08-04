\name{directed-joint-premap-model}
\alias{fit_directed_joint_fundamental}
\alias{predict_directed_joint_fundamental}
\alias{fit_moneyline_joint_correction}
\alias{predict_moneyline_joint_model}
\title{Directed joint pre-map kills model}
\description{
Fits a separate probabilistic duration model and directed team kill
intensities using own attack rates and opponent concession rates. Total kills
use a Negative Binomial distribution, team allocation uses a Beta-Binomial
distribution, and optional continuous no-vig moneyline corrections cover the
full favoritism range.
}
\value{
A fitted fundamental or moneyline-corrected joint model, or predictive
distributions for total and team kills.
}
