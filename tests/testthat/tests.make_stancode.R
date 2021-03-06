test_that("make_stancode handles horseshoe priors correctly", {
  prior <- prior_frame(prior = "normal(0, hs_local * hs_global)", class = "b")
  attr(prior, "hs_df") <- 7
  temp_stancode <- make_stancode(rating ~ treat*period*carry, data = inhaler,
                                 prior = prior)
  expect_match(temp_stancode, fixed = TRUE,
               "  vector<lower=0>[Kc] hs_local; \n  real<lower=0> hs_global; \n")
  expect_match(temp_stancode, fixed = TRUE,
               "  hs_local ~ student_t(7, 0, 1); \n  hs_global ~ cauchy(0, 1); \n")
})

test_that("make_stancode accepts supported links", {
  expect_match(make_stancode(rating ~ treat + period + carry, 
                             data = inhaler, family = sratio("probit_approx")), 
               "Phi_approx")
  expect_match(make_stancode(rating ~ treat + period + carry, 
                             data = inhaler, family = c("cumulative", "probit")), 
               "Phi")
  expect_match(make_stancode(rating ~ treat + period + carry, 
                             data = inhaler, family = "poisson"), 
               "log")
  expect_match(make_stancode(cbind(rating, rating + 1) ~ 1, 
                             data = inhaler, family = gaussian("log")), 
               "eta_rating[n] = exp(eta_rating[n])", fixed = TRUE)
  expect_match(make_stancode(rating ~ 1, data = inhaler, 
                             family = von_mises(tan_half)), 
               "eta[n] = inv_tan_half(eta[n])", fixed = TRUE)
})

test_that(paste("make_stancode returns correct strings", 
                "for customized covariances"), {
  expect_match(make_stancode(rating ~ treat + period + carry + (1|subject), 
                             data = inhaler, cov_ranef = list(subject = 1)), 
               "r_1_1 = sd_1[1] * (Lcov_1 * z_1[1])", fixed = TRUE)
  expect_match(make_stancode(rating ~ treat + period + carry + (1+carry|subject), 
                             data = inhaler, cov_ranef = list(subject = 1)),
               "kronecker(Lcov_1, diag_pre_multiply(sd_1, L_1)) * to_vector(z_1)",
               fixed = TRUE)
  expect_match(make_stancode(rating ~ treat + period + carry + (1+carry||subject), 
                             data = inhaler, cov_ranef = list(subject = 1)), 
               paste0("  r_1_1 = sd_1[1] * (Lcov_1 * z_1[1]); \n",
                      "  r_1_2 = sd_1[2] * (Lcov_1 * z_1[2]);"),
               fixed = TRUE)
})

test_that("make_stancode handles addition arguments correctly", {
  expect_match(make_stancode(time | cens(censored) ~ age + sex + disease, 
                             data = kidney, family = c("weibull", "log")), 
               "int<lower=-1,upper=2> cens[N];", fixed = TRUE)
  expect_match(make_stancode(time | trunc(0) ~ age + sex + disease,
                             data = kidney, family = "gamma"), 
               "T[lb[n], ];", fixed = TRUE)
  expect_match(make_stancode(time | trunc(ub = 100) ~ age + sex + disease, 
                             data = kidney, family = student("log")), 
               "T[, ub[n]];", fixed = TRUE)
  expect_match(make_stancode(count | trunc(0, 150) ~ Trt_c, 
                             data = epilepsy, family = "poisson"), 
               "T[lb[n], ub[n]];", fixed = TRUE)
})

test_that("make_stancode correctly combines strings of multiple grouping factors", {
  expect_match(make_stancode(count ~ (1|patient) + (1 + Trt_c | visit), 
                             data = epilepsy, family = "poisson"), 
               paste0("  vector[N] Z_1_1; \n",
                      "  // data for group-specific effects of ID 2 \n"), 
               fixed = TRUE)
  expect_match(make_stancode(count ~ (1|visit) + (1+Trt_c|patient), 
                             data = epilepsy, family = "poisson"), 
               paste0("  int<lower=1> NC_1; \n",
                      "  // data for group-specific effects of ID 2 \n"), 
               fixed = TRUE)
})

test_that("make_stancode handles models without fixed effects correctly", {
  expect_match(make_stancode(count ~ 0 + (1|patient) + (1+Trt_c|visit), 
                             data = epilepsy, family = "poisson"), 
               "  eta = rep_vector(0, N); \n", fixed = TRUE)
})

