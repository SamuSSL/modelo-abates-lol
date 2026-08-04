#' Build point-in-time challenger features proposed in the external memo
#'
#' @param maps Frozen map feature rows in chronological order.
#' @param rw_gain Fixed RW1 update gain applied after each completed week.
#' @return Maps with isolated archetype, asymmetric, and global RW1 blocks.
#' @export
build_claude_challenger_features <- function(maps, rw_gain = 0.2) {
  archetypes <- c(
    "engage", "pick", "poke_siege", "dive", "protect",
    "front_to_back", "split_map", "skirmish", "scaling"
  )
  required <- unlist(lapply(archetypes, function(name) {
    paste0(c("blue_draft_", "red_draft_"), name)
  }))
  missing <- setdiff(
    c("game_datetime", "total_kills_game", required),
    names(maps)
  )
  if (length(missing) > 0L) {
    stop("Dados sem features challenger: ", paste(missing, collapse = ", "))
  }
  result <- maps
  blue <- as.matrix(result[paste0("blue_draft_", archetypes)])
  red <- as.matrix(result[paste0("red_draft_", archetypes)])
  blue[!is.finite(blue)] <- 0
  red[!is.finite(red)] <- 0
  result$archetype_distance <- sqrt(rowSums((blue - red)^2))
  denominator <- sqrt(rowSums(blue^2) * rowSums(red^2))
  result$archetype_similarity <- ifelse(
    denominator > 0,
    rowSums(blue * red) / denominator,
    0
  )
  blue_primary <- max.col(blue, ties.method = "first")
  red_primary <- max.col(red, ties.method = "first")
  for (blue_index in seq_along(archetypes)) {
    for (red_index in seq_along(archetypes)) {
      name <- paste0(
        "archetype_pair_",
        archetypes[[blue_index]],
        "_vs_",
        archetypes[[red_index]]
      )
      result[[name]] <- as.numeric(
        blue_primary == blue_index & red_primary == red_index
      )
    }
  }
  result$asym_engage_exposure <- blue[, "blue_draft_engage"] *
    (1 - red[, "red_draft_protect"]) +
    red[, "red_draft_engage"] * (1 - blue[, "blue_draft_protect"])
  result$asym_dive_exposure <- blue[, "blue_draft_dive"] *
    (1 - red[, "red_draft_front_to_back"]) +
    red[, "red_draft_dive"] * (1 - blue[, "blue_draft_front_to_back"])
  result$asym_poke_exposure <- blue[, "blue_draft_poke_siege"] *
    (1 - red[, "red_draft_engage"]) +
    red[, "red_draft_poke_siege"] * (1 - blue[, "blue_draft_engage"])
  result$asym_scaling_pressure <- blue[, "blue_draft_scaling"] *
    red[, "red_draft_engage"] +
    red[, "red_draft_scaling"] * blue[, "blue_draft_engage"]

  order_index <- order(result$game_datetime, result$gameid)
  dates <- as.POSIXct(result$game_datetime[order_index], tz = "UTC")
  weeks <- format(dates, "%G-%V", tz = "UTC")
  outcomes <- as.numeric(result$total_kills_game[order_index])
  state <- 25.5
  rw <- numeric(length(outcomes))
  completed <- numeric()
  current_week <- weeks[[1L]]
  for (index in seq_along(outcomes)) {
    if (!identical(weeks[[index]], current_week)) {
      if (length(completed) > 0L) {
        state <- state + rw_gain * (mean(completed) - state)
      }
      completed <- numeric()
      current_week <- weeks[[index]]
    }
    rw[[index]] <- state
    completed <- c(completed, outcomes[[index]])
  }
  result$global_weekly_rw1 <- NA_real_
  result$global_weekly_rw1[order_index] <- rw
  result
}
