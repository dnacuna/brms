update_data <- function(data, family, effects,
                        na.action = na.omit,
                        drop.unused.levels = TRUE,
                        terms_attr = NULL, knots = NULL) {
  # Update data for use in brms functions
  # Args:
  #   data: the original data.frame
  #   family: the model family
  #   effects: output of extract_effects (see validate.R)
  #   na.action: function defining how to treat NAs
  #   drop.unused.levels: indicates if unused factor levels
  #                       should be removed
  #   terms_attr: a list of attributes of the terms object of 
  #     the original model.frame; only used with newdata;
  #     this ensures that (1) calls to 'poly' work correctly
  #     and (2) that the number of variables matches the number 
  #     of variable names; fixes issue #73
  #   knots: a list of knot values for GAMMS
  # Returns:
  #   model.frame in long format with combined grouping variables if present
  if (is.null(attr(data, "terms")) && "brms.frame" %in% class(data)) {
    # to avoid error described in #30
    # brms.frame class is deprecated as of brms > 0.7.0
    data <- as.data.frame(data)
  }
  if (!(isTRUE(attr(data, "brmsframe")) || "brms.frame" %in% class(data))) {
    effects$allvars <- terms(effects$allvars)
    attributes(effects$allvars)[names(terms_attr)] <- terms_attr
    if (isTRUE(attr(effects$formula, "old_mv"))) {
      data <- melt_data(data, family = family, effects = effects)
    } else {
      check_data_old_mv(data, family = family, effects = effects)
    }
    data <- data_rsv_intercept(data, effects = effects)
    data <- model.frame(effects$allvars, data = data, na.action = na.pass,
                        drop.unused.levels = drop.unused.levels)
    nrow_with_NA <- nrow(data)
    data <- na.action(data)
    if (nrow(data) != nrow_with_NA) {
      warning("Rows containing NAs were excluded from the model",
              call. = FALSE)
    }
    if (any(grepl("__|_$", colnames(data)))) {
      stop("Variable names may not contain double underscores ",
           "or underscores at the end.", call. = FALSE)
    }
    data <- combine_groups(data, get_random(effects)$group, 
                           effects$time$group)
    data <- fix_factor_contrasts(data)
    attr(data, "knots") <- knots
    attr(data, "brmsframe") <- TRUE
  }
  data
}

melt_data <- function(data, family, effects) {
  # add reserved variables to the data
  # and transform it into long format for mv models
  # DEPRECATED as of brms 1.0.0
  # Args:
  #   data: a data.frame
  #   family: the model family
  #   effects: output of extract_effects
  response <- effects$response
  nresp <- length(response)
  if (is.mv(family, response = response)) {
    if (!is(data, "data.frame")) {
      stop("Argument 'data' must be a data.frame for this model", 
           call. = FALSE)
    }
    # only keep variables that are relevant for the model
    rel_vars <- c(all.vars(attr(terms(effects$allvars), "variables")), 
                  all.vars(effects$respform))
    data <- data[, which(names(data) %in% rel_vars), drop = FALSE]
    rsv_vars <- intersect(c("trait", "response"), names(data))
    if (length(rsv_vars)) {
      rsv_vars <- paste0("'", rsv_vars, "'", collapse = ", ")
      stop(paste(rsv_vars, "is a reserved variable name"), call. = FALSE)
    }
    if (is.categorical(family)) {
      # no parameters are modeled for the reference category
      response <- response[-1]
    }
    # prepare the response variable
    # use na.pass as otherwise cbind will complain
    # when data contains NAs in the response
    nobs <- nrow(data)
    trait <- factor(rep(response, each = nobs), levels = response)
    new_cols <- data.frame(trait = trait)
    model_response <- model.response(model.frame(
      effects$respform, data = data, na.action = na.pass))
    # allow to remove NA responses later on
    rows2remove <- which(!complete.cases(model_response))
    if (is.linear(family)) {
      model_response[rows2remove, ] <- NA
      model_response <- as.vector(model_response)
    } else if (is.categorical(family)) {
      model_response[rows2remove] <- NA
    } else if (is.forked(family)) {
      model_response[rows2remove] <- NA
      rsv_vars <- intersect(c(response[2], "main", "spec"), names(data))
      if (length(rsv_vars)) {
        rsv_vars <- paste0("'", rsv_vars, "'", collapse = ", ")
        stop(paste(rsv_vars, "is a reserved variable name"), call. = FALSE)
      }
      one <- rep(1, nobs)
      zero <- rep(0, nobs)
      new_cols$main <- c(one, zero)
      new_cols$spec <- c(zero, one)
      # dummy responses not actually used in Stan
      model_response <- rep(model_response, 2)
    }
    new_cols$response <- model_response
    old_data <- data
    data <- replicate(length(response), old_data, simplify = FALSE)
    data <- cbind(do.call(rbind, data), new_cols)
    data <- fix_factor_contrasts(data, optdata = old_data)
  }
  data
}

