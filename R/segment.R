## FINDING SYLLABLES AND VOCAL BURSTS ##

#' Segment a sound
#'
#' Finds syllables and bursts. Syllables are defined as continuous segments with
#' ampiltude above threshold. Bursts are defined as local maxima in amplitude
#' envelope that are high enough both in absolute terms (relative to the global
#' maximum) and with respect to the surrounding region (relative to local
#' mimima). See the vignette on acoustic analysis for details.
#'
#' The algorithm is very flexible, but the parameters may be hard to optimize by
#' hand. If you have an annotated sample of the sort of audio you are planning
#' to analyze, with syllables and/or bursts counted manually, you can use it for
#' automatic optimization of control parameters (see
#' \code{\link{optimizePars}}. The defaults are the results of just such
#' optimization against 260 human vocalizations in Anikin, A. & Persson, T.
#' (2017). Non-linguistic vocalizations from online amateur videos for emotion
#' research: a validated corpus. Behavior Research Methods, 49(2): 758-771.
#' @param x path to a .wav file or a vector of amplitudes with specified
#'   samplingRate
#' @param samplingRate sampling rate of \code{x} (only needed if \code{x} is a
#'   numeric vector, rather than a .wav file)
#' @param windowLength,overlap length (ms) and overlap (%) of the smoothing
#'   window used to produce the amplitude envelope, see
#'   \code{\link[seewave]{env}}
#' @param shortestSyl minimum acceptable length of syllables, ms
#' @param shortestPause minimum acceptable break between syllables, ms.
#'   Syllables separated by less time are merged. To avoid merging, specify
#'   \code{shortestPause = NA}
#' @param sylThres amplitude threshold for syllable detection (as a
#'   proportion of global mean amplitude of smoothed envelope)
#' @param interburst minimum time between two consecutive bursts (ms). If
#'   specified, it overrides \code{interburstMult}
#' @param interburstMult multiplier of the default minimum interburst
#'   interval (median syllable length or, if no syllables are detected, the same
#'   number as \code{shortestSyl}). Only used if \code{interburst} is
#'   not specified. Larger values improve detection of unusually broad shallow
#'   peaks, while smaller values improve the detection of sharp narrow peaks
#' @param burstThres to qualify as a burst, a local maximum has to be at least
#'   \code{burstThres} times the height of the global maximum of amplitude
#'   envelope
#' @param peakToTrough to qualify as a burst, a local maximum has to be at
#'   least \code{peakToTrough} times the local minimum on the LEFT over
#'   analysis window (which is controlled by \code{interburst} or
#'   \code{interburstMult})
#' @param troughLeft,troughRight should local maxima be compared to the trough
#'   on the left and/or right of it? Default to TRUE and FALSE, respectively
#' @param summary if TRUE, returns only a summary of the number and spacing of
#'   syllables and vocal bursts. If FALSE, returns a list containing full stats
#'   on each syllable and bursts (location, duration, amplitude, ...)
#' @param plot if TRUE, produces a segmentation plot
#' @param savePath full path to the folder in which to save the plots. Defaults
#'   to NA
#' @param ... other graphical parameters passed to \code{\link[graphics]{plot}}
#' @return If \code{summary = TRUE}, returns only a summary of the number and
#'   spacing of syllables and vocal bursts. If \code{summary = FALSE}, returns a
#'   list containing full stats on each syllable and bursts (location, duration,
#'   amplitude, ...).
#' @export
#' @examples
#' sound = soundgen(nSyl = 8, sylLen = 50, pauseLen = 70,
#'   pitchAnchors = list(time = c(0, 1), value = c(368, 284)), temperature = 0.1,
#'   noiseAnchors = list(time = c(0, 67, 86, 186), value = c(-45, -47, -89, -120)),
#'   rolloff_noise = -8, amplAnchorsGlobal = list(time = c(0, 1), value = c(120, 20)))
#' spectrogram(sound, samplingRate = 16000, osc = TRUE)
#'  # playme(sound, samplingRate = 16000)
#'
#' s = segment(sound, samplingRate = 16000, plot = TRUE)
#' # accept quicker and quieter syllables
#' s = segment(sound, samplingRate = 16000, plot = TRUE,
#'   shortestSyl = 25, shortestPause = 25, sylThres = .6)
#' # look for narrower, sharper bursts
#' s = segment(sound, samplingRate = 16000, plot = TRUE,
#'   shortestSyl = 25, shortestPause = 25, sylThres = .6,
#'   interburstMult = 1)
#'
#' # just a summary
#' segment(sound, samplingRate = 16000, summary = TRUE)
segment = function(x,
                   samplingRate = NULL,
                   windowLength = 40,
                   overlap = 80,
                   shortestSyl = 40,
                   shortestPause = 40,
                   sylThres = 0.9,
                   interburst = NULL,
                   interburstMult = 1,
                   burstThres = 0.075,
                   peakToTrough = 3,
                   troughLeft = TRUE,
                   troughRight = FALSE,
                   summary = FALSE,
                   plot = FALSE,
                   savePath = NA,
                   ...) {
  mergeSyl = ifelse(is.null(shortestPause) || is.na(shortestPause), F, T)
  if (windowLength < 10) {
    warning('windowLength < 10 ms is slow and usually not very useful')
  }
  if (overlap < 0) overlap = 0
  if (overlap > 99) overlap = 99

  ## import a sound
  if (class(x) == 'character') {
    sound = tuneR::readWave(x)
    samplingRate = sound@samp.rate
    sound = sound@left
    plotname = tail(unlist(strsplit(x, '/')), n = 1)
    plotname = substring(plotname, 1, nchar(plotname) - 4)
  }  else if (class(x) == 'numeric' & length(x) > 1) {
    if (is.null(samplingRate)) {
      stop ('Please specify samplingRate, eg 44100')
    } else {
      sound = x
      plotname = ''
    }
  }

  ## normalize
  if (min(sound) > 0) {
    sound = scale(sound)
  }
  sound = sound / max(abs(max(sound)), abs(min(sound)))
  # plot(sound, type='l')

  ## extract amplitude envelope
  windowLength_points = ceiling(windowLength * samplingRate / 1000)
  if (windowLength_points > length(sound) / 2) {
    windowLength_points = length(sound) / 2
  }

  sound_downsampled = seewave::env(
    sound,
    f = samplingRate,
    msmooth = c(windowLength_points, overlap),
    fftw = TRUE,
    plot = FALSE
  )
  timestep = 1000 / samplingRate *
    (length(sound) / length(sound_downsampled)) # time step in the envelope, ms
  envelope = data.frame(time = ( (1:length(sound_downsampled) - 1) * timestep),
                        value = sound_downsampled)
  # plot (envelope, type='l')

  ## find syllables and get descriptives
  threshold = mean(envelope$value) * sylThres
  syllables = findSyllables(envelope = envelope,
                            timestep = timestep,
                            threshold = threshold,
                            shortestSyl = shortestSyl,
                            shortestPause = shortestPause,
                            mergeSyl = mergeSyl)

  ## find bursts and get descriptives
  # calculate the window for analyzing bursts based on the median duration of
  # syllables (if no syllables are detected, just use the specified shortest
  # acceptable syllable length)
  if (is.null(interburst)) {
    median_scaled = suppressWarnings(median(syllables$sylLen) * interburstMult)
    interburst = ifelse(is.numeric(median_scaled) && length(median_scaled) > 0,
                               median_scaled,
                               shortestSyl)
  }
  bursts = findBursts(envelope = envelope,
                      timestep = timestep,
                      interburst = interburst,
                      burstThres = burstThres,
                      peakToTrough = peakToTrough,
                      troughLeft = troughLeft,
                      troughRight = troughRight
  )

  ## plotting (optional)
  if (is.character(savePath)) plot = TRUE
  if (plot) {
    if (is.character(savePath)) {
      jpeg(filename = paste0 (savePath, plotname, ".jpg"), 900, 500)
    }
    plot(envelope$time, envelope$value, type = 'l', col = 'green',
         xlab = 'Time, ms', ylab = 'Amplitude', main = plotname, ...)
    points (bursts, col = 'red', cex = 3, pch = 8)
    for (s in 1:nrow(syllables)) {
      segments( x0 = syllables$start[s], y0 = threshold,
                x1 = syllables$end[s], y1 = threshold,
                lwd = 2, col = 'blue')
    }
    if (!is.na(savePath)){
      dev.off()
    }
  }

  if (summary) {
    ## prepare a dataframe containing descriptives for syllables and bursts
    result = data.frame(
      nSyl = nrow(syllables),
      sylLen_mean = suppressWarnings(mean(syllables$sylLen)),
      sylLen_median = ifelse(nrow(syllables) > 0,
                             median(syllables$sylLen),
                             NA),  # otherwise returns NULL
      sylLen_sd = sd(syllables$sylLen),
      pauseLen_mean = suppressWarnings(mean(syllables$pauseLen, na.rm = TRUE)),
      pauseLen_median = ifelse(nrow(syllables) > 1,
                               median(syllables$pauseLen, na.rm = TRUE),
                               NA),  # otherwise returns NULL
      pauseLen_sd = sd(syllables$pauseLen),
      nBursts = nrow(bursts),
      interburst_mean = suppressWarnings(mean(bursts$interburstInt, na.rm = TRUE)),
      interburst_median = ifelse(nrow(bursts) > 0,
                                 median(bursts$interburstInt, na.rm = TRUE),
                                 NA),  # otherwise returns NULL
      interburst_sd = sd(bursts$interburstInt, na.rm = TRUE)
    )
    result[apply(result, c(1, 2), is.nan)] = NA
  } else {
    result = list(syllables = syllables, bursts = bursts)
  }

  return(result)
}


