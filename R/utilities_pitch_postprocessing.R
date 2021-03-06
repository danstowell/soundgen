### UTILITIES FOR POSTPROCESSING OF PITCH CONTOURS ###

#' Pathfinder
#'
#' Internal soundgen function.
#'
#' Internal helper function for postprocessing pitch contour. Starts with a
#' reasonable guess and computes the more-or-less optimal pitch contour (not
#' quite the very optimal - too computationally expensive).
#' @param pitchCands a matrix of multiple pitch candidates per fft frame. Each
#'   column is one fft frame, each row is one candidate.
#' @param pitchCert a matrix of the same dimensionality as pitchCands specifying
#'   our certainty in pitch candidates
#' @inheritParams analyze
#' @param interpolWin when interpolating pitch candidates, the median is
#'   calculated over \code{± interpolWin}
#' @param interpolTol when interpolating pitch candidates, the criterion
#'   for needing to interpolate is the absense of pitch candidates with values
#'   within \code{1 ± interpolTol} of the median of pitch center of
#'   gravity over the interpolation window. For ex., if \code{interpolTol}
#'   is .05, we look for values from 0.95 to 1.05 time the median value over
#'   interpolation window.
#' @param interpolCert when interpolating pitch candidates, all generated pitch
#'   candidates are assigned a certainty equal to \code{interpolCert}
#' @return Returns a numeric vector of pitch values representing the best found
#'   path through pitch candidates.
#' @keywords internal
pathfinder = function(pitchCands,
                      pitchCert,
                      certWeight = 0.5,
                      pathfinding = c('none', 'fast', 'slow')[2],
                      annealPars = list(maxit = 5000, temp = 1000),
                      interpolWin = 3,
                      interpolTol = 0.05,
                      interpolCert = 0.3,
                      snakeStep = 0.05,
                      snakePlot = FALSE) {
  # take log to approximate human perception of pitch differences
  pitchCands[!is.na(pitchCands)] = log2(pitchCands[!is.na(pitchCands)])

  # get the "center of gravity" of pitch candidates in each frame (mean of all
  # pitch candidates weighted by their respective certainties)
  pitchCenterGravity = apply(as.matrix(1:ncol(pitchCands), nrow = 1), 1, function(x) {
    mean(
      pitchCands[, x],
      weights = pitchCert[, x] / sum(pitchCert[, x]),
      na.rm = T
    )
  })

  ## INTERPOLATION
  # if a frame has no pitch candidate at all (NA) or no candidate
  # between the most likely candidates for the adjacent frames, add such a
  # candidate with ~low certainty
  if (is.numeric(interpolWin) && interpolWin > 0) {
    intplt = interpolate(pitchCands = pitchCands,
                         pitchCert = pitchCert,
                         pitchCenterGravity = pitchCenterGravity,
                         interpolWin = interpolWin,
                         interpolTol = interpolTol,
                         interpolCert = interpolCert)
    pitchCands = intplt$pitchCands
    pitchCert = intplt$pitchCert
    pitchCenterGravity = intplt$pitchCenterGravity
  }

  # order pitch candidates and certainties in each frame from lowest to highest
  # pitch (helpful for further processing)
  if (nrow(pitchCands) > 1) {
    o = apply(as.matrix(1:ncol(pitchCands), nrow = 1), 1, function(x) {
      order(pitchCands[, x])
    })
    pitchCands = apply(matrix(1:ncol(pitchCands)), 1, function(x) {
      pitchCands[o[, x], x]
    })
    pitchCert = apply(matrix(1:ncol(pitchCert)), 1, function(x) {
      pitchCert[o[, x], x]
    })
  }

  # remove rows with all NA's
  pitchCands = pitchCands[rowSums(!is.na(pitchCands)) != 0, , drop = FALSE]
  pitchCert = pitchCert[rowSums(!is.na(pitchCert)) != 0, , drop = FALSE]

  # special case: only a single pitch candidate for all frames in a syllable
  # (no paths to chose among)
  if (nrow(pitchCands) == 1) {
    return(2 ^ pitchCands)
  }

  ## PATH-FINDING
  # find the best path through frame-by-frame pitch candidates
  if (ncol(pitchCands) < 2) pathfinding = 'none'
  if (pathfinding == 'fast') {
    bestPath = pathfinding_fast(
      pitchCands = pitchCands,
      pitchCert = pitchCert,
      pitchCenterGravity = pitchCenterGravity,
      certWeight = certWeight
    )
  } else if (pathfinding == 'slow') {
    bestPath = pathfinding_slow(
      pitchCands = pitchCands,
      pitchCert = pitchCert,
      certWeight = certWeight,
      pitchCenterGravity = pitchCenterGravity,
      annealPars = annealPars
    )
  } else {
    bestPath = apply(matrix(1:ncol(pitchCands)), 1, function(x) {
      idx = which.min(abs(pitchCands[, x] - pitchCenterGravity[x]))
      pitchCands[idx, x]
    }) # or bestPath = pitchCenterGravity
  }

  ## SNAKE
  # apply the snake algorithm to minimize the elastic forces acting on this
  # pitch contour without deviating too far from high-certainty anchors
  if (is.numeric(snakeStep) && snakeStep > 0) {
    bestPath = snake(
      pitch = bestPath,
      pitchCands = pitchCands,
      pitchCert = pitchCert,
      certWeight = certWeight,
      pitchCenterGravity = pitchCenterGravity,
      snakeStep = snakeStep,
      snakePlot = snakePlot
    )
  }

  return(2 ^ bestPath)
}