check_data_old_mv <- function(data, family, effects) {
  # check if the deprecated MV syntax was used in a new model
  # Args:
  #   see update_data
  rsv_vars <- rsv_vars(family, nresp = length(effects$response),
                       old_mv = TRUE)
  rsv_vars <- setdiff(rsv_vars, names(data))
  used_rsv_vars <- intersect(rsv_vars, all.vars(effects$allvars))
  if (length(used_rsv_vars)) {
    stop("It is no longer possible (and necessary) to specify models ", 
         "using the multivariate 'trait' syntax. See help(brmsformula) ",
         "for details on the new syntax.", call. = FALSE)
  }
  invisible(NULL)
}

data_rsv_intercept <- function(data, effects) {
  # introduces the resevered variable "intercept" to the data
  # Args:
  #   data: data.frame or list
  #   effects: output of extract_effects
  if (isTRUE(attr(effects$fixed, "rsv_intercept"))) {
    if (is.list(data) && length(data)) {
      if ("intercept" %in% names(data)) {
        stop("'intercept' is a reserved variable name in models ",
             "without a fixed effects intercept", call. = FALSE)
      }
      data$intercept <- rep(1, length(data[[1]]))
    } else {
      stop("Argument 'data' must be a non empty data.frame ", 
           "or list for this model.", call. = FALSE)
    }
  }
  data
}

combine_groups <- function(data, ...) {
  # combine grouping factors
  # Args:
  #   data: a data.frame
  #   ...: the grouping factors to be combined. 
  # Returns:
  #   a data.frame containing all old variables and 
  #   the new combined grouping factors
  group <- c(...)
  for (i in seq_along(group)) {
    sgroup <- unlist(strsplit(group[[i]], ":"))
    if (length(sgroup) > 1) {
      new.var <- get(sgroup[1], data)
      for (j in 2:length(sgroup)) {
        new.var <- paste0(new.var, "_", get(sgroup[j], data))
      }
      data[[group[[i]]]] <- new.var
    }
  } 
  data
}

fix_factor_contrasts <- function(data, optdata = NULL) {
  # hard code factor contrasts to be independent
  # of the global "contrasts" option
  # Args:
  #   data: a data.frame
  #   optdata: optional data.frame from which contrasts
  #            are taken if present
  # Returns:
  #   a data.frame with amended contrasts attributes
  stopifnot(is(data, "data.frame"))
  stopifnot(is.null(optdata) || is.list(optdata))
  optdata <- as.data.frame(optdata)  # fixes issue #105
  for (i in seq_along(data)) {
    if (is.factor(data[[i]]) && is.null(attr(data[[i]], "contrasts"))) {
      if (!is.null(attr(optdata[[names(data)[i]]], "contrasts"))) {
        # take contrasts from optdata
        contrasts(data[[i]]) <- attr(optdata[[names(data)[i]]], "contrasts")
      } else {
        # hard code current global "contrasts" option
        contrasts(data[[i]]) <- contrasts(data[[i]])
      }
    }
  }
  data
}

