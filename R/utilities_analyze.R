### UTILITIES FOR ACOUSTIC ANALYSIS ###

#' Analyze fft frame
#'
#' Internal soundgen function.
#'
#' This function performs the heavy lifting of pitch tracking and acoustic
#' analysis in general: it takes the spectrum of a single fft frame as input and
#' analyzes it.
#' @param frame the real part of the spectrum of a frame, as returned by
#'   \code{\link[stats]{fft}}
#' @param autoCorrelation pre-calculated autocorrelation of the input frame
#'   (computationally more efficient than to do it here)
#' @param samplingRate sampling rate (Hz)
#' @param trackPitch if TRUE, attempt to find F0 in this frame (FALSE if entropy
#'   is above some threshold - specified in \code{\link{analyze}})
#' @inheritParams analyze
#' @return Returns a list with two components: $pitch_array contains pitch
#'   candidates for the frame, and $summaries contains other acoustic predictors
#'   like HNR, specSlope, etc.
#' @keywords internal
analyzeFrame = function(frame,
                        autoCorrelation = NULL,
                        samplingRate = 44100,
                        trackPitch = TRUE,
                        pitchMethods = c('autocor', 'cep', 'spec', 'dom'),
                        cutFreq = 6000,
                        domThres = 0.1,
                        domSmooth = 220,
                        autocorThres = 0.75,
                        autocorSmooth = NULL,
                        cepThres = 0.45,
                        cepSmooth = 3,
                        cepZp = 2 ^ 13,
                        specThres = 0.45,
                        specPeak = 0.8,
                        specSinglePeakCert = 0.6,
                        specSmooth = 100,
                        specHNRslope = .1,
                        specMerge = 1,
                        pitchFloor = 75,
                        pitchCeiling = 3500,
                        nCands = 1) {
  ## DESCRIPTIVES
  meanSpec = data.frame('freq' = 1000 * as.numeric(names(frame)),
                        'amp' = frame)
  amplitude = sum(frame)
  peakFreq = meanSpec$freq[which.max(frame)] # absolute peak
  meanFreq = meanSpec$freq[min(which(cumsum(frame) > amplitude / 2))] # center of mass

  # Cut spectral band from pitchFloor to cutFreq Hz
  meanSpec_cut = meanSpec[meanSpec$freq > pitchFloor &
                            meanSpec$freq < cutFreq,] # Above 5-6 kHz or so,
  # spectral energy depends too much on the original sampling rate, noises etc.
  # Besides, those frequencies are not super relevant to human vocalizations in
  # any case. So we cut away all info above 5 kHz before we calculate quartiles
  # of spectral energy
  peakFreqCut = meanSpec_cut$freq[which.max(frame)] # peakFreq under cutFreq
  amplitude_cut = sum(meanSpec_cut$amp)
  # first quartile of spectral energy distribution in the band from pitchFloor
  # to cutFreq kHz
  cum_cut = cumsum(meanSpec_cut$amp)
  quartile25 = meanSpec_cut$freq[min(which(cum_cut >= 0.25 * amplitude_cut))]
  # second quartile (same as mean freq within this spectral band)
  quartile50 = meanSpec_cut$freq[min(which(cum_cut >= 0.5 * amplitude_cut))]
  # third quartile. Note: half the energy in the band from pitchFloor to
  # cutFreq kHz lies between quartile25 and quartile75
  quartile75 = meanSpec_cut$freq[min(which(cum_cut >= 0.75 * amplitude_cut))]
  specSlope = summary(lm(amp ~ freq, data = meanSpec_cut))$coef[2, 1]

  ## PITCH TRACKING
  frame = frame / max(frame) # plot (frame, type='l')
  bin = samplingRate / 2 / length(frame) # the width of one bin in spectrogram,
  # in Hz (~20 Hz for 44100 Hz with 50 ms window and zp = 0)

  # lowest dominant frequency band
  if (trackPitch && 'dom' %in% pitchMethods) {
    d = getDom(frame = frame,
               samplingRate = samplingRate,
               bin = bin,
               domSmooth = domSmooth,
               domThres = domThres,
               pitchFloor = pitchFloor
    )
    pitch_array = d$dom_array
    dom = d$dom
  } else {
    pitch_array = data.frame(
      'pitchCand' = numeric(),
      'pitchAmpl' = numeric(),
      'source' = character(),
      stringsAsFactors = FALSE,
      row.names = NULL
    )    # initialize an empty dataframe
    dom = NA
  }

  # autocorrelation (PRAAT)
  if (trackPitch && 'autocor' %in% pitchMethods) {
    pa = getPitchAutocor(autoCorrelation = autoCorrelation,
                         autocorThres = autocorThres,
                         autocorSmooth = autocorSmooth,
                         pitchFloor = pitchFloor,
                         pitchCeiling = pitchCeiling,
                         samplingRate = samplingRate,
                         nCands = nCands)
    if(!is.null(pa$pitchAutocor_array)) {
      pitch_array = rbind(pitch_array, pa$pitchAutocor_array)
    }
    HNR = pa$HNR
  } else {
    HNR = NA
  }

  # cepstrum
  if (trackPitch && 'cep' %in% pitchMethods) {
    pitchCep_array = getPitchCep(frame = frame,
                                 cepZp = cepZp,
                                 samplingRate = samplingRate,
                                 pitchFloor = pitchFloor,
                                 pitchCeiling = pitchCeiling,
                                 cepThres = cepThres,
                                 cepSmooth = cepSmooth,
                                 nCands = nCands)
    if(!is.null(pitchCep_array)) pitch_array = rbind(pitch_array, pitchCep_array)
  }

  # spectral: ratios of harmonics (BaNa)
  if (trackPitch && 'spec' %in% pitchMethods) {
    pitchSpec_array = getPitchSpec(frame = frame,
                                   specSmooth = specSmooth,
                                   specHNRslope = specHNRslope,
                                   bin = bin,
                                   HNR = NULL,
                                   specThres = specThres,
                                   specPeak = specPeak,
                                   specSinglePeakCert = specSinglePeakCert,
                                   pitchFloor = pitchFloor,
                                   pitchCeiling = pitchCeiling,
                                   specMerge = specMerge,
                                   nCands = nCands
    )
    if(!is.null(pitchSpec_array)) pitch_array = rbind(pitch_array, pitchSpec_array)
  }

  # some adjustments of pitch candidates
  if (nrow(pitch_array) > 0) {
    pitch_array[, 1:2] = apply(pitch_array[, 1:2], 2, function(x) as.numeric(x))
    # otherwise they become characters after rbind
  }
  if (nrow(pitch_array[pitch_array$source == 'dom', ]) > 0 & !is.na(HNR)) {
    pitch_array$pitchAmpl[pitch_array$source == 'dom'] =
      1 / (1 + exp(3 * HNR - 1)) # dom is worth more for noisy sounds,
    # but its weight approaches ~0.2 as HNR approaches 1
    # (NB: this is before HNR is converted to dB). Visualization:
    # a = seq(0, 1, length.out = 100)
    # b = 1 / (1 + exp(3 * a - 1))
    # plot (a, b, ylim = c(0, 1))
  }

  return (list(
    'pitch_array' = pitch_array,
    'summaries' = data.frame(
      HNR = HNR,
      dom = dom,
      peakFreq = peakFreq,
      peakFreqCut = peakFreqCut,
      meanFreq = meanFreq,
      quartile25 = quartile25,
      quartile50 = quartile50,
      quartile75 = quartile75,
      specSlope = specSlope
    )
  ))
}