#' Interpolate
#'
#' Internal soundgen function.
#'
#' Interpolation: if a frame has no pitch candidate at all (NA) or no candidate
#' between the most likely candidates for the adjacent frames, add such a
#' candidate with some (low) certainty.
#' @inheritParams pathfinder
#' @inheritParams analyze
#' @param pitchCenterGravity numeric vector giving the mean of all pitch
#'   candidates per fft frame weighted by our certainty in each of these
#'   candidates
#' @return Returns a modified pitchCands matrix.
#' @keywords internal
interpolate = function(pitchCands,
                       pitchCert,
                       pitchCenterGravity,
                       interpolWin = 3,
                       interpolTol = 0.3,
                       interpolCert = 0.3) {
  for (f in 1:ncol(pitchCands)) {
    left = max(1, f - interpolWin)
    right = min(ncol(pitchCands), f + interpolWin)
    # median over interpolation window (by default ±2 points)
    med = median(pitchCenterGravity[left:right], na.rm = TRUE)
    sum_pitchCands = sum(
      pitchCands[, f] > (1 - interpolTol) * med &
        pitchCands[, f] < (1 + interpolTol) * med,
      na.rm = TRUE
    )
    if (sum_pitchCands == 0 & !is.na(med)) {
      # if there are no pitch candidates in the frequency range
      # expected based on pitch candidates in the adjacent frames...
      # ... add an empty row for a new, interpolated pitch candidate
      pitchCands = rbind(pitchCands, rep(NA, ncol(pitchCands)))
      pitchCert = rbind(pitchCert, rep(NA, ncol(pitchCert)))
      # use median of adjacent frames for the new pitch cand
      pitchCands[nrow(pitchCands), f] = med
      # certainty assigned to interpolated frames
      pitchCert[nrow(pitchCert), f] = interpolCert
      # update pitchCenterGravity for the interpolated frame
      pitchCenterGravity[f] = mean(pitchCands[, f],
                                   weights = pitchCert[, f] / sum(pitchCert[, f]),
                                   na.rm = TRUE)
    }
  }
  return(list(pitchCands = pitchCands,
              pitchCert = pitchCert,
              pitchCenterGravity = pitchCenterGravity))
}