amend_newdata <- function(newdata, fit, re_formula = NULL, 
                          allow_new_levels = FALSE,
                          check_response = FALSE,
                          incl_autocor = TRUE,
                          return_standata = TRUE) {
  # amend newdata passed to predict and fitted methods
  # Args:
  #   newdata: a data.frame containing new data for prediction 
  #   fit: an object of class brmsfit
  #   re_formula: a random effects formula
  #   allow_new_levels: Are new random effects levels allowed?
  #   check_response: Should response variables be checked
  #                   for existence and validity?
  #   incl_autocor: Check data of autocorrelation terms?
  #   return_standata: Compute the data to be passed to Stan
  #                    or just return the updated newdata?
  # Returns:
  #   updated data.frame being compatible with formula(fit)
  if (is.null(newdata) || is(newdata, "list")) {
    # to shorten expressions in S3 methods such as predict.brmsfit
    if (return_standata && is.null(newdata)) {
      control <- list(not4stan = TRUE, save_order = TRUE)
      newdata <- standata(fit, re_formula = re_formula, control = control)
    }
    return(newdata)
  } else if (!"data.frame" %in% class(newdata)) {
    stop("newdata must be a data.frame", call. = FALSE)
  }
  # standata will be based on an updated formula if re_formula is specified
  new_formula <- update_re_terms(formula(fit), re_formula = re_formula)
  ee <- extract_effects(new_formula, family = family(fit),
                        autocor = if (incl_autocor) fit$autocor,
                        resp_rhs_all = FALSE)
  resp_only_vars <- setdiff(all.vars(ee$respform), 
                            all.vars(rhs(ee$allvars)))
  missing_resp <- setdiff(resp_only_vars, names(newdata))
  if (check_response && length(missing_resp)) {
    stop("Response variables must be specified in newdata for this model.",
         call. = FALSE)
  } else {
    for (resp in missing_resp) {
      # add irrelevant response variables but make sure they pass all checks
      newdata[[resp]] <- NA 
    }
  }
  cens_vars <- all.vars(ee$cens)
  for (v in setdiff(cens_vars, names(newdata))) {
    # censoring vars are unused in predict and related methods
    newdata[[v]] <- 0
  }
  weights_vars <- all.vars(ee$weights)
  for (v in setdiff(weights_vars, names(newdata))) {
    # weighting vars are unused in predict and related methods
    newdata[[v]] <- 1
  }
  new_ranef <- tidy_ranef(ee, data = model.frame(fit))
  if (nrow(fit$ranef)) {
    if (nrow(new_ranef) && allow_new_levels) {
      # grouping factors do not need to be specified 
      # by the user if new levels are allowed
      new_gf <- unique(unlist(strsplit(new_ranef$group, split = ":")))
      missing_gf <- setdiff(new_gf, names(newdata))
      newdata[, missing_gf] <- NA
    }
  }
  newdata <- combine_groups(newdata, get_random(ee)$group)
  # try to validate factor levels in newdata
  if (is.data.frame(fit$data)) {
    # validating is possible (implies brms > 0.5.0)
    list_data <- lapply(as.list(fit$data), function(x)
      if (is.numeric(x)) x else as.factor(x))
    is_factor <- sapply(list_data, is.factor)
    dont_check <- c(fit$ranef$group, cens_vars)
    dont_check <- names(list_data) %in% dont_check
    factors <- list_data[is_factor & !dont_check]
    if (length(factors)) {
      factor_names <- names(factors)
      factor_levels <- lapply(factors, levels) 
      for (i in seq_along(factors)) {
        new_factor <- newdata[[factor_names[i]]]
        if (!is.null(new_factor)) {
          if (!is.factor(new_factor)) {
            new_factor <- factor(new_factor)
          }
          new_levels <- levels(new_factor)
          old_levels <- factor_levels[[i]]
          old_contrasts <- contrasts(factors[[i]])
          to_zero <- is.na(new_factor) | new_factor %in% ".ZERO"
          # don't add the '.ZERO' level to response variables
          is_resp <- factor_names[i] %in% all.vars(ee$respform)
          if (!is_resp && any(to_zero)) {
            levels(new_factor) <- c(new_levels, ".ZERO")
            new_factor[to_zero] <- ".ZERO"
            old_levels <- c(old_levels, ".ZERO")
            old_contrasts <- rbind(old_contrasts, .ZERO = 0)
          }
          if (any(!new_levels %in% old_levels)) {
            stop(paste("New factor levels are not allowed. \n",
                 "Levels found:", paste(new_levels, collapse = ", ") , "\n",
                 "Levels allowed:", paste(old_levels, collapse = ", ")),
                 call. = FALSE)
          }
          newdata[[factor_names[i]]] <- factor(new_factor, old_levels)
          # don't use contrasts(.) here to avoid dimension checks
          attr(newdata[[factor_names[i]]], "contrasts") <- old_contrasts
        }
      }
    }
    # validate monotonic variables
    if (is.formula(ee$mono)) {
      take_num <- !is_factor & names(list_data) %in% all.vars(ee$mono)
      # factors have already been checked
      num_mono_vars <- names(list_data)[take_num]
      for (v in num_mono_vars) {
        # use 'get' to check whether v is defined in newdata
        new_values <- get(v, newdata)
        min_value <- min(list_data[[v]])
        invalid <- new_values < min_value | 
                   new_values > max(list_data[[v]]) |
                   !is.wholenumber(new_values)
        if (sum(invalid)) {
          stop(paste0("Invalid values in variable '", v, "': ",
                      paste(new_values[invalid], collapse = ",")),
               call. = FALSE)
        }
        attr(newdata[[v]], "min") <- min_value
      }
    }
    # brms:::update_data expects all original variables to be present
    # even if not actually used later on
    rsv_vars <- rsv_vars(family(fit), nresp = length(ee$response),
                         rsv_intercept = has_rsv_intercept(ee$formula),
                         old_mv = attr(ee$formula, "old_mv"))
    used_vars <- unique(c(names(newdata), all.vars(ee$allvars), rsv_vars))
    unused_vars <- setdiff(names(model.frame(fit)), used_vars)
    if (length(unused_vars)) {
      newdata[, unused_vars] <- NA
    }
  } else {
    warning(paste("Validity of factors cannot be checked for", 
                  "fitted model objects created with brms <= 0.5.0"),
            call. = FALSE)
  }
  # validate grouping factors
  gnames <- unique(new_ranef$group)
  old_levels <- named_list(gnames)
  for (i in seq_along(gnames)) {
    new_levels <- unique(as.character(get(gnames[i], newdata)))
    old_levels[[i]] <- attr(new_ranef, "levels")[[gnames[i]]]
    unknown_levels <- setdiff(new_levels, old_levels[[i]])
    if (!allow_new_levels && length(unknown_levels)) {
      unknown_levels <- paste0("'", unknown_levels, "'", collapse = ", ")
      stop2("Levels ", unknown_levels, " of grouping factor '", 
            gnames[i], "' cannot be not found in the fitted model. ",
            "Consider setting argument 'allow_new_levels' to TRUE.")
    }
    if (is.factor(model.frame(fit)[[gnames[i]]])) {
      # avoids an error in factor() when supplying only a single level
      all_levels <- union(old_levels[[i]], new_levels)
      newdata[[gnames[i]]] <- factor(newdata[[gnames[i]]], all_levels)   
    }
  }
  if (return_standata) {
    control <- list(is_newdata = TRUE, not4stan = TRUE, 
                    old_levels = old_levels, save_order = TRUE, 
                    omit_response = !check_response,
                    old_cat <- is.old_categorical(fit))
    old_terms <- attr(model.frame(fit), "terms")
    control$terms_attr <- attributes(old_terms)[c("variables", "predvars")]
    has_mono <- length(get_effect(ee, "mono")) > 0L
    if (has_trials(fit$family) || has_cat(fit$family) || has_mono) {
      # some components should not be computed based on newdata
      pars <- c(names(ee$nonlinear), intersect(auxpars(), names(ee)))
      comp <- c("trials", "ncat", paste0("Jm", c("", paste0("_", pars))))
      old_standata <- rmNULL(standata(fit)[comp])
      control[c("trials", "ncat")] <- old_standata[c("trials", "ncat")]
      Jm <- old_standata[grepl("^Jm", names(old_standata))]
      names(Jm) <- sub("^Jm$", "mu", sub("^Jm_", "", names(Jm)))
      control[["Jm"]] <- Jm 
    }
    control$smooth <- make_smooth_list(ee, model.frame(fit))
    if (is(fit$autocor, "cov_fixed")) {
      median_V <- median(diag(fit$autocor$V), na.rm = TRUE)
      fit$autocor$V <- diag(median_V, nrow(newdata))
    }
    knots <- attr(model.frame(fit), "knots")
    newdata <- make_standata(new_formula, data = newdata, 
                             family = fit$family, autocor = fit$autocor,
                             knots = knots, control = control)
  }
  newdata
}