test_that("make_stancode correctly restricts FE parameters", {
  data <- data.frame(y = rep(0:1, each = 5), x = rnorm(10))
  sc <- make_stancode(y ~ x, data, prior = set_prior("", lb = 2))
  expect_match(sc, "vector<lower=2>[Kc] b", fixed = TRUE)
  sc <- make_stancode(y ~ x, data, prior = set_prior("normal(0,2)", ub = "4"))
  expect_match(sc, "vector<upper=4>[Kc] b", fixed = TRUE)
  prior <- set_prior("normal(0,5)", lb = "-3", ub = 5)
  sc <- make_stancode(y ~ 0 + x, data, prior = prior)
  expect_match(sc, "vector<lower=-3,upper=5>[K] b", fixed = TRUE)
})

test_that("make_stancode returns correct self-defined functions", {
  # cauchit link
  expect_match(make_stancode(rating ~ treat, data = inhaler,
                             family = cumulative("cauchit")),
               "real inv_cauchit(real y)", fixed = TRUE)
  # tan_half link
  expect_match(make_stancode(rating ~ treat, data = inhaler,
                             family = von_mises("tan_half")),
               "real inv_tan_half(real y)", fixed = TRUE)
  # inverse gaussian models
  temp_stancode <- make_stancode(time | cens(censored) ~ age, data = kidney,
                                 family = inverse.gaussian)
  expect_match(temp_stancode, "real inv_gaussian_lpdf(real y", fixed = TRUE)
  expect_match(temp_stancode, "real inv_gaussian_lcdf(real y", fixed = TRUE)
  expect_match(temp_stancode, "real inv_gaussian_lccdf(real y", fixed = TRUE)
  expect_match(temp_stancode, "real inv_gaussian_vector_lpdf(vector y", fixed = TRUE)
  # von Mises models
  temp_stancode <- make_stancode(time ~ age, data = kidney, family = von_mises)
  expect_match(temp_stancode, "real von_mises_real_lpdf(real y", fixed = TRUE)
  expect_match(temp_stancode, "real von_mises_vector_lpdf(vector y", fixed = TRUE)
  # zero-inflated and hurdle models
  expect_match(make_stancode(count ~ Trt_c, data = epilepsy, 
                             family = "zero_inflated_poisson"),
               "real zero_inflated_poisson_lpmf(int y", fixed = TRUE)
  expect_match(make_stancode(count ~ Trt_c, data = epilepsy, 
                             family = "zero_inflated_negbinomial"),
               "real zero_inflated_neg_binomial_lpmf(int y", fixed = TRUE)
  expect_match(make_stancode(count ~ Trt_c, data = epilepsy, 
                             family = "zero_inflated_binomial"),
               "real zero_inflated_binomial_lpmf(int y", fixed = TRUE)
  expect_match(make_stancode(count ~ Trt_c, data = epilepsy, 
                             family = "zero_inflated_beta"),
               "real zero_inflated_beta_lpdf(real y", fixed = TRUE)
  expect_match(make_stancode(count ~ Trt_c, data = epilepsy, 
                             family = hurdle_poisson()),
               "real hurdle_poisson_lpmf(int y", fixed = TRUE)
  expect_match(make_stancode(count ~ Trt_c, data = epilepsy, 
                             family = hurdle_negbinomial),
               "real hurdle_neg_binomial_lpmf(int y", fixed = TRUE)
  expect_match(make_stancode(count ~ Trt_c, data = epilepsy, 
                             family = hurdle_gamma("log")),
               "real hurdle_gamma_lpdf(real y", fixed = TRUE)
  # linear models with special covariance structures
  expect_match(make_stancode(rating ~ treat, data = inhaler, 
                             autocor = cor_ma(cov = TRUE)),
               "real normal_cov_lpdf(vector y", fixed = TRUE)
  expect_match(make_stancode(time ~ age, data = kidney, family = "student", 
                             autocor = cor_ar(cov = TRUE)),
               "real student_t_cov_lpdf(vector y", fixed = TRUE)
  # ARMA covariance matrices
  expect_match(make_stancode(rating ~ treat, data = inhaler, 
                             autocor = cor_ar(cov = TRUE)),
               "matrix cov_matrix_ar1(real ar", fixed = TRUE)
  expect_match(make_stancode(time ~ age, data = kidney, family = "student", 
                             autocor = cor_ma(cov = TRUE)),
               "matrix cov_matrix_ma1(real ma", fixed = TRUE)
  expect_match(make_stancode(time ~ age, data = kidney, family = "student", 
                             autocor = cor_arma(p = 1, q = 1, cov = TRUE)),
               "matrix cov_matrix_arma1(real ar, real ma", fixed = TRUE)
  # kronecker matrices
  expect_match(make_stancode(rating ~ treat + period + carry + (1+carry|subject), 
                            data = inhaler, cov_ranef = list(subject = 1)), 
              "matrix as_matrix.*matrix kronecker")
})

