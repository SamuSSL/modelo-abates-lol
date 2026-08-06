.league_config_path <- function() {
  configured <- getOption("lolkills.leagues_config", NA_character_)
  if (!is.na(configured) && nzchar(configured)) {
    return(configured)
  }

  project_path <- file.path("config", "leagues.yml")
  if (file.exists(project_path)) {
    return(project_path)
  }

  installed_path <- system.file(
    "config",
    "leagues.yml",
    package = "lolkills"
  )
  if (nzchar(installed_path)) {
    return(installed_path)
  }

  project_path
}

.read_league_config <- function(config_path = .league_config_path()) {
  if (!file.exists(config_path)) {
    stop("League configuration does not exist: ", config_path, call. = FALSE)
  }

  config <- yaml::read_yaml(config_path)
  required <- c(
    "target_leagues",
    "canonical_mapping",
    "auxiliary_competitions"
  )
  missing <- setdiff(required, names(config))
  if (length(missing) > 0L) {
    stop(
      "Missing league configuration fields: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  config
}

#' Return the canonical target leagues
#'
#' @param config_path Path to the league configuration.
#' @return Character vector of target leagues.
#' @export
canonical_target_leagues <- function(config_path = .league_config_path()) {
  as.character(.read_league_config(config_path)$target_leagues)
}

#' Map raw competition codes to canonical target leagues
#'
#' @param league Raw Oracle's Elixir league codes.
#' @param config_path Path to the league configuration.
#' @return Character vector. Non-target competitions are `NA`.
#' @export
canonicalize_league <- function(
  league,
  config_path = .league_config_path()
) {
  config <- .read_league_config(config_path)
  mapping <- unlist(config$canonical_mapping, use.names = TRUE)
  result <- unname(mapping[as.character(league)])
  result[is.na(result) | result == ""] <- NA_character_
  result
}

#' Classify competition use in the project
#'
#' @param league Raw Oracle's Elixir league codes.
#' @param config_path Path to the league configuration.
#' @return One of `target`, `auxiliary`, or `excluded`.
#' @export
classify_competition_role <- function(
  league,
  config_path = .league_config_path()
) {
  config <- .read_league_config(config_path)
  canonical <- canonicalize_league(league, config_path)
  auxiliary <- as.character(config$auxiliary_competitions)

  result <- rep("excluded", length(league))
  result[as.character(league) %in% auxiliary] <- "auxiliary"
  result[!is.na(canonical)] <- "target"
  result
}