get_model_matrix <- function(formula, data = environment(formula),
                             cols2remove = NULL, ...) {
  # Construct Design Matrices for \code{brms} models
  # Args:
  #   formula: An object of class formula
  #   data: A data frame created with model.frame. 
  #         If another sort of object, model.frame is called first.
  #   cols2remove: names of the columns to remove from 
  #                the model matrix (mainly used for intercepts)
  #   ...: currently ignored
  # Returns:
  #   The design matrix for a regression-like model 
  #   with the specified formula and data. 
  #   For details see the documentation of \code{model.matrix}.
  stopifnot(is.atomic(cols2remove))
  terms <- amend_terms(formula)
  if (is.null(terms)) {
    return(NULL)
  }
  if (isTRUE(attr(terms, "rm_intercept"))) {
    cols2remove <- union(cols2remove, "Intercept")
  }
  X <- stats::model.matrix(terms, data)
  colnames(X) <- rename(colnames(X), check_dup = TRUE)
  cols2remove <- which(colnames(X) %in% cols2remove)
  if (length(cols2remove)) {
    X <- X[, -cols2remove, drop = FALSE]
  }
  X   
}

prepare_mono_vars <- function(formula, data, check = TRUE) {
  # prepare monotonic variables for use in Stan
  # Args:
  #   formula: formula containing mononotic effects terms
  #   data: a data.frame or named list
  #   check: check the number of levels? 
  # Returns:
  #   'data' with amended monotonic variables
  data <- model.frame(formula, data)
  vars <- names(data)
  for (i in seq_along(vars)) {
    # validate predictors to be modeled as monotonic effects
    if (is.ordered(data[[vars[i]]])) {
      # counting starts at zero
      data[[vars[i]]] <- as.numeric(data[[vars[i]]]) - 1 
    } else if (all(is.wholenumber(data[[vars[i]]]))) {
      min_value <- attr(data[[vars[i]]], "min")
      if (is.null(min_value)) {
        min_value <- min(data[[vars[i]]])
      }
      data[[vars[i]]] <- data[[vars[i]]] - min_value
    } else {
      stop(paste("monotonic predictors must be either integers or",
                 "ordered factors. Error occured for variable", vars[i]), 
           call. = FALSE)
    }
    if (check && max(data[[vars[i]]]) < 2L) {
      stop(paste("monotonic predictors must have at least 3 different", 
                 "values. Error occured for variable", vars[i]),
           call. = FALSE)
    }
  }
  out <- get_model_matrix(formula, data, cols2remove = "Intercept")
  if (any(grepl(":", colnames(out), fixed = TRUE))) {
    stop("Modeling interactions as monotonic ", 
         "is not meaningful.", call. = FALSE)
  }
  out
}