#' Get lowest dominant frequency band
#'
#' Internal soundgen function.
#'
#' Calculate the lowest frequency band in the spectrum above pitchFloor whose
#' power exceeds a certain threshold.
#' @inheritParams analyzeFrame
#' @inheritParams analyze
#' @param bin the width of one bin in spectrogram, Hz
#' @return Returns a list of $dom (NA or numeric) and $dom_array
#'   (either NULL or a dataframe of pitch candidates).
#' @keywords internal
getDom = function(frame,
                  samplingRate,
                  bin,
                  domSmooth,
                  domThres,
                  pitchFloor
) {
  dom_array = data.frame(
    'pitchCand' = numeric(),
    'pitchAmpl' = numeric(),
    'source' = character(),
    stringsAsFactors = FALSE,
    row.names = NULL
  )
  dom = NA
  # width of smoothing interval (in bins), forced to be an odd number
  domSmooth_bins = 2 * ceiling(domSmooth / bin / 2) - 1

  # find peaks in the smoothed spectrum
  temp = zoo::rollapply(zoo::as.zoo(frame),
                        width = domSmooth_bins,
                        align = 'center',
                        function(x) {
                          isCentral.localMax(x, threshold = domThres)
                        })
  idx = zoo::index(temp)[zoo::coredata(temp)]
  pitchFloor_idx = which(as.numeric(names(frame)) > pitchFloor / 1000)[1]
  idx = idx[idx > pitchFloor_idx]

  if (length(idx) > 0) {
    # lowest dominant freq band - we take the first frequency in the spectrum at
    # least /domThres/ % of the amplitude of peak frequency, but high
    # enough to be above pitchFloor
    dom = as.numeric(names(frame)[idx[1]]) * 1000
    dom_array = data.frame(
      'pitchCand' = dom,
      'pitchAmpl' = frame[idx[1]],
      'source' = 'dom',
      stringsAsFactors = FALSE,
      row.names = NULL
    )
  }
  return (list(dom_array = dom_array, dom = dom))
}


