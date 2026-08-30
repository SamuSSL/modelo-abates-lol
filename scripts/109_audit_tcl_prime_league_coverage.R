script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

raw_root <- file.path(project_root, "data", "raw", "oracles_elixir")
files <- list.files(
  raw_root,
  pattern = "^[0-9]{4}_LoL_esports_match_data_from_OraclesElixir[.]csv$",
  full.names = TRUE
)
rows <- lapply(files, function(path) {
  data <- data.table::fread(
    path,
    select = c("gameid", "league", "year", "date", "position"),
    showProgress = FALSE
  )
  data <- data[data$position == "team", ]
  data <- data[grepl(
    "TCL|PRM|Prime",
    data$league,
    ignore.case = TRUE
  ), ]
  unique(data[, .(gameid, league, year, date)])
})
coverage <- data.table::rbindlist(rows, fill = TRUE)
summary <- coverage[, .(
  maps = data.table::uniqueN(gameid),
  first_map = min(as.POSIXct(date, tz = "UTC"), na.rm = TRUE),
  last_map = max(as.POSIXct(date, tz = "UTC"), na.rm = TRUE)
), by = .(league, year)]
data.table::setorder(summary, league, year)

output_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "market-structural-v2",
  "league-expansion"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  summary,
  file.path(output_dir, "oracle-coverage.csv"),
  row.names = FALSE
)
print(summary)