make_smooth_list <- function(effects, data) {
  # compute smoothing objects based on the original data
  # as the basis for doing predictions with new data
  # Args:
  #   effects: output of extract_effects
  #   data: the original model.frame
  # Returns:
  #   A named list of lists of smoothing objects
  #   one element per (non-linear) parameter    
  if (has_splines(effects)) {
    knots <- attr(data, "knots")
    data <- rm_attr(data, "terms")
    gam_args <- list(data = data, knots = knots, 
                     absorb.cons = TRUE, modCon = 3)
    if (length(effects$nonlinear)) {
      smooth <- named_list(names(effects$nonlinear))
      for (nlp in names(smooth)) {
        splines <- get_spline_labels(effects$nonlinear[[nlp]])
        for (i in seq_along(splines)) {
          sc_args <- c(list(eval_spline(splines[i])), gam_args)
          smooth[[nlp]][[i]] <- do.call(mgcv::smoothCon, sc_args)[[1]]
        }
      }
    } else {
      smooth <- named_list("mu")
      splines <- get_spline_labels(effects)
      for (i in seq_along(splines)) {
        sc_args <- c(list(eval_spline(splines[i])), gam_args)
        smooth[["mu"]][[i]] <- do.call(mgcv::smoothCon, sc_args)[[1]]
      }
    }
    auxpars <- intersect(auxpars(), names(effects))
    smooth <- c(smooth, named_list(auxpars))
    for (ap in auxpars) {
      splines <- get_spline_labels(effects[[ap]])
      for (i in seq_along(splines)) {
        sc_args <- c(list(eval_spline(splines[i])), gam_args)
        smooth[[ap]][[i]] <- do.call(mgcv::smoothCon, sc_args)[[1]]
      }
    }
  } else {
    smooth <- list()
  }
  smooth
}

