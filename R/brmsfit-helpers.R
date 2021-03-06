array2list <- function(x) {
  # convert array to list of elements with reduced dimension
  # Args: 
  #   x: an arrary of dimension d
  # Returns: 
  #   A list of arrays of dimension d-1
  if (is.null(dim(x))) stop("Argument x has no dimension")
  ndim <- length(dim(x))
  l <- list(length = dim(x)[ndim])
  ind <- collapse(rep(",", ndim - 1))
  for (i in seq_len(dim(x)[ndim])) {
    l[[i]] <- eval(parse(text = paste0("x[", ind, i,"]"))) 
  }
  names(l) <- dimnames(x)[[ndim]]
  l
}

Nsamples <- function(x, subset = NULL) {
  # compute the number of posterior samples
  # Args:
  #   x: a brmsfit object
  #   subset: a vector defining a subset of samples to be considered
  if (!is(x$fit, "stanfit") || !length(x$fit@sim)) {
    out <- 0
  } else {
    ntsamples <- (x$fit@sim$iter - x$fit@sim$warmup) /
                  x$fit@sim$thin * x$fit@sim$chains
    if (length(subset)) {
      out <- length(subset)
      if (out > ntsamples || max(subset) > ntsamples) {
        stop("invalid 'subset' argument", call. = FALSE)
      }
    } else {
      out <- ntsamples
    }
  }
  out
}

contains_samples <- function(x) {
  if (!is(x$fit, "stanfit") || !length(x$fit@sim)) {
    stop("The model does not contain posterior samples",
         call. = FALSE)
  }
  invisible(TRUE)
}

algorithm <- function(x) {
  stopifnot(is(x, "brmsfit"))
  if (is.null(x$algorithm)) "sampling"
  else x$algorithm
}

restructure <- function(x) {
  # restructure old brmsfit objects to work with the latest brms version
  stopifnot(is(x, "brmsfit"))
  if (isTRUE(attr(x, "restructured"))) {
    return(x)  # already restructured
  }
  if (isTRUE(x$version < utils::packageVersion("brms"))) {
    # element 'nonlinear' deprecated as of brms > 0.9.1
    # element 'partial' deprecated as of brms > 0.8.0
    x$formula <- SW(update_formula(x$formula, partial = x$partial, 
                                   nonlinear = x$nonlinear))
    x$nonlinear <- x$partial <- NULL
    if (is(x$autocor, "cor_fixed")) {
      # deprecated as of brms 1.0.0
      class(x$autocor) <- "cov_fixed"
    }
    ee <- extract_effects(formula(x), family = family(x))
    change <- list()
    if (isTRUE(x$version <= "0.10.0.9000")) {
      attr(x$formula, "old_mv") <- is.old_mv(x)
      x$ranef <- tidy_ranef(ee, model.frame(x))
      if (length(ee$nonlinear)) {
        # nlpar and group have changed positions
        change <- c(change,
          change_old_ranef(x$ranef, pars = parnames(x),
                           dims = x$fit@sim$dims_oi))
      }
    } else if (isTRUE(x$version < "1.0.0")) {
      # I added double underscores in group-level parameters
      # right before the release of brms 1.0.0
      change <- c(change,
        change_old_ranef2(x$ranef, pars = parnames(x),
                          dims = x$fit@sim$dims_oi))
    }
    if (isTRUE(x$version <= "1.0.1")) {
      # names of spline parameters had to be changed after
      # allowing for multiple covariates in one spline term
      change <- c(change,
        change_old_splines(ee, pars = parnames(x),
                           dims = x$fit@sim$dims_oi))
    }
    for (i in seq_along(change)) {
      x <- do_renaming(change = change[[i]], x = x)
    }
  }
  structure(x, "restructured" = TRUE)
}

first_greater <- function(A, target, i = 1) {
  # find the first element in A that is greater than target
  # Args: 
  #   A: a matrix
  #   target: a vector of length nrow(A)
  #   i: column of A being checked first
  # Returns: 
  #   A vector of the same length as target containing the column ids 
  #   where A[,i] was first greater than target
  ifelse(target <= A[, i] | ncol(A) == i, i, first_greater(A, target, i + 1))
}