#' Path through pitch candidates: fast
#'
#' Internal soundgen function.
#'
#' Uses a quick-and-simple heuristic to find a reasonable path though pitch
#' candidates. The idea is to start at the median of the center of gravity of
#' pitch candidates over the first/last few frames and then go over the path
#' twice (forward and backward), minimizing the cost of transitions at each step
#' in terms of pitch jumps and distance from high-certainty candidates. The best
#' of these two paths is accepted.
#' @inheritParams pathfinder
#' @inheritParams analyze
#' @param pitchCenterGravity numeric vector giving the mean of all pitch
#'   candidates per fft frame weighted by our certainty in each of these
#'   candidates
#' @keywords internal
pathfinding_fast = function(pitchCands = pitchCands,
                            pitchCert = pitchCert,
                            pitchCenterGravity = pitchCenterGravity,
                            certWeight = certWeight) {
  # start at the beginning of the snake: find the most plausible starting pitch
  # by taking median over the first few frames, weighted by certainty
  p = median(pitchCenterGravity[1:min(5, length(pitchCenterGravity))],
             na.rm = TRUE)
  c = pitchCert[, 1] / abs(pitchCands[, 1] - p) # b/c there may be NA's,
  # and they can't be excluded directly in which.max in the next line
  point_current = pitchCands[which.max(c), 1]
  path = point_current
  costPathForward = 0

  for (i in 2:ncol(pitchCands)) {
    cands = na.omit(pitchCands[, i])
    if (length(cands) > 0) { # in case of an NA in the contour
      cost_cert = abs(cands - pitchCenterGravity[i])
      # get the cost of transition from the current point to each of the pitch
      # candidates in the next frame
      cost_pitchJump = apply(as.matrix(1:length(cands), nrow = 1), 1, function(x) {
        costJumps(point_current, cands[x])
      })
      if (length(cost_pitchJump) == 0) cost_pitchJump = 0
      # get a weighted average of transition costs associated with the certainty
      # of each estimate vs. the magnitude of pitch jumps
      costs = certWeight * cost_cert + (1 - certWeight) * cost_pitchJump
      path = c(path, pitchCands[which.min(costs), i])
      costPathForward = costPathForward + min(costs)
    }
  }

  # run backwards
  pitchCands_rev = pitchCands[, rev(1:ncol(pitchCands)), drop = FALSE]
  pitchCert_rev = pitchCert[, rev(1:ncol(pitchCert)), drop = FALSE]
  pitchCenterGravity_rev = rev(pitchCenterGravity)

  p = median (pitchCenterGravity_rev[1:min(5, length(pitchCenterGravity_rev))])
  c = na.omit (pitchCert_rev[, 1] / abs(pitchCands_rev[, 1] - p)) # b/c there may be NA's,
  # and they can't be excluded directly in which.max in the next line
  point_current = pitchCands_rev[which.max(c), 1]
  path_rev = point_current
  costPathBackward = 0

  for (i in 2:ncol(pitchCands_rev)) {
    cands = na.omit(pitchCands_rev[, i])
    if (length(cands) > 0) { # in case of an NA in the contour
      cost_cert = abs(cands - pitchCenterGravity_rev[i])
      cost_pitchJump = apply(as.matrix(1:length(cands), nrow = 1), 1, function(x) {
        costJumps(point_current, cands[x])
      })
      if (length(cost_pitchJump) == 0) cost_pitchJump = 0
      costs = certWeight * cost_cert + (1 - certWeight) * cost_pitchJump
      path_rev = c(path_rev, pitchCands_rev[which.min(costs), i])
      costPathBackward = costPathBackward + min(costs)
    }
  }

  if (costPathForward < costPathBackward) {
    bestPath = path
  } else {
    bestPath = rev(path_rev)
  }
  return(bestPath)
}