arr_design_matrix <- function(Y, r, group)  { 
  # compute the design matrix for ARR effects
  # Args:
  #   Y: a vector containing the response variable
  #   r: ARR order
  #   group: vector containing the grouping variable
  # Notes: 
  #   expects Y to be sorted after group already
  # Returns:
  #   the design matrix for ARR effects
  stopifnot(length(Y) == length(group))
  if (r > 0) {
    U_group <- unique(group)
    N_group <- length(U_group)
    out <- matrix(0, nrow = length(Y), ncol = r)
    ptsum <- rep(0, N_group + 1)
    for (j in seq_len(N_group)) {
      ptsum[j + 1] <- ptsum[j] + sum(group == U_group[j])
      for (i in seq_len(r)) {
        if (ptsum[j] + i + 1 <= ptsum[j + 1]) {
          out[(ptsum[j] + i + 1):ptsum[j + 1], i] <- 
            Y[(ptsum[j] + 1):(ptsum[j + 1] - i)]
        }
      }
    }
  } else {
    out <- NULL
  } 
  out
}

data_effects <- function(effects, data, family = gaussian(),
                         ranef = empty_ranef(), prior = prior_frame(), 
                         autocor = cor_arma(), knots = NULL, nlpar = "", 
                         not4stan = FALSE, smooth = NULL, Jm = NULL) {
  # combine data for all types of effects
  # Args:
  #   effects: a list returned by extract_effects
  #   data: the data passed by the user
  #   family: the model family
  #   prior: an object of class prior_frame
  #   autocor: object of class 'cor_brms'
  #   cov_ranef: name list of user-defined covariance matrices
  #   knots: optional knot values for smoothing terms
  #   nlpar: optional character string naming a non-linear parameter
  #   not4stan: is the data for use in S3 methods only?
  #   old_levels: original levels of grouping factors
  #   smooth: optional list of smoothing objects based on 
  #           the original data
  #   Jm: optional precomputed values of Jm for monotonic effects
  # Returns:
  #   A named list of data to be passed to Stan
  data_fixef <- data_fixef(effects, data = data, family = family, 
                           autocor = autocor, nlpar = nlpar, 
                           knots = knots, not4stan = not4stan,
                           smooth = smooth)
  data_monef <- data_monef(effects, data = data, ranef = ranef,
                           prior = prior, Jm = Jm, nlpar = nlpar)
  data_ranef <- data_ranef(ranef, data = data, nlpar = nlpar, 
                           not4stan = not4stan)
  c(data_fixef, data_monef, data_ranef)
}