link <- function(x, link) {
  # apply a link function on x
  # Args:
  #   x: An arrary of arbitrary dimension
  #   link: a character string defining the link
  # Returns:
  #   an array of dimension dim(x) on which the link function was applied
  if (link == "identity") x
  else if (link == "log") log(x)
  else if (link == "inverse") 1/x
  else if (link == "sqrt") sqrt(x)
  else if (link == "1/mu^2") 1 / x^2
  else if (link == "tan_half") tan(x / 2)
  else if (link == "logit") logit(x)
  else if (link == "probit") qnorm(x)
  else if (link == "probit_approx") qnorm(x)
  else if (link == "cloglog") cloglog(x)
  else if (link == "cauchit") qcauchy(x)
  else stop(paste("Link", link, "not supported"))
}

ilink <- function(x, link) {
  # apply the inverse link function on x
  # Args:
  #   x: An arrary of arbitrary dimension
  #   link: a character string defining the link
  # Returns:
  #   an array of dimension dim(x) on which the inverse link function was applied
  if (link == "identity") x
  else if (link == "log") exp(x)
  else if (link == "inverse") 1/x
  else if (link == "sqrt") x^2
  else if (link == "1/mu^2") 1 / sqrt(x)
  else if (link == "tan_half") 2 * atan(x)
  else if (link == "logit") inv_logit(x)
  else if (link == "probit") pnorm(x)
  else if (link == "probit_approx") inv_logit(0.07056*x^3 + 1.5976*x)
  else if (link == "cloglog") inv_cloglog(x)
  else if (link == "cauchit") pcauchy(x)
  else stop(paste("Link", link, "not supported"))
}

get_cornames <- function(names, type = "cor", brackets = TRUE,
                         sep = "__") {
  # get correlation names as combinations of variable names
  # Args:
  #   names: the variable names 
  #   type: character string to be put in front of the returned strings
  #   brackets: should the correlation names contain brackets 
  #            or underscores as seperators
  #   sep: character string to separate names;
  #        only used if brackets == FALSE
  # Returns: 
  #   correlation names based on the variable names 
  #   passed to the names argument
  cornames <- NULL
  if (length(names) > 1) {
    for (i in 2:length(names)) {
      for (j in 1:(i-1)) {
        if (brackets) {
          cornames <- c(cornames, 
            paste0(type, "(", names[j], "," , names[i], ")"))
        } else {
          cornames <- c(cornames, 
            paste0(type, sep, names[j], sep, names[i]))
        }
      }
    }
  }
  cornames
}

get_nlpar <- function(x, suffix = "") {
  # extract name of a non-linear parameter
  nlpar <- attr(x, "nlpar")
  if (length(nlpar) && nchar(nlpar)) paste0(nlpar, suffix) else ""
}

get_estimate <- function(coef, samples, margin = 2, to.array = FALSE, ...) {
  # calculate estimates over posterior samples 
  # Args:
  #   coef: coefficient to be applied on the samples (e.g., "mean")
  #   samples: the samples over which to apply coef
  #   margin: see apply
  #   to.array: logical; should the result be transformed 
  #             into an array of increased dimension?
  #   ...: additional arguments passed to get(coef)
  # Returns: 
  #   typically a matrix with colnames(samples) as colnames
  dots <- list(...)
  args <- list(X = samples, MARGIN = margin, FUN = coef)
  fun_args <- names(formals(coef))
  if (!"..." %in% fun_args) {
    dots <- dots[names(dots) %in% fun_args]
  }
  x <- do.call(apply, c(args, dots))
  if (is.null(dim(x))) {
    x <- matrix(x, dimnames = list(NULL, coef))
  } else if (coef == "quantile") {
    x <- aperm(x, length(dim(x)):1)
  }
  if (to.array && length(dim(x)) == 2) {
    x <- array(x, dim = c(dim(x), 1), 
               dimnames = list(NULL, NULL, coef))
  }
  x 
}

