#' Audit the structural contract of one Oracle's Elixir CSV
#'
#' @param path Path to a seasonal CSV file.
#' @param expected_rows_per_game Expected player plus team rows per game.
#' @return A one-row data frame with structural counts.
#' @export
audit_oe_file <- function(path, expected_rows_per_game = 12L) {
  if (length(path) != 1L || is.na(path) || !file.exists(path)) {
    stop("Audit file does not exist: ", path, call. = FALSE)
  }
  if (
    length(expected_rows_per_game) != 1L ||
    is.na(expected_rows_per_game) ||
    expected_rows_per_game < 1L
  ) {
    stop("expected_rows_per_game must be a positive integer.", call. = FALSE)
  }

  header <- names(
    data.table::fread(
      path,
      nrows = 0L,
      showProgress = FALSE,
      encoding = "UTF-8"
    )
  )
  validate_oe_schema(header)

  audit_columns <- c(
    "gameid",
    "position",
    "league",
    "datacompleteness",
    "date"
  )
  rows <- data.table::fread(
    path,
    select = audit_columns,
    showProgress = FALSE,
    encoding = "UTF-8",
    na.strings = c("", "NA")
  )

  game_ids <- as.character(rows$gameid)
  if (anyNA(game_ids) || any(game_ids == "")) {
    stop("Audit found rows without gameid.", call. = FALSE)
  }

  game_row_counts <- table(game_ids)
  completeness <- table(as.character(rows$datacompleteness))
  dates <- as.character(rows$date)
  dates <- dates[!is.na(dates) & dates != ""]

  data.frame(
    file_name = basename(path),
    schema_valid = TRUE,
    column_count = length(header),
    row_count = nrow(rows),
    game_count = length(game_row_counts),
    games_with_12_rows = sum(
      game_row_counts == as.integer(expected_rows_per_game)
    ),
    games_with_invalid_row_count = sum(
      game_row_counts != as.integer(expected_rows_per_game)
    ),
    team_row_count = sum(
      tolower(as.character(rows$position)) == "team",
      na.rm = TRUE
    ),
    complete_row_count = unname(completeness["complete"] %||% 0L),
    partial_row_count = unname(completeness["partial"] %||% 0L),
    date_min = if (length(dates) > 0L) min(dates) else NA_character_,
    date_max = if (length(dates) > 0L) max(dates) else NA_character_,
    stringsAsFactors = FALSE
  )
}

`%||%` <- function(x, y) {
  if (length(x) == 0L || is.na(x)) y else x
}

