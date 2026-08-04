.bettingiscool_default_base_url <- "https://api.bettingiscool.com"

.bettingiscool_scalar <- function(value, default = NA_character_) {
  if (is.null(value) || length(value) == 0L || is.na(value[[1L]])) {
    return(default)
  }
  as.character(value[[1L]])
}

.bettingiscool_query_url <- function(base_url, endpoint, query = list()) {
  endpoint <- paste0("/", sub("^/+", "", endpoint))
  url <- paste0(sub("/+$", "", base_url), endpoint)
  if (length(query) == 0L) {
    return(url)
  }
  keep <- !vapply(query, function(value) {
    is.null(value) || length(value) == 0L || is.na(value[[1L]])
  }, logical(1L))
  query <- query[keep]
  if (length(query) == 0L) {
    return(url)
  }
  encoded <- vapply(names(query), function(name) {
    value <- paste(as.character(query[[name]]), collapse = ",")
    paste0(
      utils::URLencode(name, reserved = TRUE),
      "=",
      utils::URLencode(value, reserved = TRUE)
    )
  }, character(1L))
  paste0(url, "?", paste(encoded, collapse = "&"))
}

.bettingiscool_parse_headers <- function(raw_headers) {
  parsed <- curl::parse_headers_list(raw_headers)
  if (length(parsed) == 0L) {
    return(list())
  }
  names(parsed) <- tolower(names(parsed))
  parsed
}

.bettingiscool_default_transport <- function(url, api_key) {
  handle <- curl::new_handle()
  curl::handle_setheaders(
    handle,
    "X-API-Key" = api_key,
    "Accept" = "application/json"
  )
  curl::handle_setopt(
    handle,
    connecttimeout = 15,
    timeout = 120,
    followlocation = TRUE
  )
  response <- curl::curl_fetch_memory(url, handle = handle)
  list(
    status_code = as.integer(response$status_code),
    headers = .bettingiscool_parse_headers(response$headers),
    content = rawToChar(response$content)
  )
}

.bettingiscool_header <- function(headers, name, default = NA_character_) {
  value <- headers[[tolower(name)]]
  .bettingiscool_scalar(value, default)
}

#' Request data from the BettingIsCool API
#'
#' @param endpoint API endpoint beginning with `/api/`.
#' @param query Named query parameters.
#' @param api_key API key. Defaults to `BETTINGISCOOL_API_KEY`.
#' @param base_url API base URL.
#' @param max_retries Maximum retries for 429 and server errors.
#' @param transport Injectable HTTP transport used by tests.
#' @param sleeper Injectable sleep function used by tests.
#' @return Response metadata, parsed data, and raw response text.
#' @export
bettingiscool_request <- function(
  endpoint,
  query = list(),
  api_key = Sys.getenv("BETTINGISCOOL_API_KEY", unset = ""),
  base_url = .bettingiscool_default_base_url,
  max_retries = 5L,
  transport = .bettingiscool_default_transport,
  sleeper = Sys.sleep
) {
  if (!nzchar(api_key)) {
    stop(
      "Defina BETTINGISCOOL_API_KEY antes de consultar a API.",
      call. = FALSE
    )
  }
  if (
    !is.list(query) ||
    (length(query) > 0L && is.null(names(query)))
  ) {
    stop("query deve ser uma lista nomeada.", call. = FALSE)
  }
  request_url <- .bettingiscool_query_url(base_url, endpoint, query)
  attempt <- 0L
  repeat {
    attempt <- attempt + 1L
    response <- transport(request_url, api_key)
    status_code <- as.integer(response$status_code)
    retryable <- status_code == 429L || status_code >= 500L
    if (!retryable || attempt > as.integer(max_retries)) {
      break
    }
    retry_after <- suppressWarnings(as.numeric(
      .bettingiscool_header(response$headers, "retry-after", NA_character_)
    ))
    if (!is.finite(retry_after) || retry_after < 0) {
      retry_after <- min(2^(attempt - 1L), 30)
    }
    sleeper(retry_after)
  }
  if (status_code < 200L || status_code >= 300L) {
    stop(
      paste0(
        "BettingIsCool retornou HTTP ",
        status_code,
        " em ",
        endpoint,
        "."
      ),
      call. = FALSE
    )
  }
  content <- as.character(response$content)
  parsed <- if (!nzchar(trimws(content))) {
    list()
  } else {
    jsonlite::fromJSON(content, simplifyVector = TRUE)
  }
  list(
    endpoint = endpoint,
    query = query,
    request_url = request_url,
    retrieved_at = format(
      Sys.time(),
      tz = "UTC",
      format = "%Y-%m-%dT%H:%M:%OSZ"
    ),
    status_code = status_code,
    quota_limit = suppressWarnings(as.numeric(
      .bettingiscool_header(response$headers, "x-quota-limit")
    )),
    quota_remaining = suppressWarnings(as.numeric(
      .bettingiscool_header(response$headers, "x-quota-remaining")
    )),
    quota_cost = suppressWarnings(as.numeric(
      .bettingiscool_header(response$headers, "x-quota-cost")
    )),
    row_count = suppressWarnings(as.numeric(
      .bettingiscool_header(response$headers, "x-rows", "0")
    )),
    truncated = identical(
      tolower(.bettingiscool_header(
        response$headers,
        "x-truncated",
        "false"
      )),
      "true"
    ),
    data = parsed,
    raw_text = content
  )
}