get_summary <- function(samples, probs = c(0.025, 0.975),
                        robust = FALSE) {
  # summarizes parameter samples based on mean, sd, and quantiles
  # Args: 
  #   samples: a matrix or data.frame containing the samples to be summarized. 
  #            rows are samples, columns are parameters
  #   probs: quantiles to be computed
  # Returns:
  #   a N x C matric where N is the number of observations and C 
  #   is equal to \code{length(probs) + 2}.
  if (robust) {
    coefs <- c("median", "mad", "quantile")
  } else {
    coefs <- c("mean", "sd", "quantile")
  }
  if (length(dim(samples)) == 2L) {
    out <- do.call(cbind, lapply(coefs, get_estimate, samples = samples,
                                 probs = probs, na.rm = TRUE))
  } else if (length(dim(samples)) == 3L) {
    out <- abind(lapply(seq_len(dim(samples)[3]), function(i)
      do.call(cbind, lapply(coefs, get_estimate, samples = samples[, , i],
                            probs = probs))), along = 3)
    dimnames(out) <- list(NULL, NULL, paste0("P(Y = ", 1:dim(out)[3], ")")) 
  } else { 
    stop("dimension of 'samples' must be either 2 or 3") 
  }
  rownames(out) <- seq_len(nrow(out))
  colnames(out) <- c("Estimate", "Est.Error", paste0(probs * 100, "%ile"))
  out  
}

get_table <- function(samples, levels = sort(unique(as.numeric(samples)))) {
  # compute absolute frequencies for each column
  # Args:
  #   samples: a S x N matrix
  #   levels: all possible values in \code{samples}
  # Returns:
  #    a N x \code{levels} matrix containing relative frequencies
  #    in each column seperately
  stopifnot(is.matrix(samples))
  out <- do.call(rbind, lapply(seq_len(ncol(samples)), 
    function(n) table(factor(samples[, n], levels = levels))))
  # compute relative frequencies
  out <- out / sum(out[1, ])
  rownames(out) <- seq_len(nrow(out))
  colnames(out) <- paste0("P(Y = ", seq_len(ncol(out)), ")")
  out
}

get_cov_matrix <- function(sd, cor = NULL) {
  # compute covariance and correlation matrices based 
  # on correlation and sd samples
  # Args:
  #   sd: samples of standard deviations
  #   cor: samples of correlations
  # Notes: 
  #   used in VarCorr.brmsfit
  # Returns: 
  #   samples of covariance and correlation matrices
  sd <- as.matrix(sd)
  stopifnot(all(sd >= 0))
  if (!is.null(cor)) {
    cor <- as.matrix(cor)
    stopifnot(ncol(cor) == ncol(sd) * (ncol(sd) - 1) / 2, 
              nrow(sd) == nrow(cor), min(cor) >= -1 && max(cor) <= 1)
  }
  nsamples <- nrow(sd)
  nranef <- ncol(sd)
  cor_matrix <- array(diag(1, nranef), dim = c(nranef, nranef, nsamples))
  cor_matrix <- aperm(cor_matrix, perm = c(3, 1, 2))
  cov_matrix <- cor_matrix
  for (i in seq_len(nranef)) { 
    cov_matrix[, i, i] <- sd[, i]^2
  }
  if (!is.null(cor)) {
    k <- 0 
    for (i in 2:nranef) {
      for (j in 1:(i-1)) {
        k = k + 1
        cor_matrix[, j, i] <- cor_matrix[, i, j] <- cor[, k]
        cov_matrix[, j, i] <- 
          cov_matrix[, i, j] <- cor[, k] * sd[, i] * sd[, j]
      }
    }
  }
  list(cor = cor_matrix, cov = cov_matrix)
}