#' Cost of jumps
#'
#' Internal soundgen function.
#'
#' Internal helper function for calculating the cost of transitions between
#' pitch candidates. Needed for postprocessing of pitch contour - finding the
#' optimal pitch contour.
#' @param cand1,cand2 two candidate pitch values
#' @keywords internal
#' @examples
#' a = seq(-3, 3, by = .01)
#' b = 1 / (1 + 10 * exp(3 - 7 * abs(a)))
#' plot(a, b, type = 'l')
costJumps = function(cand1, cand2) {
  return (1 / (1 + 10 * exp(3 - 7 * abs(cand1 - cand2))))
}


#' Path through pitch candidates: slow
#'
#' Internal soundgen function.
#'
#' Optimizes the path through pitch candidates using simulated annealing with
#' \code{\link[stats]{optim}}. This can be really slow, depending on control
#' parameters.
#' @inheritParams pathfinder
#' @inheritParams analyze
#' @param pitchCenterGravity numeric vector giving the mean of all pitch
#'   candidates per fft frame weighted by our certainty in each of these
#'   candidates
#' @keywords internal
pathfinding_slow = function(pitchCands = pitchCands,
                            pitchCert = pitchCert,
                            certWeight = certWeight,
                            pitchCenterGravity = pitchCenterGravity,
                            annealPars = list(maxit = 5000, temp = 1000)) {
  # start with the pitch contour most faithful to center of gravity of pitch
  # candidates for each frame
  path_init = apply(matrix(1:ncol(pitchCands)), 1, function(x) {
    which.min(abs(pitchCands[, x] - pitchCenterGravity[x]))
  })

  # use annealing to wiggle the path, attempting to minimize its cost
  o = optim(
    par = path_init,
    fn = costPerPath,
    gr = generatePath,
    pitchCands = pitchCands,
    pitchCert = pitchCert,
    certWeight = certWeight,
    pitchCenterGravity = pitchCenterGravity,
    method = 'SANN',
    control = annealPars
  )

  bestPath = apply(matrix(1:ncol(pitchCands)), 1, function(x) {
    pitchCands[o$par[x], x]
  })
  return(bestPath)
}


#' Cost per path
#'
#' Internal soundgen function.
#'
#' Internal helper function for postprocessing of pitch contours called by
#' \code{\link{pathfinding_slow}}. Calculates the cost of a particular path
#' through pitch candidates based on pitch jumps and distance from
#' high-certainty candidates.
#' @param path evaluated path through pitch candidates (as integers specifying
#'   the rows in pitchCands, not the actual values of pitch)
#' @inheritParams pathfinder
#' @param pitchCenterGravity numeric vector giving the mean of all pitch
#'   candidates per fft frame weighted by our certainty in each of these
#'   candidates
#' @keywords internal
costPerPath = function(path,
                       pitchCands,
                       pitchCert,
                       certWeight,
                       pitchCenterGravity) {
  # if there is nothing to wiggle, generatePath() returns NA and we want
  # annealing to terminate quickly, so we return very high cost
  if (is.na(path[1])) return(1e10)
  # get the cost of transition from the current point to each of the pitch
  # candidates in the next frame
  cost_pitchJump = apply(as.matrix(1:(length(path) - 1), nrow = 1), 1, function(x) {
    costJumps(pitchCands[path[x], x], pitchCands[path[x + 1], x + 1])
  })
  cost_pitchJump = mean(cost_pitchJump, na.rm = TRUE)

  # get the cost of deviating from pitchCenterGravity
  cost_cert = apply(as.matrix(1:length(path)), 1, function(x) {
    abs(pitchCands[path[x], x] - pitchCenterGravity[x])
  })
  cost_cert = mean(cost_cert, na.rm = TRUE)

  # get a weighted average of transition costs associated with the certainty
  # of each estimate vs. the magnitude of pitch jumps
  costs = certWeight * cost_cert + (1 - certWeight) * cost_pitchJump
  return(costs)
}


