script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
if (!requireNamespace("plumber", quietly = TRUE)) {
  stop("Instale o pacote plumber antes de iniciar a API.", call. = FALSE)
}
router <- plumber::plumb(file.path(project_root, "api", "plumber.R"))
router$run(host = "127.0.0.1", port = 8000)