get_cov_matrix_ar1 <- function(ar, sigma, nrows, se2 = 0) {
  # compute the covariance matrix for an AR1 process
  # Args: 
  #   ar: AR1 autocorrelation samples
  #   sigma: standard deviation samples of the AR1 process
  #   se2: square of user defined standard errors (may be 0)
  #   nrows: number of rows of the covariance matrix
  # Returns:
  #   An nsamples x nrows x nrows AR1 covariance array (!)
  mat <- array(diag(se2, nrows), dim = c(nrows, nrows, nrow(sigma)))
  mat <- aperm(mat, perm = c(3, 1, 2))
  sigma2_adjusted <- sigma^2 / (1 - ar^2)
  pow_ar <- as.list(rep(1, nrows + 1))
  for (i in seq_len(nrows)) {
    pow_ar[[i + 1]] <- ar^i
    mat[, i, i] <- mat[, i, i] + sigma2_adjusted
    for (j in seq_len(i - 1)) { 
      mat[, i, j] <- sigma2_adjusted * pow_ar[[i - j + 1]]
      mat[, j, i] <- mat[, i, j]
    } 
  } 
  mat
}

get_cov_matrix_ma1 <- function(ma, sigma, nrows, se2 = 0) {
  # compute the covariance matrix for an MA1 process
  # Args: 
  #   ma: MA1 autocorrelation samples
  #   sigma: standard deviation samples of the AR1 process
  #   se2: square of user defined standard errors (may be 0)
  #   nrows: number of rows of the covariance matrix
  # Returns:
  #   An nsamples x nrows x nrows MA1 covariance array (!)
  mat <- array(diag(se2, nrows), dim = c(nrows, nrows, nrow(sigma)))
  mat <- aperm(mat, perm = c(3, 1, 2))
  sigma2 <- sigma^2
  sigma2_adjusted <- sigma2 * (1 + ma^2)
  sigma2_times_ma <- sigma2 * ma
  for (i in seq_len(nrows)) { 
    mat[, i, i] <- mat[, i, i] + sigma2_adjusted
    if (i > 1) {
      mat[, i, i - 1] <- sigma2_times_ma
    }
    if (i < nrows) {
      mat[, i, i + 1] <- sigma2_times_ma
    }
  } 
  mat 
}

get_cov_matrix_arma1 <- function(ar, ma, sigma, nrows, se2 = 0) {
  # compute the covariance matrix for an AR1 process
  # Args: 
  #   ar: AR1 autocorrelation sample
  #   ma: MA1 autocorrelation sample
  #   sigma: standard deviation samples of the AR1 process
  #   se2: square of user defined standard errors (may be 0)
  #   nrows: number of rows of the covariance matrix
  # Returns:
  #   An nsamples x nrows x nrows ARMA1 covariance array (!)
  mat <- array(diag(se2, nrows), dim = c(nrows, nrows, nrow(sigma)))
  mat <- aperm(mat, perm = c(3, 1, 2))
  sigma2_adjusted <- sigma^2 / (1 - ar^2)
  gamma0 <- 1 + ma^2 + 2 * ar * ma
  gamma <- as.list(rep(NA, nrows))
  gamma[[1]] <- (1 + ar * ma) * (ar + ma)
  for (i in seq_len(nrows)) {
    mat[, i, i] <- mat[, i, i] + sigma2_adjusted * gamma0
    gamma[[i]] <- gamma[[1]] * ar^(i - 1)
    for (j in seq_len(i - 1)) { 
      mat[, i, j] <- sigma2_adjusted * gamma[[i - j]]
      mat[, j, i] <- mat[, i, j]
    } 
  } 
  mat 
}

get_cov_matrix_ident <- function(sigma, nrows, se2 = 0) {
  # compute a variance matrix without including ARMA parameters
  # only used for ARMA covariance models when incl_autocor = FALSE
  # Args:
  #   sigma: standard deviation samples
  #   se2: square of user defined standard errors (may be 0)
  #   nrows: number of rows of the covariance matrix
  # Returns:
  #   An nsamples x nrows x nrows sigma array
  mat <- array(diag(se2, nrows), dim = c(nrows, nrows, nrow(sigma)))
  mat <- aperm(mat, perm = c(3, 1, 2))
  sigma2 <- sigma^2
  for (i in seq_len(nrows)) {
    mat[, i, i] <- mat[, i, i] + sigma2
  }
  mat
}

