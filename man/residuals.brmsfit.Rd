% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/brmsfit-methods.R
\name{residuals.brmsfit}
\alias{residuals.brmsfit}
\title{Extract Model Residuals from brmsfit Objects}
\usage{
\method{residuals}{brmsfit}(object, newdata = NULL, re_formula = NULL,
  type = c("ordinary", "pearson"), method = c("fitted", "predict"),
  allow_new_levels = FALSE, incl_autocor = TRUE, subset = NULL,
  nsamples = NULL, sort = FALSE, summary = TRUE, robust = FALSE,
  probs = c(0.025, 0.975), ...)
}
\arguments{
\item{object}{An object of class \code{brmsfit}}

\item{newdata}{An optional data.frame for which to evaluate predictions.
If \code{NULL} (default), the orginal data of the model is used.}

\item{re_formula}{formula containing random effects 
to be considered in the prediction. 
If \code{NULL} (default), include all random effects; 
if \code{NA}, include no random effects.}

\item{type}{The type of the residuals, 
either \code{"ordinary"} or \code{"pearson"}. 
More information is provided under 'Details'.}

\item{method}{Indicates the method to compute
model implied values. Either \code{"fitted"}
(predicted values of the regression curve) or
\code{"predict"} (predicted response values). 
Using \code{"predict"} is recommended
but \code{"fitted"} is the current default for 
reasons of backwards compatibility.}

\item{allow_new_levels}{A flag indicating if new
levels of random effects are allowed (defaults to \code{FALSE}). 
Only relevant if \code{newdata} is provided.}

\item{incl_autocor}{A flag indicating if autocorrelation
parameters should be included in the predictions. 
Defaults to \code{TRUE}.}

\item{subset}{A numeric vector specifying
the posterior samples to be used. 
If \code{NULL} (the default), all samples are used.}

\item{nsamples}{Positive integer indicating how many 
posterior samples should be used. 
If \code{NULL} (the default) all samples are used.
Ignored if \code{subset} is not \code{NULL}.}

\item{sort}{Logical. Only relevant for time series models. 
Indicating whether to return predicted values in the original 
order (\code{FALSE}; default) or in the order of the 
time series (\code{TRUE}).}

\item{summary}{Should summary statistics 
 (i.e. means, sds, and 95\% intervals) be returned
instead of the raw values? Default is \code{TRUE}.}

\item{robust}{If \code{FALSE} (the default) the mean is used as 
the measure of central tendency and the standard deviation as 
the measure of variability. If \code{TRUE}, the median and the 
median absolute deivation (MAD) are applied instead.
Only used if \code{summary} is \code{TRUE}.}

\item{probs}{The percentiles to be computed by the \code{quantile} 
function. Only used if \code{summary} is \code{TRUE}.}

\item{...}{Currently ignored}
}
\value{
Model residuals. If \code{summary = TRUE} 
 this is a N x C matrix and if \code{summary = FALSE} 
 a S x N matrix, where S is the number of samples, 
 N is the number of observations, and C is equal to 
 \code{length(probs) + 2}.
}
\description{
Extract Model Residuals from brmsfit Objects
}
\details{
Residuals of type \code{ordinary} 
 are of the form \eqn{R = Y - Yp}, where \eqn{Y} is the observed 
 and \eqn{Yp} is the predicted response.
 Residuals of type \code{pearson} are 
 of the form \eqn{R = (Y - Yp) / SD(Y)},
 where \eqn{SD(Y)} is an estimation of the standard deviation 
 of \eqn{Y}. \cr
  
 Currently, \code{residuals.brmsfit} does not support 
 \code{categorical} or ordinal models.
}
\examples{
\dontrun{
## fit a model
fit <- brm(rating ~ treat + period + carry + (1|subject), 
           data = inhaler, cluster = 2)

## extract residuals 
res <- residuals(fit, summary = TRUE)
head(res)
}

}