data_fixef <- function(effects, data, family = gaussian(),
                       autocor = cor_arma(), knots = NULL,
                       nlpar = "", not4stan = FALSE,
                       smooth = NULL) {
  # prepare data for fixed effects for use in Stan 
  # Args: see data_effects
  stopifnot(length(nlpar) == 1L)
  out <- list()
  p <- usc(nlpar, "prefix")
  is_ordinal <- is.ordinal(family)
  is_bsts <- is(autocor, "cor_bsts")
  # the intercept is removed inside the Stan code for ordinal models
  cols2remove <- if (is_ordinal && not4stan || is_bsts) "Intercept"
  X <- get_model_matrix(rhs(effects$fixed), data, cols2remove = cols2remove)
  splines <- get_spline_labels(effects)
  if (length(splines)) {
    stopifnot(is.null(smooth) || length(smooth) == length(splines))
    Xs <- Zs <- vector("list", length(splines))
    for (i in seq_along(splines)) {
      if (is.null(smooth[[i]])) {
        sm <- mgcv::smoothCon(eval_spline(splines[i]), data = data, 
                              knots = knots, absorb.cons = TRUE)[[1]]
      } else {
        sm <- smooth[[i]]
        sm$X <- mgcv::PredictMat(sm, rm_attr(data, "terms"))
      }
      rasm <- mgcv::smooth2random(sm, names(data))
      Xs[[i]] <- rasm$Xf
      if (ncol(Xs[[i]])) {
        colnames(Xs[[i]]) <- paste0(sm$label, "_", seq_len(ncol(Xs[[i]])))
      }
      Zs <- lapply(rasm$rand, attr, "Xr")
      Zs <- setNames(Zs, paste0("Zs", p, "_", i, "_", seq_along(Zs)))
      knots <- list(length(Zs), as.array(ulapply(Zs, ncol)))
      knots <- setNames(knots, paste0(c("nb", "knots"), p, "_", i))
      out <- c(out, knots, Zs)
    }
    X <- cbind(X, do.call(cbind, Xs))
    colnames(X) <- rename(colnames(X))
  }
  avoid_auxpars(colnames(X), effects = effects)
  c(out, setNames(list(ncol(X), X), paste0(c("K", "X"), p)))
}

data_monef <- function(effects, data, ranef = empty_ranef(),
                       prior = prior_frame(), nlpar = "",
                       Jm = NULL) {
  # prepare data for monotonic effects for use in Stan
  # Args: see data_effects
  stopifnot(length(nlpar) == 1L)
  p <- if (nchar(nlpar)) paste0("_", nlpar) else ""
  out <- list()
  if (is.formula(effects[["mono"]])) {
    Xm <- prepare_mono_vars(effects$mono, data, check = is.null(Jm))
    avoid_auxpars(colnames(Xm), effects = effects)
    if (is.null(Jm)) {
      Jm <- as.array(apply(Xm, 2, max))
    }
    out <- c(out, setNames(list(ncol(Xm), Xm, Jm), 
                           paste0(c("Km", "Xm", "Jm"), p)))
    # validate and assign vectors for dirichlet prior
    monef <- colnames(Xm)
    for (i in seq_along(monef)) {
      take <- prior$class == "simplex" & prior$coef == monef[i] & 
              prior$nlpar == nlpar  
      sprior <- paste0(".", prior$prior[take])
      if (nchar(sprior) > 1L) {
        sprior <- as.numeric(eval(parse(text = sprior)))
        if (length(sprior) != Jm[i]) {
          stop(paste0("Invalid dirichlet prior for the simplex of ", 
                      monef[i], ". Expected input of length ", Jm[i], 
                      " but found ", paste(sprior, collapse = ",")),
               call. = FALSE)
        }
        out[[paste0("con_simplex", p, "_", i)]] <- sprior
      } else {
        out[[paste0("con_simplex", p, "_", i)]] <- rep(1, Jm[i]) 
      }
    }
  }
  out
}