get_auxpar <- function(x, i = NULL) {
  # get samples of an auxiliary parameter
  # Args:
  #   x: object to extract postarior samples from
  #   data: data initially passed to Stan
  #   i: the current observation number
  #      (used in predict and logLik)
  if (is.list(x)) {
    # compute auxpar in distributional regression models
    ilink <- get(x[["ilink"]], mode = "function")
    x <- ilink(get_eta(i = if (!is.null(i)) i else NULL, draws = x))
  } else {
    if (!is.null(i) && isTRUE(ncol(x) > 1L)) {
      x <- x[, i, drop = FALSE]
    }
  }
  if (is.null(i) && isTRUE(ncol(x) == 1L)) {
    # for compatibility with fitted helper functions
    x <- as.vector(x)
  }
  x
}

get_sigma <- function(x, data, i = NULL, dim = NULL) {
  # get the residual standard devation of linear models
  # Args: 
  #    see get_auxpar
  #    dim: target dimension of output matrices (used in fitted)
  stopifnot(is.atomic(x) || is.list(x))
  if (is.null(x)) {
    x <- get_se(data = data, i = i, dim = dim)
  } else {
    x <- get_auxpar(x, i = i)
  }
  mult_disp(x, data = data, i = i, dim = dim)
}

get_shape <- function(x, data, i = NULL, dim = NULL) {
  # get the shape parameter of gamma, weibull and negbinomial models
  # Args: see get_auxpar
  stopifnot(is.atomic(x) || is.list(x))
  x <- get_auxpar(x, i = i)
  mult_disp(x, data = data, i = i, dim = dim)
}

get_theta <- function(draws, i = NULL, par = c("zi", "hu")) {
  # convenience function to extract zi / hu parameters
  # also works with deprecated models fitted with brms < 1.0.0 
  # which were using multivariate syntax
  # Args:
  #   see get_auxpar
  #   par: parameter to extract; either 'zi' or 'hu'
  par <- match.arg(par)
  if (!is.null(draws$data$N_trait)) {
    j <- if (!is.null(i)) i else seq_len(draws$data$N_trait)
    theta <- ilink(get_eta(draws, j + draws$data$N_trait), "logit")
  } else {
    theta <- get_auxpar(draws[[par]], i = i)
  }
  theta
}

get_se <- function(data, i = NULL, dim = NULL) {
  # extract user-defined standard errors
  # Args: see get_auxpar
  se <- data$se
  if (is.null(se)) {
    # for backwards compatibility with brms <= 0.5.0
    se <- data$sigma
  }
  if (!is.null(i)) {
    se <- se[i]
  } else {
    stopifnot(!is.null(dim))
    se <- matrix(se, nrow = dim[1], ncol = dim[2], byrow = TRUE)
  }
  se
}

mult_disp <- function(x, data, i = NULL, dim = NULL) {
  # multiply existing samples by 'disp' data
  # Args: see get_auxpar
  if (!is.null(data$disp)) {
    if (!is.null(i)) {
      x <- x * data$disp[i]
    } else {
      # results in a Nsamples x Nobs matrix
      if (is.matrix(x)) {
        stopifnot(!is.null(dim))
        disp <- matrix(disp, nrow = dim[1], ncol = dim[2], byrow = TRUE)
        x <- x * disp
      } else {
        x <- x %*% matrix(data$disp, nrow = 1) 
      }
    }
  }
  x
}

prepare_family <- function(x) {
  # prepare for calling family specific loglik / predict functions
  family <- family(x)
  nresp <- length(extract_effects(x$formula, family = family,
                                  nonlinear = x$nonlinear)$response)
  if (is.old_lognormal(family, nresp = nresp, version = x$version)) {
    family <- lognormal()
  } else if (is.linear(family) && nresp > 1L) {
    family$family <- paste0(family$family, "_mv")
  } else if (use_cov(x$autocor) && sum(x$autocor$p, x$autocor$q) > 0) {
    family$family <- paste0(family$family, "_cov")
  } else if (is(x$autocor, "cov_fixed")) {
    family$family <- paste0(family$family, "_fixed")
  }
  family
}

