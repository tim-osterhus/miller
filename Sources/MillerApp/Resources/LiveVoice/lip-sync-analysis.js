(() => {
  const VOWEL_NAMES = Object.freeze(["aa", "ih", "ou", "ee", "oh"]);
  const FORMANTS = Object.freeze([
    ["aa", 800, 1150],
    ["ou", 350, 800],
    ["oh", 500, 1000],
    ["ee", 500, 1900],
    ["ih", 300, 2500],
  ]);

  function closedResult() {
    return {
      scalar: 0,
      vowels: {
        aa: 0,
        ih: 0,
        ou: 0,
        ee: 0,
        oh: 0,
      },
    };
  }

  function numericSequence(value) {
    if (Array.isArray(value)) return value;
    if (ArrayBuffer.isView(value) && !(value instanceof DataView)) return value;
    return null;
  }

  function finitePositive(value) {
    return Number.isFinite(value) && value > 0 ? value : 0;
  }

  function finiteNumber(value) {
    return typeof value === "number" && Number.isFinite(value) ? value : 0;
  }

  function clamp(value, lower, upper) {
    return Math.min(upper, Math.max(lower, value));
  }

  function mouthOpenAmount(timeDomain) {
    const values = numericSequence(timeDomain);
    if (!values || values.length === 0) return 0;

    let peak = 0;
    for (let index = 0; index < values.length; index += 1) {
      const sample = finiteNumber(values[index]);
      peak = Math.max(peak, Math.abs(sample));
    }

    let amount = 1 / (1 + Math.exp(-45 * peak + 5));
    if (amount < 0.1) amount = 0;
    return clamp(amount * 0.75, 0, 1);
  }

  function bandEnergy(frequencyData, sampleRate, fftSize, fromHz, toHz) {
    const values = numericSequence(frequencyData);
    if (!values || values.length === 0 || !(sampleRate > 0) || !(fftSize > 0)) {
      return 0;
    }

    const hzPerBin = sampleRate / fftSize;
    if (!(hzPerBin > 0) || !Number.isFinite(hzPerBin)) return 0;

    let energy = 0;
    let count = 0;
    for (let index = 0; index < values.length; index += 1) {
      const hz = index * hzPerBin;
      if (hz < fromHz || hz >= toHz) continue;

      const rawMagnitude = finiteNumber(values[index]) / 255;
      const magnitude = clamp(rawMagnitude, 0, 1);
      energy += magnitude * magnitude;
      count += 1;
    }
    return count > 0 ? Math.sqrt(energy / count) : 0;
  }

  function classify(timeDomain, frequencyData, sampleRate = 48000, fftSize) {
    const mouthOpen = mouthOpenAmount(timeDomain);
    if (!(mouthOpen > 0)) return closedResult();

    const values = numericSequence(timeDomain);
    const spectrum = numericSequence(frequencyData);
    const resolvedSampleRate = finitePositive(sampleRate);
    const resolvedFFTSize = finitePositive(
      fftSize ?? values?.length ?? (spectrum?.length ? spectrum.length * 2 : 2048),
    );
    if (!spectrum || !(resolvedSampleRate > 0) || !(resolvedFFTSize > 0)) {
      return closedResult();
    }

    let dominant = null;
    let dominantScore = 0;
    let runnerUpScore = 0;
    for (const [name, firstFormant, secondFormant] of FORMANTS) {
      const firstEnergy = bandEnergy(
        spectrum,
        resolvedSampleRate,
        resolvedFFTSize,
        firstFormant - 140,
        firstFormant + 140,
      );
      const secondEnergy = bandEnergy(
        spectrum,
        resolvedSampleRate,
        resolvedFFTSize,
        secondFormant - 220,
        secondFormant + 220,
      );
      const score = Math.sqrt(firstEnergy * secondEnergy)
        + 0.125 * (firstEnergy + secondEnergy);
      if (score > dominantScore) {
        runnerUpScore = dominantScore;
        dominant = name;
        dominantScore = score;
      } else if (score > runnerUpScore) {
        runnerUpScore = score;
      }
    }

    if (!dominant || !(dominantScore > 0)
        || dominantScore < runnerUpScore * 1.1) {
      return closedResult();
    }

    const vowels = closedResult().vowels;
    vowels[dominant] = mouthOpen;
    return {
      scalar: mouthOpen,
      vowels: VOWEL_NAMES.reduce((result, name) => {
        result[name] = clamp(Number(vowels[name]), 0, 1);
        return result;
      }, {}),
    };
  }

  globalThis.millerLipSyncAnalysis = Object.freeze({ classify });
})();
