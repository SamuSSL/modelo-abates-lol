#' Assess operational team-history eligibility
#'
#' @param blue_team Blue-side team name.
#' @param red_team Red-side team name.
#' @param blue_effective_games Recent effective Blue history.
#' @param red_effective_games Recent effective Red history.
#' @param minimum_effective_games Approved operational minimum.
#' @return Eligibility status, blocked entities, threshold, and warning.
#' @export
assess_team_sample_eligibility <- function(
  blue_team,
  red_team,
  blue_effective_games,
  red_effective_games,
  minimum_effective_games
) {
  if (
    length(minimum_effective_games) != 1L ||
      !is.finite(minimum_effective_games) ||
      minimum_effective_games < 0
  ) {
    stop(
      "minimum_effective_games must be finite and non-negative.",
      call. = FALSE
    )
  }
  teams <- as.character(c(blue_team, red_team))
  effective_games <- as.numeric(c(
    blue_effective_games,
    red_effective_games
  ))
  insufficient <- !is.finite(effective_games) |
    effective_games < minimum_effective_games
  blocked_entities <- teams[insufficient]
  if (length(blocked_entities) == 0L) {
    return(list(
      status = "ok",
      blocked_entities = character(),
      minimum_effective_games = minimum_effective_games,
      warning = NULL
    ))
  }
  entity_text <- paste(blocked_entities, collapse = " e ")
  list(
    status = "blocked",
    blocked_entities = blocked_entities,
    minimum_effective_games = minimum_effective_games,
    warning = paste0(
      "Pouca amostra para ",
      entity_text,
      ". N\u00e3o apostar."
    )
  )
}
