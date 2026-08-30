script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

targets <- data.frame(
  canonical_league = c(
    "TCL", "TCL", "TCL", "PRM", "PRM", "PRM", "PRM"
  ),
  competition = c(
    "TCL", "TCL Season Cup", "TCL Winter",
    "Prime League 1st Division", "Prime Pokal",
    "Prime Super Cup", "PRM Super Cup"
  ),
  league_id = c(
    197466L, 233840L, 218180L, 218127L, 230302L, 222570L, 222941L
  ),
  stringsAsFactors = FALSE
)
raw_root <- file.path(project_root, "data", "raw", "bettingiscool")
window_starts <- seq(as.Date("2025-05-01"), as.Date("2026-08-06"), by = 90)
rows <- list()

for (target_index in seq_len(nrow(targets))) {
  target <- targets[target_index, , drop = FALSE]
  competition_rows <- list()
  for (window_start in window_starts) {
    window_start <- as.Date(window_start, origin = "1970-01-01")
    window_end <- min(window_start + 90, as.Date("2026-08-06"))
    query <- list(
      sport_id = 12L,
      league_id = target$league_id[[1L]],
      starts_from = paste0(window_start, "T00:00:00Z"),
      starts_to = paste0(window_end, "T00:00:00Z"),
      live = 0L,
      limit = 1000L
    )
    message(
      "Auditando ", target$competition[[1L]], " de ",
      window_start, " a ", window_end
    )
    response <- bettingiscool_request("/api/fixtures", query = query)
    write_bettingiscool_raw_response(response, raw_root)
    data <- .bettingiscool_as_data_frame(response$data)
    if (nrow(data) > 0L) {
      competition_rows[[length(competition_rows) + 1L]] <- data
    }
  }
  data <- if (length(competition_rows) > 0L) {
    unique(do.call(rbind, competition_rows))
  } else {
    data.frame()
  }
  if (nrow(data) == 0L) {
    rows[[target_index]] <- data.frame(
      canonical_league = target$canonical_league,
      competition = target$competition,
      league_id = target$league_id,
      fixtures = 0L,
      regular_events = 0L,
      kills_events = 0L,
      first_start = NA_character_,
      last_start = NA_character_,
      stringsAsFactors = FALSE
    )
    next
  }
  rows[[target_index]] <- data.frame(
    canonical_league = target$canonical_league,
    competition = target$competition,
    league_id = target$league_id,
    fixtures = nrow(data),
    regular_events = sum(data$resulting_unit == "Regular", na.rm = TRUE),
    kills_events = sum(data$resulting_unit == "Kills", na.rm = TRUE),
    first_start = min(as.character(data$starts), na.rm = TRUE),
    last_start = max(as.character(data$starts), na.rm = TRUE),
    stringsAsFactors = FALSE
  )
}

coverage <- do.call(rbind, rows)
output_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "market-structural-v2",
  "league-expansion"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  coverage,
  file.path(output_dir, "bettingiscool-competition-coverage.csv"),
  row.names = FALSE
)
print(coverage, row.names = FALSE)