#' Generate path
#'
#' Internal soundgen function.
#'
#' Internal helper function for postprocessing of pitch contours called by
#' \code{\link{pathfinding_slow}}. Generates proposals for new paths through
#' pitch candidates. It gives up and returns NA after 100 attempts, which stops
#' annealing - so the adaptation of pitch contour doesn't happen if
#' @param path currently evaluated path
#' @inheritParams pathfinder
#' @param ... nothing really, but otherwise optim() complains
#' @keywords internal
generatePath = function(path, pitchCands, ...) {
  i = 1
  while (i < 100) {
    point_to_wiggle = sample(1:length(path), 1)
    idx = which(!is.na(pitchCands[, point_to_wiggle])) [-path[point_to_wiggle]]
    if (length(idx) > 0 && is.numeric(idx)) {
      path[point_to_wiggle] = idx[1]
      return(path)
    }
    i = i + 1
  }
  return(NA)
}


#' Snake
#'
#' Internal soundgen function.
#'
#' Internal helper function for postprocessing of pitch contour. Wiggles a snake
#' along the gradient of internal + external forces. NB: if the snake is run,
#' the final contour may deviate from the actually measured pitch candidates!
#' @param pitch numeric vector representing our best guess at pitch contour,
#'   which we are now attempting to improve by minimizing its elastic tension
#' @inheritParams pathfinder
#' @inheritParams analyze
#' @param pitchCenterGravity numeric vector giving the mean of all pitch
#'   candidates per fft frame weighted by our certainty in each of these
#'   candidates
#' @return Returns optimized pitch contour (numeric vector of the same length as
#'   \code{pitch}).
#' @keywords internal
snake = function(pitch,
                 pitchCands,
                 pitchCert,
                 certWeight,
                 pitchCenterGravity,
                 snakeStep = 0.05,
                 snakePlot = FALSE) {
  ran = diff(range(pitchCands, na.rm = TRUE)) # range of pitch
  maxIter = floor(ran / snakeStep * 2)  # just heuristic, no theory behind this

  # plot for debugging or esthetic appreciation
  if (snakePlot) {
    # plot all pitch candidates and the initial path
    plot(seq(1, ncol(pitchCands)), pitch,
         type = 'n', xlab = 'FFT frame', ylab = 'log(pitch)',
         ylim = c(
           range(pitchCands, na.rm = TRUE)[1] - .3 * ran,
           range(pitchCands, na.rm = TRUE)[2] + .3 * ran
         )
    )
    for (r in 1:nrow(pitchCands)) {
      points (seq(1, ncol(pitchCands)),
              pitchCands[r, ],
              cex = as.numeric(pitchCert[r, ]) * 2)
    }
    lines (seq(1, ncol(pitchCands)), pitch)
  }

  # optimization algorithm follows
  i = 1
  force_old = 1e10  # Inf causes NaN in force_delta
  while (i < maxIter) {
    force = forcePerPath(pitch = pitch,
                         pitchCands = pitchCands,
                         pitchCert = pitchCert,
                         pitchCenterGravity = pitchCenterGravity,
                         certWeight = certWeight)
    force_new = mean(abs(force))
    force_delta = (force_old - force_new) / force_old
    force_old = force_new
    if (is.na(force_delta) || force_delta < snakeStep) break
    # wiggle the snake along the gradient of the total force acting on it
    # (elastic + attraction of high-certainty pitch candidates)
    pitch = pitch + snakeStep * force
    if (snakePlot) {
      lines(seq(1, length(pitch)), pitch,
            type = 'l', col = 'green', lty = 4)
    }
    i = i + 1
  }

  if (snakePlot) {
    lines(seq(1, length(pitch)), pitch,
          type = 'l', col = 'blue', lwd = 3)
  }
  return (pitch)
}


