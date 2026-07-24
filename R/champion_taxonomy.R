.champion_taxonomy_columns <- function() {
  c(
    "champion",
    "tank",
    "fighter",
    "assassin",
    "mage",
    "marksman",
    "support",
    "attack",
    "defense",
    "magic",
    "difficulty"
  )
}

#' Read a static champion taxonomy
#'
#' @param path YAML taxonomy path.
#' @return Data frame with one row per champion.
#' @export
read_champion_taxonomy <- function(path) {
  document <- yaml::read_yaml(path)
  if (is.null(document$champions) || length(document$champions) == 0L) {
    stop("Champion taxonomy is empty.", call. = FALSE)
  }
  rows <- lapply(document$champions, function(champion) {
    as.data.frame(champion, stringsAsFactors = FALSE)
  })
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  validate_champion_taxonomy(result)
  result
}

#' Validate the static champion taxonomy
#'
#' @param taxonomy Data frame with one row per champion.
#' @param required_champions Champions that must be covered.
#' @return `TRUE` invisibly when valid.
#' @export
validate_champion_taxonomy <- function(
  taxonomy,
  required_champions = character()
) {
  missing_columns <- setdiff(
    .champion_taxonomy_columns(),
    names(taxonomy)
  )
  if (length(missing_columns) > 0L) {
    stop(
      "Missing taxonomy columns: ",
      paste(missing_columns, collapse = ", "),
      call. = FALSE
    )
  }
  if (anyNA(taxonomy$champion) ||
      any(!nzchar(as.character(taxonomy$champion))) ||
      anyDuplicated(as.character(taxonomy$champion))) {
    stop("Taxonomy champion names must be unique.", call. = FALSE)
  }
  score_columns <- c("attack", "defense", "magic", "difficulty")
  valid_scores <- vapply(
    taxonomy[score_columns],
    function(values) {
      values <- as.numeric(values)
      all(is.finite(values) & values >= 0 & values <= 1)
    },
    logical(1L)
  )
  if (!all(valid_scores)) {
    stop("Taxonomy scores must be between zero and one.", call. = FALSE)
  }
  missing_champions <- setdiff(
    required_champions,
    as.character(taxonomy$champion)
  )
  if (length(missing_champions) > 0L) {
    stop(
      "Missing taxonomy champions: ",
      paste(missing_champions, collapse = ", "),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

#' Score a champion composition with the static taxonomy
#'
#' @param champions Character vector of champion names.
#' @param taxonomy Valid champion taxonomy.
#' @return One-row data frame of transparent composition scores.
#' @export
score_composition_archetypes <- function(champions, taxonomy) {
  champions <- as.character(champions)
  if (anyDuplicated(champions)) {
    stop("Duplicate champions are not allowed.", call. = FALSE)
  }
  validate_champion_taxonomy(taxonomy, champions)
  rows <- taxonomy[match(champions, taxonomy$champion), , drop = FALSE]
  role_count <- function(column) {
    sum(as.logical(rows[[column]]))
  }
  scores <- data.frame(
    champion_count = as.integer(length(champions)),
    frontline_score = mean(
      0.6 * as.numeric(rows$defense) +
        0.4 * (as.numeric(rows$tank) | as.numeric(rows$fighter))
    ),
    damage_score = mean(as.numeric(rows$attack)),
    magic_score = mean(as.numeric(rows$magic)),
    burst_score = mean(
      as.numeric(rows$assassin) | as.numeric(rows$mage)
    ),
    utility_score = mean(
      as.numeric(rows$support) | as.numeric(rows$tank)
    ),
    execution_difficulty = mean(as.numeric(rows$difficulty)),
    tank_count = role_count("tank"),
    fighter_count = role_count("fighter"),
    assassin_count = role_count("assassin"),
    mage_count = role_count("mage"),
    marksman_count = role_count("marksman"),
    support_count = role_count("support"),
    stringsAsFactors = FALSE
  )
  scores
}
