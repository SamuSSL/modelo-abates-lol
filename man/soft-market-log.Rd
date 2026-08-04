\name{soft-market-log}
\alias{initialize_soft_market_store}
\alias{prepare_soft_market_quote}
\alias{append_soft_market_quote}
\alias{assess_soft_market_edge}
\title{Private soft-book quote log and evidence gate}
\description{
Validates and stores manual soft-book quotes, applies the fixed one-unit and
minimum expected-value rules, and checks the pre-registered evidence gate.
}
\value{
Normalized quote records, inserted-row counts, or an evidence-gate summary.
}