extract_pars <- function(pars, all_pars, exact_match = FALSE,
                         na_value = all_pars, ...) {
  # extract all valid parameter names that match pars
  # Args:
  #   pars: A character vector or regular expression
  #   all_pars: all parameter names of the fitted model
  #   exact_match: should parnames be matched exactly?
  #   na_value: what should be returned if pars is NA? 
  #   ...: Further arguments to be passed to grepl
  # Returns:
  #   A character vector of parameter names
  if (!(anyNA(pars) || is.character(pars))) {
    stop("Argument pars must be NA or a character vector")
  }
  if (!anyNA(pars)) {
    if (exact_match) {
      pars <- all_pars[all_pars %in% pars]
    } else {
      pars <- all_pars[apply(sapply(pars, grepl, x = all_pars, ...), 1, any)]
    }
  } else {
    pars <- na_value
  }
  pars
}

compute_ic <- function(x, ic = c("waic", "loo"), ll_args = list(), ...) {
  # compute WAIC and LOO using the 'loo' package
  # Args:
  #   x: an object of class brmsfit
  #   ic: the information criterion to be computed
  #   ll_args: a list of additional arguments passed to logLik
  #   ...: passed to the loo package
  # Returns:
  #   output of the loo package with amended class attribute
  ic <- match.arg(ic)
  contains_samples(x)
  args <- list(x = do.call(logLik, c(list(x), ll_args)))
  if (ll_args$pointwise) {
    args$args$draws <- attr(args$x, "draws")
    args$args$data <- data.frame()
    args$args$N <- attr(args$x, "N")
    args$args$S <- Nsamples(x, subset = ll_args$subset)
    attr(args$x, "draws") <- NULL
  }
  if (ic == "loo") {
    args <- c(args, ...)
  }
  IC <- do.call(eval(parse(text = paste0("loo::", ic))), args)
  class(IC) <- c("ic", "loo")
  return(IC)
}

compare_ic <- function(x, ic = c("waic", "loo")) {
  # compare information criteria of different models
  # Args:
  #   x: A list containing loo objects
  #   ic: the information criterion to be computed
  # Returns:
  #   A matrix with differences in the ICs 
  #   as well as corresponding standard errors
  ic <- match.arg(ic)
  n_models <- length(x)
  ic_diffs <- matrix(0, nrow = n_models * (n_models - 1) / 2, ncol = 2)
  rnames <- rep("", nrow(ic_diffs))
  # pairwise comparision to get differences in ICs and their SEs
  n <- 1
  for (i in seq_len(n_models - 1)) {
    for (j in (i + 1):n_models) {
      temp <- loo::compare(x[[j]], x[[i]])
      ic_diffs[n, ] <- c(-2 * temp[["elpd_diff"]], 2 * temp[["se"]]) 
      rnames[n] <- paste(names(x)[i], "-", names(x)[j])
      n <- n + 1
    }
  }
  rownames(ic_diffs) <- rnames
  colnames(ic_diffs) <- c(toupper(ic), "SE")
  # compare all models at once to obtain weights
  all_compare <- do.call(loo::compare, x)
  if (n_models == 2L) {
    # weights are named differently when comparing only 2 models
    weights <- unname(all_compare[c("weight1", "weight2")])
  } else {
    # weights must be resorted as loo::compare sorts models after weights
    get_input_names <- function(...) {
      # mimic the way loo::compare defines model names
      as.character(match.call())[-1L]
    }
    if ("weights" %in% colnames(all_compare)) {
      weights <- unname(all_compare[do.call(get_input_names, x), "weights"])
    } else {
      # weights have been temporarily removed in loo 0.1.5
      weights <- rep(NA, n_models)
    }
  }
  nlist(ic_diffs, weights)
}