#' Force per path
#'
#' Internal soundgen function.
#'
#' Internal helper function for postprocessing of pitch contour. Returns the
#' total force acting on a snake (sum of internal and external gradients, i.e.
#' of the elastic force trying to straighten the snake [internal] and of the
#' force pushing the snake towards the most certain pitch estimates [external])
#' @inheritParams snake
#' @inheritParams pathfinder
#' @inheritParams analyze
#' @param pitchCenterGravity numeric vector giving the mean of all pitch
#'   candidates per fft frame weighted by our certainty in each of these
#'   candidates
#' @return Returns a numeric vector of the same length as \code{pitch} that
#'   gives the total force acting on the snake at each point.
#' @keywords internal
forcePerPath = function (pitch,
                         pitchCands,
                         pitchCert,
                         pitchCenterGravity,
                         certWeight) {
  ran = diff(range(pitchCands, na.rm = TRUE))
  # external_force = -(pitch_path - pitchCenterGravity) / ran
  external_force = pitch # just a quick way to initialize a vector of the right length
  for (i in 1:ncol(pitchCands)) {
    cands = na.omit(pitchCands[, i])
    certs = na.omit(pitchCert[, i])
    deltas = 1 / exp((cands - pitch[i]) ^ 2)
    forces = certs * deltas
    forces = ifelse(cands > pitch[i], forces, -forces)
    external_force[i] = sum(forces)
  }
  # external_force is the "external" force - the attraction of high-certainty
  # pitch candidates

  internal_force = -findGrad(pitch)
  # internal_force is the elastic force trying to make the curve smooth

  total_force = certWeight * external_force + (1 - certWeight) * internal_force
  # weighted average of internal and external forces

  return(total_force)
}


#' Find gradient
#'
#' Internal soundgen function.
#'
#' Internal helper function for postprocessing of pitch contour. Returns
#' the elastic force acting on a snake. See \code{\link{snake}}.
#' @param path numeric vector
#' @param interpol the number of points to interpolate beyond each end of the path
#' @return Returns a vector of the same length as input path giving its 4th derivative.
#' @keywords internal
findGrad = function(path, interpol = 3) {
  # interpolate 2 values before the first one and two after the last one based
  # on /interpol/ number of points in case the path is shorter than the
  # specified interpol:
  interpol = ifelse(interpol > length(path), length(path), interpol)
  if (interpol == 1) {
    path = c(rep(path[1], 2), path, rep(path[length(path)], 2))
  } else {
    slopeLeft = suppressWarnings(summary(lm(
      path[1:interpol] ~ seq(1, interpol)
    ))$coef[2, 1])
    minus12 = path[1] - c(1, 2) * slopeLeft
    slopeRight = suppressWarnings(summary(lm(
      path[(length(path) - interpol + 1):length(path)] ~ seq(1, interpol)
    ))$coef[2, 1])
    plus12 = path[length(path)] + c(1, 2) * slopeRight
    path = c (minus12[2], minus12[1], path, plus12[1], plus12[2])
  }

  # take the 4th derivative of the path with interpolated values
  # (so that we get d4f over the entire length of the original path)
  grad = rep(0, length(path))
  for (i in 3:(length(path) - 2)) {  # approximation
    grad[i] = path[i - 2] - 4 * path[i - 1] + 6 * path[i] - 4 * path[i + 1] +
      path[i + 2]
  }
  grad = grad[3:(length(grad) - 2)]
  return (grad)
}