#' Autocorrelation pitch tracker
#'
#' Internal soundgen function.
#'
#' Attempts to find F0 of a frame by looking for peaks in the autocorrelation
#' function (time domain analysis). Modified PRAAT's algorithm. See Boersma, P.
#' (1993). Accurate short-term analysis of the fundamental frequency and the
#' harmonics-to-noise ratio of a sampled sound. In Proceedings of the institute
#' of phonetic sciences (Vol. 17, No. 1193, pp. 97-110).
#' @inheritParams analyzeFrame
#' @inheritParams analyze
#' @return Returns a list of $HNR (NA or numeric) and $pitchAutocor_array
#'   (either NULL or a dataframe of pitch candidates).
#' @keywords internal
getPitchAutocor = function(autoCorrelation,
                           autocorSmooth = NULL,
                           autocorThres,
                           pitchFloor,
                           pitchCeiling,
                           samplingRate,
                           nCands) {
  # autoCorrelation = autocorBank[, 13]
  pitchAutocor_array = NULL
  a = data.frame ('freq' = as.numeric(names(autoCorrelation)),
                  'amp' = autoCorrelation)
  rownames(a) = NULL
  a = a[a$freq > pitchFloor &
          a$freq < pitchCeiling, , drop = FALSE] # plot(a[,2], type='l')
  HNR = max(a$amp) # HNR is here defined as the maximum autocorrelation
  # within the specified pitch range. It is also measured for the frames which
  # are later classified as unvoiced (i.e. HNR can be <voicedThres)
  if (!is.numeric(autocorSmooth)) {
    autocorSmooth = 2 * ceiling(7 * samplingRate / 44100 / 2) - 1
    # width of smoothing interval, chosen to be proportionate to samplingRate (7
    # for samplingRate 44100), but always an odd number.
    # for(i in seq(16000, 60000, length.out = 10)) {
    #   print(paste(round(i), ':', 2 * ceiling(7 * i / 44100 / 2) - 1))
    # }
  }

  # find peaks in the corrected autocorrelation function
  a_zoo = zoo::as.zoo(a$amp)
  temp = zoo::rollapply(a_zoo,
                        width = autocorSmooth,
                        align = 'center',
                        function(x) {
                          isCentral.localMax(x, threshold = autocorThres)
                          # width = 7 chosen by optimization, but it doesn't make that much difference anyhow
                        })
  idx = zoo::index(temp)[zoo::coredata(temp)]
  autocorPeaks = a[idx, ]

  if (nrow(autocorPeaks) > 0) {
    # if some peaks are found...
    # we are only interested in frequencies above half of the best candidate
    # (b/c otherwise we get false subharmonics)
    bestFreq = autocorPeaks$freq[which(autocorPeaks$amp >
                                         0.975 * max(autocorPeaks$amp))[1]]
    # bestFreq = autocorPeaks$freq[which.max(autocorPeaks$amp)]
    if (!is.na(bestFreq)) {
      autocorPeaks = try(autocorPeaks[autocorPeaks$freq > bestFreq / 1.8,
                                      , drop = FALSE], silent = TRUE)
      # otherwise we get false subharmonics
      autocorPeaks = try(autocorPeaks[order(autocorPeaks$amp, decreasing = TRUE),
                                      , drop = FALSE], silent = TRUE)
    }
    if (class(autocorPeaks) != 'try-error') {
      if (nrow(autocorPeaks) > 0) {
        # if some peaks satisfy all criteria, return them:
        pitchAutocor_array = data.frame (
          'pitchCand' = autocorPeaks [1:min(nrow(autocorPeaks), nCands), 1],
          # save n candidates of pitchAutocor, convert to Hz
          'pitchAmpl' = autocorPeaks[1:min(nrow(autocorPeaks), nCands), 2],
          # save amplitudes corresponding to each pitchAutocor candidate
          'source' = 'autocor',
          stringsAsFactors = FALSE,
          row.names = NULL
        )
      }
    }
  }
  # very occasionally HNR can be calculated as 1.01 etc. To prevent this nonsense:
  if (!is.na(HNR) & HNR >= 1) {
    HNR = 0.9999
  } # analogous to 40 dB

  return(list(pitchAutocor_array = pitchAutocor_array,
              HNR = HNR))
}


