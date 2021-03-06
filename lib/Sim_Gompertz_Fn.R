#' Simulate data from a Gompertz population dynamics model.
#'
#' @description Simulate data for \code{n_years} and \code{n_stations}
#' using the \code{\pkg{RandomFields}} package and a Gompertz population
#' dynamics model. The model uses a recursive equation to simulate population
#' dynamics rather than an autoregressive equation.
#' If you plan on using the results of \code{Sim_Gompertz_Fn} in a simulation,
#' your parameter estimates will be less biased if you use a recursive equation
#' in your estimation routine as well, rather than an autoregressive estimation
#' method. The majority of the bias will be in the variance parameters if you
#' choose to not do the self test.
#'
#' @details The code for this function originally came from James Thorson
#' and his github repository
#' \url{https://github.com/James-Thorson/2016_Spatio-temporal_models/Week 7 -- spatiotemporal models/Lab/Sim_Gompertz_Fn.R}
#'
#' @param n_years The number of years you want data for
#' @param n_stations The number of stations you want samples for
#' @param phi The fraction from equilibrium you want to start from
#' The default is to start at a random \code{rnorm(1, mean = 0, sd = 1)}
#' start value.
#' @param rho Density-dependence
#' @param logMeanDens A scalar or vector of log mean density that will be
#' converted into \code{alpha} or mean productivity.
#' \code{alpha} = \code{logMeanDens} * (1 - \code{rho}).
#' @param SpatialScale The scale of the spatial random effects, must be
#' in the same units as the locations.
#' @param SD_O The marginal standard deviation of Omega.
#' @param SD_E The marginal standard deviation of
#' temporal and spatial process error.
#' @param SD_E The standard deviation of observation error.
#' @param SD_extra Extra variance in the poisson distribution.
#' @param log_clustersize The natural log of the expected cluster size
#'   for the Poisson lognormal distribution.
#' @param Loc A two-column matrix of locations.
#' @param projection The projection for your \code{Loc}.
#' @param gridlimits A vector of numeric values specifying the grid limits
#'   if \code{is.null(Loc)}. The values will be used to create a square grid.
#' @param model A character value specifying the \code{\link{RandomFields}}
#'   covariance model to use for the simulated spatial field. Currently,
#'   the options are \code{"RMgauss"}, which is the default, and
#'   \code{RMgneiting}, which is more stable than the default.
#' @param seed A numeric value providing the random seed for the simulation.
#'
#' @examples
#' test <- Sim_Gompertz_Fn(n_years = 10, n_stations = 50, phi = NULL,
#'   rho = 0.5, logMeanDens = c(1), SpatialScale = 0.1,
#'   SD_O = 0.5, SD_E = 1.0, SD_obs = 1.0, log_clustersize = log(4),
#'   Loc = NULL, projection = NULL,
#'   model = "RMgauss", seed = 1)
#'
Sim_Gompertz_Fn <- function(n_years, n_stations = 100, phi = NULL,
  rho = 0.5, logMeanDens = 1, SpatialScale = 0.1,
  SD_O = 0.5, SD_E = 1.0, SD_obs = 1.0, SD_extra = 0, log_clustersize = log(4),
  Loc = NULL, projection = NULL, gridlimits = c(0, 1),
  model = "RMgauss", seed = 1) {

  # Define Poisson lognormal from JTT::r_poisson_lognormal
  rlpois <- function(n, log_mean, sdlog, log_clustersize){
    encounterprob <- 1 - exp(-1 * exp(log_mean) / exp(log_clustersize));
    posTF <- rbinom(n = n, size = 1, prob = encounterprob)
    catch <- posTF *
      rlnorm(n = n, meanlog = log_mean - log(encounterprob), sdlog = sdlog)
    return(catch)
  }

###############################################################################
## Parameters
###############################################################################
  set.seed(seed)
  # Determine the starting position from equilibrium
  if (is.null(phi)) phi <- rnorm(1, mean = 0, sd = 1)

  # Calculate the mean growth rate for each subpopulation
  # If all values are the same, then condense alpha to the first value
  alpha <- logMeanDens * (1 - rho)
  if (length(unique(alpha)) == 1) alpha <- alpha[1]

###############################################################################
## Spatial model
###############################################################################
  # Randomly generate the locations if a matrix is not given
  # such that each polygon is approximately square, and if there is
  # only one alpha value then the spatial landscape is 1 x 1
  set.seed(seed + 1)
  if (is.null(Loc)) {
    if (length(gridlimits) != 2) {
      stop("gridlimits must have a length of two, \nwhereas a vector",
        " of length = ", length(gridlimits), " was supplied.")
    }
    Loc <- cbind(
      "x" = runif(n_stations, min = gridlimits[1], max = gridlimits[2]),
      "y" = runif(n_stations, min = gridlimits[1], max = gridlimits[2]))
  } else {
    # If locations are given, determine how many stations and
    # set column names
    n_stations <- NROW(Loc)
    if (NCOL(Loc) != 2) stop("Loc does not have two columns")
    colnames(Loc) <- c("x", "y")
  }

  # Create a polygon with a buffer around the locations
  pol_studyarea <- as(raster::extent(Loc), "SpatialPolygons")
  if (!is.null(projection)) sp::proj4string(pol_studyarea) <- projection
# Find the outer boundaries
  lonlimits <- unlist(attributes(
    raster::extent(pol_studyarea))[c("xmin", "xmax")])
  # Make them a little smaller so they will be not be split bad
  lonlimits <- ifelse(lonlimits < 0, lonlimits * 0.95, lonlimits * 1.05)
  latlimits <- unlist(attributes(raster::extent(
    calc_areabuffer(pol_studyarea, ratio = 3.5)))[c("ymin", "ymax")])
  # Find a new polygon that is 10% bigger
  pol_studyarea <- calc_areabuffer(pol_studyarea, ratio = 1.1,
    precision = 0.001)

  # Create SpatialPoints from Loc data
  points <- as.data.frame(Loc)
  sp::coordinates(points) <- ~ x + y
  if (!is.null(projection)) sp::proj4string(points) <- projection

  # Determine which subpopulation each location belongs to
  cuts <- NULL
  if (length(alpha) > 1) {
    table <- 0
    while (any(table < 1/length(alpha)/2) | all(table == 1)) {
      # Cut the min and max longitude into areas based on how many
      # alpha values are supplied.
      cuts <- runif(length(alpha) - 1, min = lonlimits[1], max = lonlimits[2])
      lines_grouptrue <- calc_lines(cuts = cuts, limits = latlimits,
        projection = projection)
      # Determine which polygon each point is in
      group <- sp::over(points, calc_polys(pol_studyarea, lines_grouptrue))
      table <- prop.table(table(group))
    }
  } else {
      group <- rep(1, length.out = NROW(Loc))
  }
  cuts <- c(latlimits[1], cuts)

  # scale determines the distance at which correlation declines to ~10% of
  # the maximum observed correlation
  # Estimates of "Range" should scale linearly with scale because
  # Range = sqrt(8)/exp(logkappa)
  if (model == "RMgauss") {
    model_O <- RandomFields::RMgauss(var = SD_O^2, scale = SpatialScale)
    model_E <- RandomFields::RMgauss(var = SD_E^2, scale = SpatialScale)
  }
  if (model == "RMgneiting") {
    model_O <- RandomFields::RMgneiting(orig = FALSE,
      var = SD_O^2, scale = SpatialScale)
    model_E <- RandomFields::RMgneiting(orig = FALSE,
      var = SD_E^2, scale = SpatialScale)
  }

  RandomFields::RFoptions(spConform = FALSE)
  # Simulate Omega
  Omega <- rep(NA, length(group))
  for (it_ in seq_along(alpha)) {
    temp <- which(group == it_)
    Omega[temp] <- RandomFields::RFsimulate(model = model_O,
      x = Loc[temp, "x"], y = Loc[temp, "y"])
  }
  if (any(is.na(Omega))) stop("Not all Omega values were created",
    "more than likely the cuts were placed outside of the boundaries.")
  rm(temp)

  # Simulate Epsilon
  set.seed(seed + 10)
  Epsilon <- array(NA, dim = c(n_stations, n_years))
  for(t in 1:n_years) {
    Epsilon[, t] <- RandomFields::RFsimulate(
      model = model_E,
      x = Loc[, "x"], y = Loc[, "y"])
  }

  RandomFields::RFoptions(spConform = TRUE)

###############################################################################
## Calculate Psi
###############################################################################
  Theta <- array(NA, dim = c(n_stations, n_years))
  DF <- array(NA, dim = c(n_stations * n_years, 12),
    dimnames = list(NULL, c(
      "Site",
      "Year",
      "lambda",
      "Simulated_example",
      "zeroinflatedlnorm",
      "group",
      "cuts",
      "Epsilon",
      "Omega",
      "alpha",
      "Longitude",
      "Latitude")))
  for (it_s in 1:n_stations) {
  for (t in 1:n_years) {
    if(t == 1) Theta[it_s, t] <- as.numeric(
      phi +
      (alpha[group[it_s]] + Omega[it_s])/(1 - rho) +
      Epsilon[it_s, t]
      )
    if(t >= 2) Theta[it_s, t] <- as.numeric(
      rho * Theta[it_s, t - 1] +
      (alpha[group[it_s]] + Omega[it_s]) +
      Epsilon[it_s, t]
      )
    counter <- ifelse(it_s == 1 & t == 1, 1, counter + 1)
    DF[counter, "Site"] <- it_s
    DF[counter, "Year"] <- t
    DF[counter, "lambda"] <- exp(Theta[it_s, t])
    DF[counter, "Simulated_example"] <- rpois(1,
      lambda = DF[counter, "lambda"] * exp(SD_extra * rnorm(1)))
    DF[counter, "zeroinflatedlnorm"] <- rlpois(1,
      log_mean = Theta[it_s, t], sdlog = SD_obs, log_clustersize = log_clustersize)
    DF[counter, "group"] <- as.numeric(group[it_s])
    DF[counter, "cuts"] <- cuts[DF[counter, "group"]]
    DF[counter, "Epsilon"] <- Epsilon[it_s, t]
    DF[counter, "Omega"] <- Omega[it_s]
    DF[counter, "alpha"] <- as.numeric(alpha[group[it_s]])
    DF[counter, "Longitude"] <- Loc[it_s, 1]
    DF[counter, "Latitude"] <- Loc[it_s, 2]
  }}

  DF <- as.data.frame(DF)
  DF <- DF[order(DF$group, DF$Site, DF$Year), ]
  DF$phi <- phi
  DF$cuts <- cuts[DF$group]
  DF$sd_O <- SD_O
  DF$sd_E <- SD_E
  DF$sd_obs <- SD_obs
  DF$log_clustersize <- log_clustersize
  DF$SpatialScale <- SpatialScale
  DF$seed <- seed
  DF$rho <- rho
  DF$model <- model

  return(DF)
}