#' Median smoothing
#'
#' Internal soundgen function.
#'
#' Internal helper function for smoothing pitch contours or other contours. Only
#' outliers are modified, so it's not like smoothing with a kernel. NB: the
#' expected input is pitch, so deviance is calculated on a log-scale.
#' @param df dataframe (each column is processed separately, so multiple
#'   contours can be fed into this function at once to speed things up)
#' @param smoothing_ww width of smoothing window (points)
#' @param smoothingThres tolerated deviance from moving median (semitones)
#' @return Returns a dataframe of the same dimensions as df.
#' @keywords internal
#' @examples
#' df = data.frame(a = rnorm(100, mean = 100, sd = 20),
#'                 b = rnorm(100, mean = 100, sd = 10))
#' df1 = soundgen:::medianSmoother(df, smoothing_ww = 5, smoothingThres = 1)
#' plot(df[, 2], type='b')
#' lines(df1[, 2], type='b', col='blue', pch=3)
medianSmoother = function (df, smoothing_ww, smoothingThres) {
  temp = df # to calculate median_over_window for original values
  hw = floor(smoothing_ww / 2) # smooth over ± half the smoothing_ww
  for (i in 1:nrow(df)) {
    window = c (max(i - hw, 1), min(i + hw, nrow(df))) # smoothing window
    median_over_window = apply(as.matrix(temp[(window[1]:window[2]), ]), 2, function(x) {
      median(unlist(x), na.rm = TRUE)  # w/o unlist returns NULL for NA vectors (weird...)
      # NB: use either temp or df, for original or smoothed values to be used
      # for calculating median_over_window
    })
    # difference from median pitch etc over window, in semitones
    deviance = 12 * log2(as.numeric(df[i, ]) / median_over_window)
    cond = which(abs(deviance - 1) > smoothingThres)
    df[i, cond] = median_over_window[cond]
  }
  return (df)
}


#' Find voiced segments
#'
#' Internal soundgen function.
#'
#' Internal helper function for postprocessing of pitch contours. Merges voiced
#' segments at least \code{shortestSyl} ms long and separated by less than
#' \code{shortestPause} ms.
#' @param pitchCands matrix of possible pitch values per column. One column is
#'   one fft frame, one row is one pitch candidate
#' @inheritParams analyze
#' @inheritParams spectrogram
#' @param samplingRate sampling rate (Hz)
#' @param minVoicedCands a frame is considered to be voiced if at least this
#'   many pitch candidates are not NA. Defaults to 2: since dom is usually
#'   defined, in practice this means that we also want at least one other pitch
#'   candidate (autocor, cep or BaNa)
#' @return Returns a dataframe specifying where each voiced segment starts and
#'   ends (in fft frames, not ms!)
#' @keywords internal
findVoicedSegments = function(pitchCands,
                              shortestSyl,
                              shortestPause,
                              step,
                              samplingRate,
                              minVoicedCands) {
  putativelyVoiced = apply(pitchCands, 2, function(x) {
    ifelse(sum(!is.na(x)) >= minVoicedCands, 1, NA)
  })
  # the smallest number of consecutive non-NA pitch values that constitute a
  # voiced segment; but at least 1
  noRequired = max(1, ceiling(shortestSyl / step))
  # the greatest number of NA values that we tolerate before we say a new voiced
  # syllable begins
  nToleratedNA = floor(shortestPause / step)

  # find and save separately all voiced segments
  segmentStart = numeric()
  segmentEnd = numeric()
  i = 1
  while (i < (length(putativelyVoiced) - noRequired + 1)) {
    # find beginning
    while (i < (length(putativelyVoiced) - noRequired + 1)) {
      if (sum(!is.na(putativelyVoiced[i:(i + noRequired - 1)])) == noRequired) {
        segmentStart = c(segmentStart, i)
        break
      }
      i = i + 1
    }
    # find end
    if (length(segmentEnd) < length(segmentStart)) {
      while (i < (length(putativelyVoiced) - nToleratedNA + 1)) {
        if (sum(putativelyVoiced[i:(i + nToleratedNA)], na.rm = TRUE) == 0) {
          segmentEnd = c(segmentEnd, i - 1)
          i = i - 1
          break
        }
        i = i + 1
      }
      if (length(segmentEnd) < length(segmentStart)) {
        # if the end is not found, take the last non-NA value
        segmentEnd = c(segmentEnd, tail(which(!is.na(putativelyVoiced)), 1))
        break
      }
    }
    i = i + 1
  }
  return (data.frame(segmentStart = segmentStart, segmentEnd = segmentEnd))
}