test_that("make_stancode detects invalid combinations of modeling options", {
  data <- data.frame(y1 = rnorm(10), y2 = rnorm(10), 
                     wi = 1:10, ci = sample(-1:1, 10, TRUE))
  expect_error(make_stancode(y1 | cens(ci) ~ y2, data = data,
                             autocor = cor_ar(cov = TRUE)),
               "Invalid addition arguments")
  expect_error(make_stancode(cbind(y1, y2) ~ 1, data = data,
                             autocor = cor_ar(cov = TRUE)),
               "ARMA covariance matrices are not yet working")
  expect_error(make_stancode(y1 | se(wi) ~ y2, data = data,
                             autocor = cor_ma()),
               "Please set cov = TRUE", fixed = TRUE)
  expect_error(make_stancode(y1 | trunc(lb = -50) | weights(wi) ~ y2,
                             data = data),
               "truncation is not yet possible")
})

test_that("make_stancode is silent for multivariate models", {
  data <- data.frame(y1 = rnorm(10), y2 = rnorm(10), x = 1:10)
  expect_silent(make_stancode(cbind(y1, y2) ~ x, data = data))
})

test_that("make_stancode is silent for categorical models", {
  data <- data.frame(y = sample(1:4, 10, TRUE), x = 1:10)
  expect_silent(make_stancode(y ~ x, data = data, family = categorical()))
})

test_that("make_stancode returns correct code for intercept only models", {
  expect_match(make_stancode(rating ~ 1, data = inhaler),
               "b_Intercept = temp_Intercept;", fixed = TRUE) 
  expect_match(make_stancode(rating ~ 1, data = inhaler, family = sratio()),
               "b_Intercept = temp_Intercept;", fixed = TRUE) 
  expect_match(make_stancode(rating ~ 1, data = inhaler, family = categorical()),
               "b_3_Intercept = temp_3_Intercept;", fixed = TRUE) 
})

test_that("make_stancode returns correct code for spline only models", {
  expect_match(make_stancode(count ~ s(log_Age_c), data = epilepsy),
               "matrix[N, K - 1] Xc;", fixed = TRUE)
})

test_that("make_stancode generates correct code for category specific effects", {
  scode <- make_stancode(rating ~ period + carry + cse(treat), 
                         data = inhaler, family = sratio())
  expect_match(scode, "matrix[N, Kcs] Xcs;", fixed = TRUE)
  expect_match(scode, "matrix[Kcs, ncat - 1] bcs;", fixed = TRUE)
  expect_match(scode, "etacs = Xcs * bcs;", fixed = TRUE)
  expect_match(scode, "sratio(eta[n], etacs[n], temp_Intercept);", fixed = TRUE)
  scode <- make_stancode(rating ~ period + carry + cse(treat) + (cse(1)|subject), 
                         data = inhaler, family = acat())
  expect_match(scode, "etacs[n, 1] = etacs[n, 1] + r_1_1[J_1[n]] * Z_1_1[n];",
               fixed = TRUE)
  scode <- make_stancode(rating ~ period + carry + (cse(treat)|subject), 
                         data = inhaler, family = acat())
  expect_match(scode, paste("etacs[n, 3] = etacs[n, 3] + r_1_3[J_1[n]] * Z_1_3[n]", 
                             "+ r_1_6[J_1[n]] * Z_1_6[n];"), fixed = TRUE)
  expect_match(scode, "Y[n] ~ acat(eta[n], etacs[n], temp_Intercept);", 
               fixed = TRUE)
})

