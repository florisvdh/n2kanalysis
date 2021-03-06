#' Read a n2kModel object
#' @param x the file fingerprint of the n2kModel
#' @param base the base location to read the model
#' @param project will be a relative path within the base location
#' @name read_model
#' @rdname read_model
#' @exportMethod read_model
#' @docType methods
#' @importFrom methods setGeneric
setGeneric(
  name = "read_model",
  def = function(x, base, project){
    standardGeneric("read_model") # nocov
  }
)

#' @rdname read_model
#' @importFrom methods setMethod new
#' @importFrom assertthat assert_that is.string is.dir
#' @importFrom utils file_test
setMethod(
  f = "read_model",
  signature = signature(base = "character"),
  definition = function(x, base, project){
    assert_that(is.string(x))
    assert_that(is.dir(base))
    assert_that(is.string(project))

    filename <- sprintf("%s/%s", base, project) %>%
      normalizePath() %>%
      list.files(pattern = x, full.names = TRUE, recursive = TRUE)
    filename <- filename[grepl("\\.rds$", filename)]

    if (length(filename) == 1) {
      return(readRDS(filename))
    }

    if (length(filename) == 0) {
      stop("no matching object in directory")
    }
    stop("multiple matching objects in directory")
  }
)

#' @rdname read_model
#' @importFrom methods setMethod new
#' @importFrom assertthat assert_that is.string
#' @importFrom aws.s3 bucket_exists get_bucket s3readRDS
#' @include import_S3_classes.R
setMethod(
  f = "read_model",
  signature = signature(base = "s3_bucket"),
  definition = function(x, base, project){
    assert_that(is.string(x))
    assert_that(is.string(project))

    # try several times to connect to S3 bucket
    # avoids errors due to time out
    i <- 1
    repeat {
      bucket_ok <- tryCatch(
        bucket_exists(base),
        error = function(err) {
          err
        }
      )
      if (is.logical(bucket_ok)) {
        break
      }
      if (i > 10) {
        stop("Unable to connect to S3 bucket")
      }
      message("attempt ", i, " to connect to S3 bucket failed. Trying again...")
      i <- i + 1
      # waiting time between tries increases with the number of tries
      Sys.sleep(i)
    }
    if (!bucket_ok) {
      stop("Unable to connect to S3 bucket")
    }

    # check if object with same fingerprint exists
    available <- get_bucket(base, prefix = project, max = Inf)
    existing <- available[names(available) == "Contents"] %>%
      sapply("[[", "Key")
    matching <- sprintf("%s.rds", x) %>%
      grep(existing)
    if (length(matching) == 1) {
      return(s3readRDS(available[[matching]]))
    }

    if (length(matching) == 0) {
      stop("no matching object in bucket")
    }
    stop("multiple matching objects in bucket")
  }
)

#' @rdname read_model
#' @importFrom methods setMethod new
#' @importFrom assertthat assert_that is.string
#' @importFrom aws.s3 bucket_exists get_bucket s3readRDS
#' @include import_S3_classes.R
setMethod(
  f = "read_model",
  signature = signature(base = "s3_bucket"),
  definition = function(x, base, project){
    assert_that(is.string(x))
    assert_that(is.string(project))

    available <- get_bucket(base, prefix = project, max = Inf)
    existing <- available[names(available) == "Contents"] %>%
      sapply("[[", "Key")
    matching <- sprintf("%s/.*%s[[:xdigit:]]{0,40}\\.rds", project, x) %>%
      grep(existing)
    if (length(matching) == 1) {
      return(s3readRDS(available[[matching]]))
    }

    if (length(matching) == 0) {
      stop("no matching object in bucket")
    }
    stop("multiple matching objects in bucket")
  }
)