.bettingiscool_as_data_frame <- function(data) {
  if (is.data.frame(data)) {
    return(data)
  }
  if (is.list(data) && length(data) == 0L) {
    return(data.frame())
  }
  if (is.list(data)) {
    rows <- lapply(data, function(row) {
      as.data.frame(row, stringsAsFactors = FALSE)
    })
    result <- do.call(rbind, rows)
    rownames(result) <- NULL
    return(result)
  }
  stop("Resposta da API nao possui formato tabular.", call. = FALSE)
}

.bettingiscool_add_missing <- function(data, columns) {
  for (column in columns) {
    if (!column %in% names(data)) {
      data[[column]] <- rep(NA, nrow(data))
    }
  }
  data
}

#' Validate the map-kills market contract
#'
#' @param odds Odds rows from `/api/odds`, `/api/opening`, or `/api/closing`.
#' @return `TRUE` invisibly when the contract is valid.
#' @export
validate_bettingiscool_kills_contract <- function(odds) {
  odds <- .bettingiscool_as_data_frame(odds)
  required <- c(
    "event_id",
    "period",
    "market",
    "line",
    "odds1",
    "odds2",
    "todds1",
    "todds2"
  )
  missing <- setdiff(required, names(odds))
  if (length(missing) > 0L) {
    stop(
      "Resposta de odds sem campos obrigatorios: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (nrow(odds) == 0L) {
    stop("Resposta de odds vazia nao confirma o contrato.", call. = FALSE)
  }
  if (any(tolower(as.character(odds$market)) != "totals")) {
    stop("Contrato de kills aceita somente market=totals.", call. = FALSE)
  }
  periods <- suppressWarnings(as.integer(odds$period))
  if (anyNA(periods) || any(periods < 1L)) {
    stop("period deve identificar um mapa positivo.", call. = FALSE)
  }
  decimal_columns <- c("odds1", "odds2", "todds1", "todds2")
  valid_decimal <- vapply(decimal_columns, function(column) {
    values <- suppressWarnings(as.numeric(odds[[column]]))
    all(is.finite(values) & values > 1)
  }, logical(1L))
  if (!all(valid_decimal)) {
    stop("Odds e true odds devem ser decimais maiores que 1.", call. = FALSE)
  }
  invisible(TRUE)
}

#' Normalize BettingIsCool map-kills odds
#'
#' The documented standard-market convention is fixed as
#' `odds1/todds1 = Over` and `odds2/todds2 = Under`.
#'
#' @param odds Raw odds rows.
#' @param retrieved_at Retrieval timestamp.
#' @param snapshot_type `history`, `opening`, or `closing`.
#' @return Normalized odds rows with deterministic snapshot identifiers.
#' @export
normalize_bettingiscool_kills_odds <- function(
  odds,
  retrieved_at,
  snapshot_type = "history"
) {
  odds <- .bettingiscool_as_data_frame(odds)
  validate_bettingiscool_kills_contract(odds)
  odds <- .bettingiscool_add_missing(
    odds,
    c(
      "line_id",
      "alt_line_id",
      "timestamp",
      "cutoff",
      "status",
      "max_win",
      "result_status",
      "score_home",
      "score_away"
    )
  )
  normalized <- data.frame(
    provider = "bettingiscool",
    event_id = as.character(odds$event_id),
    period = as.integer(odds$period),
    market = tolower(as.character(odds$market)),
    line = as.numeric(odds$line),
    line_id = as.character(odds$line_id),
    alt_line_id = as.character(odds$alt_line_id),
    odds_over = as.numeric(odds$odds1),
    odds_under = as.numeric(odds$odds2),
    true_odds_over = as.numeric(odds$todds1),
    true_odds_under = as.numeric(odds$todds2),
    odds_timestamp = as.character(odds$timestamp),
    market_cutoff = as.character(odds$cutoff),
    market_status = suppressWarnings(as.integer(odds$status)),
    max_win = suppressWarnings(as.numeric(odds$max_win)),
    result_status = suppressWarnings(as.integer(odds$result_status)),
    score_home = suppressWarnings(as.numeric(odds$score_home)),
    score_away = suppressWarnings(as.numeric(odds$score_away)),
    snapshot_type = as.character(snapshot_type),
    retrieved_at = as.character(retrieved_at),
    stringsAsFactors = FALSE
  )
  normalized$snapshot_id <- vapply(
    seq_len(nrow(normalized)),
    function(index) {
      digest::digest(
        paste(
          normalized$provider[[index]],
          normalized$event_id[[index]],
          normalized$period[[index]],
          normalized$market[[index]],
          normalized$line[[index]],
          normalized$line_id[[index]],
          normalized$alt_line_id[[index]],
          normalized$odds_timestamp[[index]],
          normalized$snapshot_type[[index]],
          sep = "|"
        ),
        algo = "sha256",
        serialize = FALSE
      )
    },
    character(1L)
  )
  normalized
}