set_pointwise <- function(x, newdata = NULL, subset = NULL, thres = 1e+07) {
  # set the pointwise argument based on the model size
  # Args:
  #   x: a brmsfit object
  #   newdata: optional data.frame containing new data
  #   subset: a vector to indicate a subset of the posterior samples
  #   thres: threshold above which pointwise is set to TRUE
  # Returns:
  #   TRUE or FALSE
  nsamples <- Nsamples(x, subset = subset)
  if (is.data.frame(newdata)) {
    nobs <- nrow(newdata)
  } else {
    nobs <- nobs(x)
  }
  pointwise <- nsamples * nobs > thres
  if (pointwise) {
    message(paste0("Switching to pointwise evaluation to reduce ",  
                   "RAM requirements.\nThis will likely increase ",
                   "computation time."))
  }
  pointwise
}

match_response <- function(models) {
  # compare the response parts of multiple brmsfit objects
  # Args:
  #   models: A list of brmsfit objects
  # Returns:
  #   TRUE if the response parts of all models match and FALSE else
  if (length(models) <= 1L) {
    out <- TRUE  
  } else {
    .match_fun <- function(x, y) {
      # checks if all relevant parts of the response are the same 
      # Args:
      #   x, y: named lists as returned by standata
      to_match <- c("Y", "se", "weights", "cens", "trunc", "disp")
      all(ulapply(to_match, function(v) {
        a <- if (is.null(attr(x, "old_order"))) as.vector(x[[v]])
             else as.vector(x[[v]])[attr(x, "old_order")]
        b <- if (is.null(attr(y, "old_order"))) as.vector(y[[v]])
             else as.vector(y[[v]])[attr(y, "old_order")]
        is_equal(a, b)
      }))
    }
    standatas <- lapply(models, standata, control = list(save_order = TRUE))
    matches <- ulapply(standatas[-1], .match_fun, y = standatas[[1]]) 
    if (all(matches)) {
      out <- TRUE
    } else {
      out <- FALSE
      warning("Model comparisons are most likely invalid as the response ", 
              "parts of at least two models do not match.", call. = FALSE)
    }
  }
  invisible(out)
}

find_names <- function(x) {
  # find all valid object names in a string 
  # Args:
  #   x: a character string
  # Notes:
  #   does not use the R parser itself to allow for 
  #   square brackets and kommas at the end of names
  #   currently only used in hypothesis.brmsfit
  # Returns:
  #   all valid variable names within the string
  if (!is.character(x) || length(x) > 1) 
    stop("x must be a character string of length 1")
  x <- gsub(" ", "", x)
  reg_all <- paste0("([^([:digit:]|[:punct:])]|\\.)[[:alnum:]_\\.]*", 
                    "(\\[[^],]+(,[^],]+)*\\])?")
  pos_all <- gregexpr(reg_all, x)[[1]]
  reg_fun <- "([^([:digit:]|[:punct:])]|\\.)[[:alnum:]_\\.]*\\("
  pos_fun <- gregexpr(reg_fun, x)[[1]]
  pos_decnum <- gregexpr("\\.[[:digit:]]+", x)[[1]]
  pos_var <- list(rmMatch(pos_all, pos_fun, pos_decnum))
  unlist(regmatches(x, pos_var))
}