test_that("make_stancode generates correct code for monotonic effects", {
  data <- data.frame(y = rpois(120, 10), x1 = rep(1:4, 30), 
                     x2 = factor(rep(c("a", "b", "c"), 40), ordered = TRUE))
  scode <- make_stancode(y ~ monotonic(x1 + x2), data = data)
  expect_match(scode, "int Xm[N, Km];", fixed = TRUE)
  expect_match(scode, "simplex[Jm[1]] simplex_1;", fixed = TRUE)
  expect_match(scode, "(bm[2]) * monotonic(simplex_2, Xm[n, 2]);", fixed = TRUE)
  expect_match(scode, "simplex_1 ~ dirichlet(con_simplex_1);", fixed = TRUE)
  scode <- make_stancode(y ~ mono(x1) + (mono(x1)|x2) + (1|x2), data = data)
  expect_match(scode, "(bm[1] + r_1_1[J_1[n]]) * monotonic(simplex_1, Xm[n, 1]);",
               fixed = TRUE)
  # check that Z_1_1 is (correctly) undefined
  expect_match(scode, paste0("  int<lower=1> M_1; \n",
    "  // data for group-specific effects of ID 2"), fixed = TRUE)
  expect_error(make_stancode(y ~ mono(x1) + (mono(x1+x2)|x2), data = data),
               "Monotonic group-level terms require", fixed = TRUE)
})

test_that("make_stancode generates correct code for non-linear models", {
  nonlinear <- list(a ~ x, b ~ z + (1|g))
  data <- data.frame(y = rgamma(9, 1, 1), x = rnorm(9), z = rnorm(9), 
                     g = rep(1:3, 3))
  prior <- c(set_prior("normal(0,5)", nlpar = "a"),
             set_prior("normal(0,1)", nlpar = "b"))
  # syntactic validity is already checked within make_stancode
  stancode <- make_stancode(y ~ a - exp(b^z), data = data, prior = prior,
                            nonlinear = nonlinear)
  expect_match(stancode, "eta[n] = eta_a[n] - exp(eta_b[n] ^ C[n, 1]);",
               fixed = TRUE)
  
  nonlinear <- list(a1 ~ 1, a2 ~ z + (x|g))
  prior <- c(set_prior("beta(1,1)", nlpar = "a1", lb = 0, ub = 1),
             set_prior("normal(0,1)", nlpar = "a2"))
  stancode <- make_stancode(y ~ a1 * exp(-x/(a2 + z)), data = data, 
                            family = Gamma("log"), prior = prior, 
                            nonlinear = nonlinear)
  expect_match(stancode, fixed = TRUE,
    paste("eta[n] = shape * exp(-(eta_a1[n] *", 
          "exp( - C[n, 1] / (eta_a2[n] + C[n, 2]))));"))
})

test_that("make_stancode accepts very long non-linear formulas", {
  data <- data.frame(y = rnorm(10), this_is_a_very_long_predictor = rnorm(10))
  expect_silent(make_stancode(y ~ b0 + this_is_a_very_long_predictor + 
                              this_is_a_very_long_predictor +
                              this_is_a_very_long_predictor,
                data = data, nonlinear = b0 ~ 1,
                prior = set_prior("normal(0,1)", nlpar = "b0")))
})

test_that("no loop in trans-par is defined for simple 'identity' models", {
  expect_true(!grepl(make_stancode(time ~ age, data = kidney), 
                     "eta[n] <- (eta[n]);", fixed = TRUE))
  expect_true(!grepl(make_stancode(time ~ age, data = kidney, 
                                   family = poisson("identity")), 
                     "eta[n] <- (eta[n]);", fixed = TRUE))
})