#' Segment all files in a folder
#'
#' Finds syllables and bursts in all .wav files in a folder.
#'
#' This is just a convenient wrapper for \code{\link{segment}} intended for
#' analyzing the syllables and bursts in a large number of audio files at a
#' time. In verbose mode, it also reports ETA every ten iterations. With default
#' settings, running time should be about a second per minute of audio.
#'
#' @param myfolder full path to target folder
#' @inheritParams segment
#' @param verbose,reportEvery if TRUE, reports progress every \code{reportEvery}
#'   files and estimated time left
#' @return If \code{summary} is TRUE, returns a dataframe with one row per audio
#'   file. If \code{summary} is FALSE, returns a list of detailed descriptives.
#' @export
#' @examples
#' \dontrun{
#' # download 260 sounds from Anikin & Persson (2017)
#' # http://cogsci.se/personal/results/
#' # 01_anikin-persson_2016_naturalistics-non-linguistic-vocalizations/260sounds_wav.zip
#' # unzip them into a folder, say '~/Downloads/temp'
#' myfolder = '~/Downloads/temp'  # 260 .wav files live here
#' s = segmentFolder(myfolder, verbose = TRUE)
#'
#' # Check accuracy: import a manual count of syllables (our "key")
#' key = segmentManual  # a vector of 260 integers
#' trial = as.numeric(s$nBursts)
#' cor(key, trial, use = 'pairwise.complete.obs')
#' boxplot(trial ~ as.integer(key), xlab='key')
#' abline(a=0, b=1, col='red')
#' }
segmentFolder = function (myfolder,
                          shortestSyl = 40,
                          shortestPause = 40,
                          sylThres = 0.9,
                          interburst = NULL,
                          interburstMult = 1,
                          burstThres = 0.075,
                          peakToTrough = 3,
                          troughLeft = TRUE,
                          troughRight = FALSE,
                          windowLength = 40,
                          overlap = 80,
                          summary = TRUE,
                          plot = FALSE,
                          savePath = NA,
                          verbose = TRUE,
                          reportEvery = 10,
                          ...) {
  time_start = proc.time()  # timing
  # open all .wav files in folder
  filenames = list.files(myfolder, pattern = "*.wav", full.names = TRUE)
  filesizes = apply(as.matrix(filenames), 1, function(x) file.info(x)$size)
  myPars = mget(names(formals()), sys.frame(sys.nframe()))
  myPars = myPars[names(myPars) != 'myfolder' &  # exclude these two args
                    names(myPars) != 'verbose']
  result = list()

  for (i in 1:length(filenames)) {
    result[[i]] = result[[i]] = do.call(segment, c(filenames[i], myPars))
    if (verbose) {
      if (i %% reportEvery == 0) {
        reportTime(i = i, nIter = length(filenames),
                   time_start = time_start, jobs = filesizes)
      }
    }
  }

  # prepare output
  if (summary == TRUE) {
    output = as.data.frame(t(sapply(result, rbind)))
    output$sound = apply(matrix(1:length(filenames)), 1, function(x) {
      tail(unlist(strsplit(filenames[x], '/')), 1)
    })
    output = output[, c('sound', colnames(output)[1:(ncol(output) - 1)])]
  } else {
    output = result
    names(output) = filenames
  }

  return (output)
}