#' Cepstral pitch tracker
#'
#' Internal soundgen function.
#'
#' Attempts to find F0 of a frame by looking for peaks in the cepstrum.
#' See http://www.phon.ucl.ac.uk/courses/spsci/matlab/lect10.html
#' @inheritParams analyzeFrame
#' @inheritParams analyze
#' @return Returns either NULL or a dataframe of pitch candidates.
#' @keywords internal
getPitchCep = function(frame,
                       cepZp,
                       samplingRate,
                       pitchFloor,
                       pitchCeiling,
                       cepThres,
                       cepSmooth = NULL,
                       nCands) {
  pitchCep_array = NULL
  if (!is.numeric(cepSmooth)) {
    cepSmooth = 2 * ceiling(31 * samplingRate / 44100 / 2) - 1
  }

  if (cepZp < length(frame)) {
    frameZP = frame
  } else {
    zp = rep(0, (cepZp - length(frame)) / 2)
    frameZP = c(zp, frame, zp)
    cepSmooth = cepSmooth * round(cepZp / length(frame))
  }

  # fft of fft, whatever you call it - cepstrum or smth else
  cepstrum = abs(fft(frameZP)) # plot(frameZP, type = 'l')
  cepstrum = cepstrum / max(cepstrum) # plot (cepstrum, type = 'l')
  l = length(cepstrum) %/% 2
  b = data.frame(
    # NB: divide by 2 because it's another fft, not inverse fft (cf. pitchAutocor)
    freq = samplingRate / (1:l) / 2 * (length(frameZP) / length(frame)),
    cep = cepstrum[1:l]
  )
  b = b[b$freq > pitchFloor & b$freq < pitchCeiling, ]
  # plot(b, type = 'l')

  # find peaks
  a_zoo = zoo::as.zoo(b$cep)
  temp = zoo::rollapply(a_zoo,
                        width = cepSmooth,
                        align = 'center',
                        function(x)
                          isCentral.localMax(x, threshold = cepThres))
  idx = zoo::index(temp)[zoo::coredata(temp)]

  absCepPeak = try(idx[which.max(b$cep[idx])], silent = TRUE)
  if (class(absCepPeak) != 'try-error') {
    idx = idx[b$freq[idx] > b$freq[absCepPeak] / 1.8]
  } # to avoid false subharmonics
  # plot (b, type = 'l')
  # points(b$freq[idx], b$cep[idx])
  idx = idx[order(b$cep[idx], decreasing = TRUE)]
  acceptedCepPeaks = idx[1:min(length(idx), nCands)]

  if (length(acceptedCepPeaks) > 0) {
    # if some peaks are found...
    pitchCep_array = data.frame(
      'pitchCand' = b$freq[acceptedCepPeaks],
      'pitchAmpl' = b$cep[acceptedCepPeaks],
      'source' = 'cep',
      stringsAsFactors = FALSE,
      row.names = NULL
    )
    # because cepstrum really stinks for frequencies above ~1 kHz, mostly
    # picking up formants or just plain noise, we discount confidence in
    # high-pitch cepstral estimates
    pitchCep_array$pitchAmpl = pitchCep_array$pitchAmpl /
      (1 + 5 / (1 + exp(2 - .25 * HzToSemitones(pitchCep_array$pitchCand / pitchFloor))))
    # visualization: a = seq(pitchFloor, pitchCeiling, length.out = 100)
    # b = 1 + 5 / (1 + exp(2 - .25 * HzToSemitones(a / pitchFloor)))
    # plot (a, b, type = 'l')
  }
  return (pitchCep_array)
}