test_that("make_stancode returns correct 'disp' code", {
  stancode <- make_stancode(time | disp(sqrt(age)) ~ sex + age, data = kidney)
  expect_match(stancode, "disp_sigma = sigma \\* disp;.*normal\\(eta, disp_sigma\\)")
  
  stancode <- make_stancode(time | disp(1/age) ~ sex + age, 
                            data = kidney, family = lognormal())
  expect_match(stancode, "Y ~ lognormal(eta, disp_sigma);", fixed = TRUE)
  
  stancode <- make_stancode(time | disp(1/age) ~ sex + age + (1|patient), 
                            data = kidney, family = Gamma())
  expect_match(stancode, paste0("eta\\[n\\] = disp_shape\\[n\\] \\* \\(.*",
                                "gamma\\(disp_shape, eta\\)"))
  
  stancode <- make_stancode(time | disp(1/age) ~ sex + age, 
                            data = kidney, family = weibull())
  expect_match(stancode, "eta[n] = exp((eta[n]) / disp_shape[n]);", 
               fixed = TRUE)
  
  stancode <- make_stancode(time | disp(1/age) ~ sex + age, 
                            data = kidney, family = negbinomial())
  expect_match(stancode, "Y ~ neg_binomial_2_log(eta, disp_shape);", 
               fixed = TRUE)
  
  stancode <- make_stancode(y | disp(y) ~ a - b^x, family = weibull(),
                            data = data.frame(y = rpois(10, 10), x = rnorm(10)),
                            nonlinear = a + b ~ 1,
                            prior = c(set_prior("normal(0,1)", nlpar = "a"),
                                      set_prior("normal(0,1)", nlpar = "b")))
  expect_match(stancode, fixed = TRUE,
               "eta[n] = exp((eta_a[n] - eta_b[n] ^ C[n, 1]) / disp_shape[n]);")
})

test_that("functions defined in 'stan_funs' appear in the functions block", {
  test_fun <- paste0("  real test_fun(real a, real b) { \n",
                     "    return a + b; \n",
                     "  } \n")
  expect_match(make_stancode(time ~ age, data = kidney, stan_funs = test_fun),
               test_fun, fixed = TRUE)
})

test_that("fixed residual covariance matrices appear in the Stan code", {
  data <- data.frame(y = 1:5)
  V <- diag(5)
  expect_match(make_stancode(y~1, data = data, family = gaussian(), 
                             autocor = cov_fixed(V)),
               "Y ~ multi_normal_cholesky(eta, LV)", fixed = TRUE)
  expect_match(make_stancode(y~1, data = data, family = student(),
                             autocor = cov_fixed(V)),
               "Y ~ multi_student_t(nu, eta, V)", fixed = TRUE)
  expect_match(make_stancode(y~1, data = data, family = student(),
                             autocor = cov_fixed(V)),
               "Y ~ multi_student_t(nu, eta, V)", fixed = TRUE)
})

test_that("make_stancode correctly generates code for bsts models", {
  dat <- data.frame(y = rnorm(10), x = rnorm(10))
  stancode <- make_stancode(y~x, data = dat, autocor = cor_bsts())
  expect_match(stancode, "+ loclev[n]", fixed = TRUE)
  expect_match(stancode, "loclev[n] ~ normal(loclev[n - 1], sigmaLL)",
               fixed = TRUE)
  dat <- data.frame(y = rexp(1), x = rnorm(10))
  stancode <- make_stancode(y~x, data = dat, family = student("log"),
                            autocor = cor_bsts())
  expect_match(stancode, "loclev[n] ~ normal(log(Y[n]), sigmaLL)",
               fixed = TRUE)
})

test_that("make_stancode correctly generates code for GAMMs", {
  dat <- data.frame(y = rnorm(10), x = rnorm(10), g = rep(1:2, 5))
  stancode <- make_stancode(y ~ s(x) + (1|g), data = dat,
                            prior = set_prior("normal(0,2)", "sds"))
  expect_match(stancode, "Zs_1_1 * s_1_1", fixed = TRUE)
  expect_match(stancode, "matrix[N, knots_1[1]] Zs_1_1", fixed = TRUE)
  expect_match(stancode, "zs_1_1 ~ normal(0, 1)", fixed = TRUE)
  expect_match(stancode, "sds_1_1 ~ normal(0,2)", fixed = TRUE)
  
  prior <- c(set_prior("normal(0,5)", nlpar = "lp"),
             set_prior("normal(0,2)", "sds", nlpar = "lp"))
  stancode <- make_stancode(y ~ lp, nonlinear = lp ~ s(x) + (1|g), data = dat, 
                            prior = prior)
  expect_match(stancode, "Zs_lp_1_1 * s_lp_1_1", fixed = TRUE)
  expect_match(stancode, "matrix[N, knots_lp_1[1]] Zs_lp_1_1", fixed = TRUE)
  expect_match(stancode, "zs_lp_1_1 ~ normal(0, 1)", fixed = TRUE)
  expect_match(stancode, "sds_lp_1_1 ~ normal(0,2)", fixed = TRUE)
  
  stancode <- make_stancode(y ~ s(x) + t2(x,y), data = dat,
                            prior = set_prior("normal(0,2)", "sds"))
  expect_match(stancode, "Zs_2_2 * s_2_2", fixed = TRUE)
  expect_match(stancode, "matrix[N, knots_2[2]] Zs_2_2", fixed = TRUE)
  expect_match(stancode, "zs_2_2 ~ normal(0, 1)", fixed = TRUE)
  expect_match(stancode, "sds_2_2 ~ normal(0,2)", fixed = TRUE)
})