data_ranef <- function(ranef, data, nlpar = "", not4stan = FALSE) {
  # prepare data for group-level effects for use in Stan
  # Args: see data_effects
  stopifnot(length(nlpar) == 1L)
  out <- list()
  ranef <- ranef[ranef$nlpar == nlpar & ranef$type != "mono", ]
  if (nrow(ranef)) {
    Z <- lapply(ranef[!duplicated(ranef$gn), ]$form, 
                get_model_matrix, data = data)
    gn <- unique(ranef$gn)
    for (i in seq_along(gn)) {
      r <- ranef[ranef$gn == gn[i], ]
      idp <- paste0(r$id[1], usc(nlpar, "prefix"))
      if (isTRUE(not4stan)) {
        # for internal use in S3 methods
        if (ncol(Z[[i]]) == 1L) {
          Z[[i]] <- as.vector(Z[[i]])
        }
        Zname <- paste0("Z_", gn[i])
        out <- c(out, setNames(Z[i], Zname))
      } else {
        if (r$type[1] == "cse") {
          ncatM1 <- nrow(r) / ncol(Z[[i]])
          Z_temp <- vector("list", ncol(Z[[i]]))
          for (k in seq_along(Z_temp)) {
            Z_temp[[k]] <- replicate(ncatM1, Z[[i]][, k])
          }
          Z[[i]] <- do.call(cbind, Z_temp)
        }
        Zname <- paste0("Z_", idp, "_", r$cn)
        for (j in seq_len(ncol(Z[[i]]))) {
          out <- c(out, setNames(list(as.array(Z[[i]][, j])), Zname[j]))
        }
      }
    }
  }
  out
}

data_group <- function(ranef, data, cov_ranef = NULL, old_levels = NULL) {
  # compute data specific for each group-level-ID
  # Args:
  #   ranef: data.frame returned by tidy_ranef
  #   data: the model.frame
  #   cov_ranef: name list of user-defined covariance matrices
  #   old_levels: original levels of grouping factors
  #               only relevant for newdata
  expr <- expression(as.array(as.numeric(factor(get(g, data)))), 
                     length(unique(get(g, data))), # number of levels 
                     nranef,  # number of group-level effects
                     nranef * (nranef - 1) / 2)  # number of cors
  if (length(old_levels)) {
    # for newdata numeration has to depend on the original levels
    expr[1] <- expression(ulapply(get(g, data), match, old_levels[[g]]))
  }
  out <- list()
  ids <- unique(ranef$id)
  for (id in ids) {
    id_ranef <- ranef[ranef$id == id, ]
    nranef <- nrow(id_ranef)
    g <- id_ranef$group[1]
    name <- paste0(c("J_", "N_", "M_", "NC_"), id)
    for (j in seq_along(name)) {
      out <- c(out, setNames(list(eval(expr[j])), name[j]))
    }
    if (g %in% names(cov_ranef)) {
      cov_mat <- as.matrix(cov_ranef[[g]])
      if (!isSymmetric(unname(cov_mat))) {
        stop(paste("covariance matrix of grouping factor", g, 
                   "is not symmetric"), call. = FALSE)
      }
      found_level_names <- rownames(cov_mat)
      if (is.null(found_level_names)) {
        stop(paste("rownames are required for covariance matrix of", g),
             call. = FALSE)
      }
      colnames(cov_mat) <- found_level_names
      true_level_names <- levels(factor(get(g, data)))
      found <- true_level_names %in% found_level_names
      if (any(!found)) {
        stop(paste("rownames of covariance matrix of", g, 
                   "do not match names of the grouping levels"),
             call. = FALSE)
      }
      cov_mat <- cov_mat[true_level_names, true_level_names, drop = FALSE]
      evs <- eigen(cov_mat, symmetric = TRUE, only.values = TRUE)$values
      if (min(evs) <= 0) {
        stop("Covariance matrix of grouping factor '", g, 
             "' is not positive definite.", call. = FALSE)
      }
      out <- c(out, setNames(list(t(chol(cov_mat))), paste0("Lcov_", id)))
    }
  }
  out
}

data_csef <- function(effects, data) {
  # prepare data for category specific effects for use in Stan
  # Args:
  #   effects: a list returned by extract_effects
  #   data: the data passed by the user
  out <- list()
  if (length(all_terms(effects[["cse"]]))) {
    Xcs <- get_model_matrix(effects$cse, data)
    avoid_auxpars(colnames(Xcs), effects = effects)
    out <- c(out, list(Kcs = ncol(Xcs), Xcs = Xcs))
  }
  out
}