evidence_ratio <- function(x, cut = 0, wsign = c("equal", "less", "greater"), 
                           prior_samples = NULL, pow = 12, ...) {
  # compute the evidence ratio between two disjunct hypotheses
  # Args:
  #   x: posterior samples 
  #   cut: the cut point between the two hypotheses
  #   wsign: direction of the hypothesis
  #   prior_samples: optional prior samples for undirected hypothesis
  #   pow influence: the accuracy of the density
  #   ...: optional arguments passed to density.default
  # Returns:
  #   the evidence ratio of the two hypothesis
  wsign <- match.arg(wsign)
  if (wsign == "equal") {
    if (is.null(prior_samples)) {
      out <- NA
    } else {
      dots <- list(...)
      dots <- dots[names(dots) %in% names(formals("density.default"))]
      # compute prior and posterior densities
      prior_density <- do.call(density, c(list(x = prior_samples, n = 2^pow), dots))
      posterior_density <- do.call(density, c(list(x = x, n = 2^pow), dots))
      # evaluate densities at the cut point
      at_cut_prior <- match(min(abs(prior_density$x - cut)), 
                            abs(prior_density$x - cut))
      at_cut_posterior <- match(min(abs(posterior_density$x - cut)), 
                                abs(posterior_density$x - cut))
      out <- posterior_density$y[at_cut_posterior] / prior_density$y[at_cut_prior] 
    }
  } else if (wsign == "less") {
    out <- length(which(x < cut))
    out <- out / (length(x) - out)
  } else if (wsign == "greater") {
    out <- length(which(x > cut))
    out <- out / (length(x) - out)  
  }
  out  
}

make_point_frame <- function(mf, effects, conditions, groups, family) {
  # helper function for marginal_effects.brmsfit
  # allowing add data points to the marginal plots
  # Args:
  #   mf: the original model.frame
  #   effects: see argument 'effects' of marginal_effects
  #   conditions: see argument 'conditions' of marginal_effects
  #   groups: names of the grouping factors
  #   family: the model family
  # Returns:
  #   a data.frame containing the data points to be plotted
  points <- mf[, effects, drop = FALSE]
  points$.RESP <- model.response(mf)
  # get required variables i.e. (grouping) factors
  list_mf <- lapply(as.list(mf), function(x)
    if (is.numeric(x)) x else as.factor(x))
  req_vars <- names(mf)[sapply(list_mf, is.factor)]
  if (length(groups)) {
    req_vars <- c(req_vars, unlist(strsplit(groups, ":")))
  }
  req_vars <- unique(setdiff(req_vars, effects))
  req_vars <- intersect(req_vars, names(conditions))
  if (length(req_vars)) {
    # find out which data point is valid for which condition
    mf <- mf[, req_vars, drop = FALSE]
    conditions <- conditions[, req_vars, drop = FALSE]
    points$MargCond <- NA
    points <- replicate(nrow(conditions), points, simplify = FALSE)
    for (i in seq_along(points)) {
      cond <- conditions[i, , drop = FALSE]
      not_na <- which(!(is.na(cond) | cond == ".ZERO"))
      if (length(not_na)) {
        # do it like base::duplicated
        K <- do.call("paste", c(mf[, not_na, drop = FALSE], sep = "\r")) %in% 
             do.call("paste", c(cond[, not_na, drop = FALSE], sep = "\r"))
      } else {
        K <- seq_len(nrow(mf))
      }
      points[[i]]$MargCond[K] <- rownames(conditions)[i] 
    }
    points <- do.call(rbind, points)
    # MargCond allows to assign points to conditions
    points$MargCond <- factor(points$MargCond, rownames(conditions))
  }
  if (!is.numeric(points$.RESP)) {
    points$.RESP <- as.numeric(as.factor(points$.RESP))
    if (is.binary(family)) {
      points$.RESP <- points$.RESP - 1
    }
  }
  na.omit(points)
}

add_samples <- function(x, newpar, dim = numeric(0), dist = "norm", ...) {
  # add some random samples to a brmsfit object 
  # currently only used within tests
  # Args:
  #   x: a brmsfit object
  #   newpar: name of the new parameter to add; 
  #           a single character vector
  #   dim: dimension of the new parameter
  # Returns:
  #   a brmsfit object with samples of a new parameter
  stopifnot(is(x, "brmsfit"), identical(dim, numeric(0)))
  for (i in seq_along(x$fit@sim$samples)) {
    x$fit@sim$samples[[i]][[newpar]] <- 
      do.call(paste0("r", dist), list(x$fit@sim$iter, ...))
  }
  x$fit@sim$fnames_oi <- c(x$fit@sim$fnames_oi, newpar) 
  x$fit@sim$dims_oi[[newpar]] <- dim
  x$fit@sim$pars_oi <- names(x$fit@sim$dims_oi)
  x
}