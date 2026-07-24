script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- locate_project_root()

renv::restore(project = project_root, prompt = FALSE)
message("Ambiente renv restaurado em: ", project_root)

