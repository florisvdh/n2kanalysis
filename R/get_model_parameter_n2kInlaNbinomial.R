#' @rdname get_model_parameter
#' @importFrom methods setMethod new
#' @importFrom tibble rownames_to_column
#' @importFrom dplyr data_frame rowwise mutate_ filter_ select_ left_join mutate_ bind_rows transmute_ semi_join
#' @importFrom digest sha1
#' @importFrom INLA inla.tmarginal inla.qmarginal
#' @importFrom assertthat assert_that is.flag noNA
#' @importFrom stats terms
#' @include n2kInlaNbinomial_class.R
#' @include n2kParameter_class.R
setMethod(
  f = "get_model_parameter",
  signature = signature(analysis = "n2kInlaNbinomial"),
  definition = function(analysis, verbose = TRUE, ...){
    assert_that(is.flag(verbose))
    assert_that(noNA(verbose))

    if (analysis@AnalysisMetadata$Status != "converged") {
      return(new("n2kParameter"))
    }
    parameter <- data_frame(
      Description = c(
        "Fixed effect", "Random effect BLUP", "Random effect variance",
        "Fitted", "Overdispersion", "WAIC", "Imputed value"
      ),
      Parent = NA_character_
    ) %>%
      rowwise() %>%
      mutate_(
        Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
      )

    # add fixed effect parameters
    if (verbose) {
      message("    reading model parameters: fixed effects", appendLF = FALSE)
    }
    utils::flush.console()


    variable <- c(
      "Intercept",
      attr(terms(analysis@AnalysisFormula[[1]]), "term.labels")
    )
    variable <- variable[!grepl("f\\(", variable)]

    fixed.effect <- get_model(analysis)$summary.fixed
    row.names(fixed.effect) <- gsub("[\\(|\\)]", "", row.names(fixed.effect))
    parameter.estimate <- data_frame(
      Analysis = analysis@AnalysisMetadata$FileFingerprint,
      Parameter = row.names(fixed.effect),
      Estimate = fixed.effect[, "mean"],
      LowerConfidenceLimit = fixed.effect[, "0.025quant"],
      UpperConfidenceLimit = fixed.effect[, "0.975quant"]
    )
    fixed.parent <- parameter$Fingerprint[
      parameter$Description == "Fixed effect"
    ]
    interaction <- grepl(":", variable)
    main.effect <- variable[!interaction]
    interaction <- variable[interaction]
    for (i in main.effect) {
      present <- grep(paste0("^", i), parameter.estimate$Parameter)
      present <- present[!grepl(":", parameter.estimate$Parameter[present])]
      if (length(present) == 0) {
        next
      }
      extra <- data_frame(
        Description = i,
        Parent = fixed.parent
      ) %>%
        rowwise() %>%
        mutate_(
          Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
        )
      extra.factor <- data_frame(
        Description = gsub(
          paste0("^", i),
          "",
          parameter.estimate$Parameter[present]
        ),
        Parent = extra$Fingerprint
      ) %>%
        filter_(~Description != "")
      if (nrow(extra.factor) == 0) {
        to.merge <- extra %>%
          select_(~-Parent)
      } else {
        extra.factor <- extra.factor %>%
          rowwise() %>%
          mutate_(
            Fingerprint = ~sha1(
              c(Description = Description, Parent = Parent)
            )
          )
        to.merge <- extra.factor %>%
          select_(~-Parent) %>%
          mutate_(Description = ~paste0(i, Description))
      }
      parameter.estimate <- left_join(
        parameter.estimate,
        to.merge,
        by = c("Parameter" = "Description")
      ) %>%
        mutate_(
          Parameter = ~ifelse(is.na(Fingerprint), Parameter, Fingerprint)
        ) %>%
        select_(~-Fingerprint)
      parameter <- bind_rows(parameter, extra, extra.factor)
    }
    for (i in interaction) {
      pattern <- paste0("^", gsub(":", ".*:", i))
      present <- grep(pattern, parameter.estimate$Parameter)
      if (length(present) == 0) {
        next
      }
      extra <- data_frame(
        Description = i,
        Parent = fixed.parent
      ) %>%
        rowwise() %>%
        mutate_(
          Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
        )
      parts <- strsplit(i, ":")[[1]]
      level.name <- gsub(
        paste0("^", parts[1]),
        "",
        parameter.estimate$Parameter[present]
      )
      for (j in parts[-1]) {
        level.name <- gsub(paste0(":", j), ":", level.name)
      }
      extra.factor <- data_frame(
        Description = level.name,
        Parent = extra$Fingerprint
      ) %>%
        filter_(~!grepl("^:*$", Description)) %>%
        rowwise() %>%
        mutate_(
          Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
        )
      if (nrow(extra.factor) > 0) {
        to.merge <- extra.factor %>%
          select_(~-Parent) %>%
          inner_join(
            data_frame(
              Description = level.name,
              Original = parameter.estimate$Parameter[present]
            ),
            by = "Description"
          ) %>%
          select_(
            ~-Description,
            Description = ~Original
          )
      } else {
        to.merge <- extra %>%
          select_(~-Parent)
      }
      parameter.estimate <- left_join(
        parameter.estimate,
        to.merge,
        by = c("Parameter" = "Description")
      ) %>%
        mutate_(
          Parameter = ~ifelse(is.na(Fingerprint), Parameter, Fingerprint)
        ) %>%
        select_(~-Fingerprint)
      parameter <- bind_rows(parameter, extra, extra.factor)
    }

    # add random effect variance
    if (verbose) {
      message(", random effect variance", appendLF = FALSE)
    }
    utils::flush.console()
    re.names <- names(get_model(analysis)$marginals.hyperpar)
    re.names <- re.names[grepl("^Precision for ", re.names)]
    if (length(re.names) > 0) {
      re.variance <- sapply(
        get_model(analysis)$marginals.hyperpar[re.names],
        function(x){
          tryCatch(
            x %>%
              inla.tmarginal(fun = function(x){
                1 / x
              }) %>%
              inla.qmarginal(p = c(0.5, 0.025, 0.975)),
            error = function(e){
              rep(NA_real_, 3)
            }
          )
        }
      ) %>%
        t() %>%
        as.data.frame() %>%
        select_(
          Estimate = ~1,
          LowerConfidenceLimit = ~2,
          UpperConfidenceLimit = ~3
        ) %>%
        rownames_to_column("Parameter") %>%
        mutate_(
          Parameter = ~gsub("^Precision for ", "", Parameter),
          Analysis = ~analysis@AnalysisMetadata$FileFingerprint
        )
      extra <- parameter %>%
        filter_(~is.na(Parent), ~Description == "Random effect variance") %>%
        select_(Parent = ~Fingerprint) %>%
        merge(
          data_frame(Description = re.variance$Parameter)
        ) %>%
        rowwise() %>%
        mutate_(
          Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
        )
      parameter.estimate <- extra %>%
        select_(~-Parent) %>%
        inner_join(re.variance, by = c("Description" = "Parameter")) %>%
        select_(~-Description, Parameter = ~Fingerprint) %>%
        bind_rows(parameter.estimate)
      parameter <- parameter %>% bind_rows(extra)
    }

    # add overdispersion
    if (verbose) {
      message(", overdispersion", appendLF = FALSE)
    }
    utils::flush.console()
    overdispersion <- get_model(analysis)$summary.hyperpar
    overdispersion <- overdispersion[
      grep("size for the nbinomial observations", rownames(overdispersion)),
    ]
    parent <- parameter %>%
      filter_(~is.na(Parent), ~Description == "Overdispersion")
    parameter.estimate <- parameter.estimate %>%
      bind_rows(
        data_frame(
          Analysis = analysis@AnalysisMetadata$FileFingerprint,
          Parameter = parent$Fingerprint,
          Estimate = overdispersion[, "mean"],
          LowerConfidenceLimit = overdispersion[, "0.025quant"],
          UpperConfidenceLimit = overdispersion[, "0.975quant"]
        )
      )


    # add WAIC
    if (verbose) {
      message(", WAIC", appendLF = FALSE)
    }
    utils::flush.console()
    parent <- parameter %>%
      filter_(~is.na(Parent), ~Description == "WAIC")
    parameter.estimate <- parameter.estimate %>%
      bind_rows(
        data_frame(
          Analysis = analysis@AnalysisMetadata$FileFingerprint,
          Parameter = parent$Fingerprint,
          Estimate = get_model(analysis)$waic$waic,
          LowerConfidenceLimit = NA_real_,
          UpperConfidenceLimit = NA_real_
        )
      )

    # add random effect BLUP's
    if (verbose) {
      message(", random effect BLUP's", appendLF = FALSE)
    }
    utils::flush.console()
    if (length(re.names) > 0) {
      blup <- lapply(
        names(get_model(analysis)$summary.random),
        function(i){
          random.effect <- get_model(analysis)$summary.random[[i]]
          if (anyDuplicated(random.effect$ID) == 0) {
            data_frame(
              Analysis = analysis@AnalysisMetadata$FileFingerprint,
              Parent = gsub("^(f|c)", "", i),
              Parameter = as.character(random.effect$ID),
              Estimate = random.effect[, "mean"],
              LowerConfidenceLimit = random.effect[, "0.025quant"],
              UpperConfidenceLimit = random.effect[, "0.975quant"]
            )
          } else {
            if (is.null(analysis@ReplicateName[[i]])) {
              random.effect <- random.effect %>%
                mutate_(
                  Replicate = ~rep(
                    seq_len(n() / n_distinct(ID)),
                    each = n_distinct(ID)
                  )
                )
            } else {
              random.effect <- random.effect %>%
                mutate_(
                  Replicate = ~rep(
                    analysis@ReplicateName[[i]],
                    each = n_distinct(ID)
                  )
                )
            }
            data_frame(
              Analysis = analysis@AnalysisMetadata$FileFingerprint,
              Parent = paste(gsub("^(f|c)", "", i)),
              Replicate = as.character(random.effect[, "Replicate"]),
              Parameter = as.character(random.effect$ID),
              Estimate = random.effect[, "mean"],
              LowerConfidenceLimit = random.effect[, "0.025quant"],
              UpperConfidenceLimit = random.effect[, "0.975quant"]
            )
          }
        }
      ) %>%
        bind_rows()
      blup.fingerprint <- parameter %>%
        semi_join(
          data_frame(
            Description = "Random effect BLUP",
            Parent = NA_character_
          ),
          by = c("Description", "Parent")
        ) %>%
        select_(~Fingerprint) %>%
        unlist()
      blup.parent <- blup %>%
        select_(Original = ~Parent) %>%
        distinct_() %>%
        mutate_(
          Parent = ~gsub(" .*$", "", Original),
          Description = ~gsub("^.* ", "", Original),
          Parent = ~ifelse(Parent == Description, blup.fingerprint, Parent)
        ) %>%
        rowwise() %>%
        mutate_(
          Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
        )
      parameter <- blup.parent %>%
        select_(~- Original) %>%
        bind_rows(parameter)
      blup <- blup.parent %>%
        select_(~Original, Parent = ~Fingerprint) %>%
        inner_join(
          blup,
          by = c("Original" = "Parent")
        ) %>%
        select_(~-Original)

      if ("Replicate" %in% colnames(blup)) {
        blup.parent <- blup %>%
          filter_(~!is.na(Replicate)) %>%
          select_(~Parent, Description = ~Replicate) %>%
          distinct_() %>%
          rowwise() %>%
          mutate_(
            Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
          )
        parameter <- bind_rows(parameter, blup.parent)
        blup <- blup %>%
          left_join(
            blup.parent,
            by = c("Replicate" = "Description", "Parent")
          ) %>%
          mutate_(
            Parent = ~ifelse(is.na(Fingerprint), Parent, Fingerprint)
          ) %>%
          select_(~-Replicate, ~-Fingerprint)
      }
      parameter <- blup %>%
        select_(~Parent, Description = ~Parameter) %>%
        distinct_() %>%
        rowwise() %>%
        mutate_(
          Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
        ) %>%
        bind_rows(parameter)
      parameter.estimate <- blup %>%
        inner_join(parameter, by = c("Parent", "Parameter" = "Description")) %>%
        select_(~-Parent, ~-Parameter, Parameter = ~Fingerprint) %>%
        bind_rows(parameter.estimate)
    }

    # add fitted values
    if (verbose) {
      message(", fitted values")
    }
    utils::flush.console()

    fitted.parent <- parameter %>%
      filter_(~is.na(Parent), ~Description == "Fitted") %>%
      select_(Parent = ~Fingerprint)
    fitted <- get_model(analysis)$summary.fitted.values
    fitted <- data_frame(
      Analysis = analysis@AnalysisMetadata$FileFingerprint,
      Parent = fitted.parent$Parent,
      Estimate = fitted[, "mean"],
      LowerConfidenceLimit = fitted[, "0.025quant"],
      UpperConfidenceLimit = ifelse(
        fitted[, "mean"] > fitted[, "0.975quant"],
        NA_real_,
        fitted[, "0.975quant"]
      )
    ) %>%
      bind_cols(
        get_data(analysis) %>%
          transmute_(Parameter = ~as.character(ObservationID))
      )

    parameter <- fitted.parent %>%
      merge(
        data_frame(Description = fitted$Parameter)
      ) %>%
      rowwise() %>%
      mutate_(
        Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
      ) %>%
      bind_rows(parameter)
    tmp <- fitted %>%
      inner_join(parameter, by = c("Parent", "Parameter" = "Description")) %>%
      select_(~-Parent, ~-Parameter, Parameter = ~Fingerprint)
    parameter.estimate <- bind_rows(tmp, parameter.estimate)

    # imputed values
    if (!is.null(analysis@RawImputed)) {
      ri <- analysis@RawImputed
      extra <- ri@Data %>%
        mutate_(Response = ri@Response) %>%
        filter_(~is.na(Response)) %>%
        select_(~ObservationID) %>%
        mutate_(
          Analysis = ~get_file_fingerprint(analysis),
          Estimate =
            ~apply(ri@Imputation, 1, quantile, probs = 0.500),
          LowerConfidenceLimit =
            ~apply(ri@Imputation, 1, quantile, probs = 0.025),
          UpperConfidenceLimit =
            ~apply(ri@Imputation, 1, quantile, probs = 0.975)
        )
      parent <- parameter %>%
        filter_(~Description == "Imputed value", ~is.na(Parent))
      impute.parameter <- extra %>%
        distinct_(~ObservationID) %>%
        transmute_(
          Parent = ~parent$Fingerprint,
          Description = ~ObservationID
        ) %>%
        rowwise() %>%
        mutate_(
          Fingerprint = ~sha1(c(Description = Description, Parent = Parent))
        )
      parameter <- parameter %>%
        bind_rows(impute.parameter)
      parameter.estimate <- extra %>%
        inner_join(
          impute.parameter,
          by = c("ObservationID" = "Description")
        ) %>%
        select_(
          ~Analysis,
          ~Estimate,
          ~LowerConfidenceLimit,
          ~UpperConfidenceLimit,
          Parameter = ~Fingerprint
        ) %>%
        bind_rows(parameter.estimate)
    }

    new(
      "n2kParameter",
      Parameter = as.data.frame(parameter),
      ParameterEstimate = as.data.frame(parameter.estimate)
    )
  }
)
