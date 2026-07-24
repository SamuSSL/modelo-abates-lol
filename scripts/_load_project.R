locate_project_root <- function() {
  rprojroot::find_root(rprojroot::has_file("DESCRIPTION"))
}

load_lolkills_project <- function() {
  project_root <- locate_project_root()
  options(
    lolkills.leagues_config = file.path(
      project_root,
      "config",
      "leagues.yml"
    )
  )
  pkgload::load_all(project_root, quiet = TRUE)
  project_root
}

