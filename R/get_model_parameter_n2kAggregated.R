#' @rdname get_model_parameter
#' @importFrom methods setMethod new
#' @importFrom dplyr mutate_all funs
#' @importFrom stats quantile
#' @include n2kAggregate_class.R
#' @include n2kParameter_class.R
setMethod(
  f = "get_model_parameter",
  signature = signature(analysis = "n2kAggregate"),
  definition = function(analysis, ...){
    if (status(analysis) != "converged") {
      return(new("n2kParameter"))
    }

    parameter <- data.frame(
      Description = "AggregatedImputed",
      Parent = NA_character_,
      Fingerprint = sha1(c("AggregatedImputed", NA_character_)),
      stringsAsFactors = FALSE
    )
    observations <- analysis@AggregatedImputed@Covariate %>%
      mutate_all(funs("as.character")) %>%
      mutate_(Parent = ~parameter$Fingerprint)
    for (i in colnames(analysis@AggregatedImputed@Covariate)) {
      extra <- observations %>%
        distinct_(~Parent) %>%
        mutate_(Description = ~i) %>%
        rowwise() %>%
        mutate_(
          Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
        )
      observations <- observations %>%
        inner_join(
          extra %>%
            select_(~Parent, ~Fingerprint),
          by = "Parent"
        ) %>%
        mutate_(Parent = ~Fingerprint) %>%
        select_(~-Fingerprint)
      parameter <- bind_rows(parameter, extra)
      extra <- observations %>%
        distinct_(~Parent, i) %>%
        transmute_(
          ~Parent,
          Description = i
        ) %>%
        rowwise() %>%
        mutate_(
          Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
        )
      link <- c("Parent", "Description")
      names(link) <- c("Parent", i)
      observations <- observations %>%
        inner_join(extra, by = link) %>%
        mutate_(Parent = ~Fingerprint) %>%
        select_(~-Fingerprint)
      parameter <- bind_rows(parameter, extra)
    }
    new(
      "n2kParameter",
      Parameter = parameter,
      ParameterEstimate = analysis@AggregatedImputed@Imputation %>%
        apply(1, quantile, c(0.5, 0.025, 0.975)) %>%
        t() %>%
        as.data.frame() %>%
        select_(
          Estimate = ~1,
          LowerConfidenceLimit = ~2,
          UpperConfidenceLimit = ~3
        ) %>%
        mutate_(
          Analysis = ~get_file_fingerprint(analysis),
          Parameter = ~extra$Fingerprint
        )
    )
  }
)
