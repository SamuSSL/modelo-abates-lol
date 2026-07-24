library(plumber)
library(lolkills)

bundle_path <- Sys.getenv(
  "LOLKILLS_BUNDLE_PATH",
  file.path("app_data", "model_bundle.json")
)
if (!file.exists(bundle_path)) {
  stop("Bundle do modelo não encontrado: ", bundle_path, call. = FALSE)
}
bundle <- jsonlite::read_json(bundle_path, simplifyVector = FALSE)

#* @apiTitle LoL Kills V1
#* @apiDescription Inferência local do bundle promovido.

#* Verificação de saúde
#* @get /health
function() {
  list(
    status = "ok",
    model_version = bundle$metadata$model_version
  )
}

#* Metadados do modelo
#* @get /v1/metadata
function() {
  list(
    metadata = bundle$metadata,
    leagues = bundle$model$league_levels,
    sample_limits = bundle$sample_limits
  )
}

#* Previsão pós-draft
#* @serializer json list(auto_unbox=TRUE, digits=NA)
#* @post /v1/predict
function(req, res) {
  request <- jsonlite::fromJSON(
    req$postBody,
    simplifyVector = FALSE
  )
  result <- predict_portable_request(request, bundle)
  if (identical(result$status, "blocked")) {
    res$status <- 422L
  }
  result
}