#' BaNa pitch tracker
#'
#' Internal soundgen function.
#'
#' Attempts to find F0 of a frame by calculating ratios of putative harmonics
#' (frequency domain analysis, ~ modified BaNa algorithm). See Ba et al. (2012)
#' "BaNa: A hybrid approach for noise resilient pitch detection." Statistical
#' Signal Processing Workshop (SSP), 2012 IEEE.
#' @inheritParams analyzeFrame
#' @inheritParams analyze
#' @param bin the width of spectral bin in \code{frame}, Hz
#' @param HNR harmonics-to-noise ratio returned by \code{\link{getPitchAutocor}}
#' @return Returns either NULL or a dataframe of pitch candidates.
#' @keywords internal
getPitchSpec = function(frame,
                        specSmooth,
                        specHNRslope,
                        bin,
                        HNR = NULL,
                        specThres,
                        specPeak,
                        specSinglePeakCert,
                        pitchFloor,
                        pitchCeiling,
                        specMerge,
                        nCands
) {
  pitchSpec_array = NULL
  width = 2 * ceiling((specSmooth / bin + 1) * 20 / bin / 2) - 1 # to be always ~100 Hz,
  # regardless of bin, but an odd number
  if (!is.numeric(HNR)) {
    specPitchThreshold = specPeak # if HNR is NA, the sound is
    # probably a mess, so we play safe by only looking at very strong harmonics
  } else {
    # for noisy sounds the threshold is high to avoid false sumharmonics etc,
    # for tonal sounds it is low to catch weak harmonics
    specPitchThreshold = specPeak * (1 - HNR * specHNRslope)
  }

  # find peaks in the spectrum (hopefully harmonics)
  temp = zoo::rollapply(zoo::as.zoo(frame),
                        width = width,
                        align = 'center',
                        function(x) {
                          isCentral.localMax(x, threshold = specPitchThreshold)
                          # plot(zoo::as.zoo(frame), type='l')
                        })
  idx = zoo::index(temp)[zoo::coredata(temp)]
  specPeaks = data.frame ('freq' = as.numeric(names(frame)[idx]) * 1000,
                          'amp' = frame[idx])

  if (nrow(specPeaks) == 1) {
    if (specPeaks[1, 1] < pitchCeiling & specPeaks[1, 1] > pitchFloor) {
      pitchSpec = specPeaks[1, 1]
      pitchAmpl = specSinglePeakCert
      pitchSpec_array = data.frame(
        'pitchCand' = pitchSpec,
        'pitchAmpl' = specSinglePeakCert,
        'source' = 'spec',
        stringsAsFactors = FALSE,
        row.names = NULL
      )
    }
  } else if (nrow(specPeaks) > 1) {
    # analyze five lowest harmonics
    specPeaks = specPeaks [1:min(5, nrow(specPeaks)), ]

    # A modified version of BaNa algorithm follows
    seq1 = 2:nrow(specPeaks)
    seq2 = 1:(nrow(specPeaks) - 1)
    n = length(seq1) * length(seq2)
    temp = data.frame (
      'harmonicA' = rep(0, n),
      'harmonicB' = rep(0, n),
      'AtoB_ratio' = rep(0, n)
    )
    counter = 1
    for (i in seq1) {
      for (j in seq2) {
        temp$harmonicA[counter] = i
        temp$harmonicB[counter] = j
        # get ratios of discovered harmonics to each other
        temp$AtoB_ratio[counter] = specPeaks$freq[i] / specPeaks$freq[j]
        counter = counter + 1
      }
    }
    temp = temp[temp$harmonicA > temp$harmonicB, ]

    pitchCand = numeric()
    for (i in 1:nrow(temp)) {
      # for each ratio that falls within the limits specified outside this
      # function in a dataframe called "ratios", calculate the corresponding
      # pitch. If several ratios suggest the same pitch, that's our best guess
      divLow = BaNaRatios$divide_lower_by[temp$AtoB_ratio[i] > BaNaRatios$value_low &
                                            temp$AtoB_ratio[i] < BaNaRatios$value_high]
      pitchCand = c(pitchCand,
                    as.numeric(specPeaks$freq[temp$harmonicB[i]] / divLow))
    }
    # add pitchCand based on the most common distances between harmonics
    # pitchCand = c(pitchCand, diff(specPeaks[,1]))

    pitchCand = sort (pitchCand [pitchCand > pitchFloor &
                                   pitchCand < pitchCeiling])
    if (length(pitchCand) > 0) {
      pitchSpec_array = data.frame(
        'pitchCand' = pitchCand,
        'specAmplIdx' = 1,
        'source' = 'spec',
        stringsAsFactors = FALSE,
        row.names = NULL
      )
      c = 1
      while (c + 1 <= nrow(pitchSpec_array)) {
        if (abs(log2(pitchSpec_array$pitchCand[c] /
                     pitchSpec_array$pitchCand[c + 1])) < specMerge / 12) {
          # merge cands within specMerge into one "super-candidate"
          # and give this new super-candidate a certainty boost
          pitchSpec_array$specAmplIdx[c] = pitchSpec_array$specAmplIdx[c] + 1
          pitchSpec_array$pitchCand[c] = mean(c(
            pitchSpec_array$pitchCand[c],
            pitchSpec_array$pitchCand[c + 1]
          ))
          pitchSpec_array = pitchSpec_array[-(c + 1), ]
        } else {
          c = c + 1
        }
      }
      pitchSpec_array$pitchAmpl = specSinglePeakCert +
        (1 / (1 + exp(-(pitchSpec_array$specAmplIdx - 1))) - 0.5) * 2 *
        (1 - specSinglePeakCert) # normalization. Visualization:
      # a = 1:15
      # b = specSinglePeakCert + (1 / (1 + exp(-(a - 1))) - 0.5) * 2 *
      # (1 - specSinglePeakCert)
      # plot(a, b, type = 'l')
      pitchSpec_array = pitchSpec_array[
        order(pitchSpec_array$pitchAmpl, decreasing = TRUE),
        c('pitchCand', 'pitchAmpl', 'source')
        ]
    }
  }
  if (!is.null(pitchSpec_array) && sum(!is.na(pitchSpec_array)) > 0) {
    pitchSpec_array = pitchSpec_array[pitchSpec_array$pitchAmpl > specThres,
                                      , drop = FALSE]
    # how many pitchSpec candidates to use (max)
    pitchSpec_array = pitchSpec_array[1:min(nrow(pitchSpec_array), nCands), ]
  }

  return(pitchSpec_array)
}