test_that("make_stancode correctly handles the group ID syntax", {
  form <- bf(count ~ Trt_c + (1+Trt_c|3|visit) + (1|patient), 
             shape ~ (1|3|visit) + (Trt_c||patient))
  sc <- make_stancode(form, data = epilepsy, family = negbinomial())
  expect_match(sc, "r_2_1 = r_2[, 1]", fixed = TRUE)
  expect_match(sc, "r_2_shape_3 = r_2[, 3]", fixed = TRUE)
  
  form <- bf(count ~ a, sigma ~ (1|3|visit) + (Trt_c||patient),
             nonlinear = a ~ Trt_c + (1+Trt_c|3|visit) + (1|patient))
  sc <- make_stancode(form, data = epilepsy, family = student(),
                      prior = set_prior("normal(0,5)", nlpar = "a"))
  expect_match(sc, "r_2_a_3 = r_2[, 3];", fixed = TRUE)
  expect_match(sc, "r_1_sigma_2 = sd_1[2] * (z_1[2]);", fixed = TRUE)
})

test_that("make_stancode correctly computes ordinal thresholds", {
  sc <- make_stancode(rating ~ period + carry + treat, 
                      data = inhaler, family = cumulative())
  expect_match(sc, "b_Intercept = temp_Intercept + dot_product(means_X, b);",
               fixed = TRUE)
  sc <- make_stancode(rating ~ period + carry + treat, 
                      data = inhaler, family = acat())
  expect_match(sc, "b_Intercept = temp_Intercept - dot_product(means_X, b);",
               fixed = TRUE)
})

test_that("make_stancode correctly parses distributional gamma models", {
  # test fix of issue #124
  scode <- make_stancode(bf(time ~ age * sex + disease + (1|patient), 
                            shape ~ age + (1|patient)), 
                         data = kidney, family = Gamma("log"))
  expect_match(scode, paste0("    shape[n] = exp(shape[n]); \n", 
                             "    eta[n] = shape[n] * exp(-(eta[n]));"),
               fixed = TRUE)
  
  scode <- make_stancode(bf(time ~ inv_logit(a) * exp(b * age),
                            nonlinear = a + b ~ sex + (1|patient), 
                            shape ~ age + (1|patient)), 
                         data = kidney, family = Gamma("identity"),
                         prior = c(set_prior("normal(2,2)", nlpar = "a"),
                                   set_prior("normal(0,3)", nlpar = "b")))
  expect_match(scode, paste0(
    "    shape[n] = exp(shape[n]); \n", 
    "    // compute non-linear predictor \n",
    "    eta[n] = shape[n] / (inv_logit(eta_a[n]) * exp(eta_b[n] * C[n, 1]));"),
    fixed = TRUE)
})

test_that("make_stancode handles censored responses correctly", {
  dat <- data.frame(y = 1:9, x = rep(-1:1, 3), y2 = 10:18)
  expect_match(make_stancode(y | cens(x, y2) ~ 1, dat, poisson()),
               "target += poisson_lpmf(Y[n] | eta[n]); \n", 
               fixed = TRUE)
  expect_match(make_stancode(y | cens(x) ~ 1, dat, weibull()), 
               "target += weibull_lccdf(Y[n] | shape, eta[n]); \n",
               fixed = TRUE)
  dat$x[1] <- 2
  expect_match(make_stancode(y | cens(x, y2) ~ 1, dat, gaussian()), 
               "target += log_diff_exp(normal_lcdf(rcens[n] | eta[n], sigma),",
               fixed = TRUE)
  dat$x <- 1
  make_stancode(y | cens(x) + weights(x) ~ 1, dat, weibull())
  expect_match(make_stancode(y | cens(x) + weights(x) ~ 1, dat, weibull()),
               paste("target += weights[n] * weibull_lccdf(Y[n] |", 
                     "shape, eta[n]); \n"), fixed = TRUE)
})
