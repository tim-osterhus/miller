import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";
import test from "node:test";

const resourcePath = new URL(
  "../../Sources/MillerApp/Resources/LiveVoice/lip-sync-analysis.js",
  import.meta.url,
);

function loadAnalysis() {
  const context = createContext({});
  runInContext(readFileSync(resourcePath, "utf8"), context, {
    filename: resourcePath.pathname,
  });
  return context.millerLipSyncAnalysis;
}

const SAMPLE_RATE = 8000;
const FFT_SIZE = 256;

function voicedSamples(amplitude = 0.16) {
  return Float32Array.from({ length: FFT_SIZE }, (_, index) =>
    index % 2 === 0 ? amplitude : -amplitude,
  );
}

function spectrum(fromHz, toHz, magnitude = 220) {
  const values = new Uint8Array(FFT_SIZE / 2);
  const hzPerBin = SAMPLE_RATE / FFT_SIZE;
  for (let index = 0; index < values.length; index += 1) {
    const hz = index * hzPerBin;
    if (hz >= fromHz && hz < toHz) values[index] = magnitude;
  }
  return values;
}

function formantSpectrum(formants, magnitude = 220, noiseFloor = 0) {
  const values = new Uint8Array(FFT_SIZE / 2).fill(noiseFloor);
  const hzPerBin = SAMPLE_RATE / FFT_SIZE;
  for (const formant of formants) {
    const center = Math.round(formant / hzPerBin);
    for (let offset = -2; offset <= 2; offset += 1) {
      const index = center + offset;
      if (index >= 0 && index < values.length) {
        values[index] = Math.max(values[index], magnitude - Math.abs(offset) * 25);
      }
    }
  }
  return values;
}

function analyze(analysis, frequencyData, timeDomain = voicedSamples()) {
  return analysis.classify(timeDomain, frequencyData, SAMPLE_RATE, FFT_SIZE);
}

function closedResult() {
  return {
    scalar: 0,
    vowels: { aa: 0, ih: 0, ou: 0, ee: 0, oh: 0 },
  };
}

function assertClosed(result) {
  assert.deepEqual(JSON.parse(JSON.stringify(result)), closedResult());
}

test("lip sync analysis exposes a frozen global classifier", () => {
  const analysis = loadAnalysis();

  assert.ok(analysis);
  assert.equal(Object.isFrozen(analysis), true);
  assert.deepEqual(Object.keys(analysis), ["classify"]);
  assert.equal(typeof analysis.classify, "function");
});

test("silence closes scalar and every vowel", () => {
  const result = analyze(loadAnalysis(), spectrum(500, 1800), new Float32Array(FFT_SIZE));
  assertClosed(result);
});

test("unusable input does not invent mouth movement", () => {
  const analysis = loadAnalysis();

  assertClosed(analyze(analysis, new Uint8Array(FFT_SIZE / 2)));
  assertClosed(analysis.classify(null, null, NaN, 0));
  assertClosed(analysis.classify("not audio", {}, -1, -1));
  assert.doesNotThrow(() => {
    assertClosed(analysis.classify(
      [Symbol("invalid"), {}, Infinity],
      [Symbol("invalid"), {}, NaN],
      SAMPLE_RATE,
      FFT_SIZE,
    ));
  });
});

test("coercible malformed samples stay closed without invoking valueOf", () => {
  const analysis = loadAnalysis();
  const formants = formantSpectrum([800, 1150]);

  for (const malformed of ["0.16", true, new Number(0.16)]) {
    assertClosed(analyze(analysis, formants, [malformed]));
  }

  let valueOfCalls = 0;
  const valueOfHook = {
    valueOf() {
      valueOfCalls += 1;
      return 0.16;
    },
  };

  assertClosed(analyze(analysis, formants, [valueOfHook]));
  assert.equal(valueOfCalls, 0);
});

test("recognizable formants select each distinct dominant vowel", () => {
  const analysis = loadAnalysis();
  const fixtures = {
    aa: [800, 1150],
    ih: [300, 2500],
    ou: [350, 800],
    ee: [500, 1900],
    oh: [500, 1000],
  };

  for (const [expected, formants] of Object.entries(fixtures)) {
    const result = analyze(analysis, formantSpectrum(formants));
    const dominant = Object.entries(result.vowels).reduce((best, entry) =>
      entry[1] > best[1] ? entry : best,
    );
    const visiblyActive = Object.values(result.vowels).filter((value) => value > 0.001);

    assert.equal(dominant[0], expected, `${expected} should be dominant`);
    assert.equal(visiblyActive.length, 1, `${expected} should not blend every mouth shape`);
    assert.ok(result.scalar > 0 && result.scalar <= 1);
    assert.equal(result.vowels[expected], result.scalar);
  }
});

test("ambiguous broadband input stays closed", () => {
  const result = analyze(loadAnalysis(), new Uint8Array(FFT_SIZE / 2).fill(90));
  assertClosed(result);
});

test("vowel weights are finite, bounded, and complete", () => {
  const result = analyze(
    loadAnalysis(),
    Uint8Array.from({ length: FFT_SIZE / 2 }, (_, index) => (index * 37) % 256),
  );

  assert.deepEqual(Object.keys(result.vowels), ["aa", "ih", "ou", "ee", "oh"]);
  assert.ok(Number.isFinite(result.scalar));
  assert.ok(result.scalar >= 0 && result.scalar <= 1);
  assert.ok(Object.values(result.vowels).every((value) => Number.isFinite(value)));
  assert.ok(Object.values(result.vowels).every((value) => value >= 0 && value <= 1));
});

test("formant selection survives a nonzero spectral floor", () => {
  const analysis = loadAnalysis();
  const fixtures = {
    aa: [800, 1150],
    ih: [300, 2500],
    ou: [350, 800],
    ee: [500, 1900],
    oh: [500, 1000],
  };

  for (const [expected, formants] of Object.entries(fixtures)) {
    const result = analyze(analysis, formantSpectrum(formants, 220, 30));
    const dominant = Object.entries(result.vowels).reduce((best, entry) =>
      entry[1] > best[1] ? entry : best,
    );
    assert.equal(dominant[0], expected, `${expected} should survive the noise floor`);
  }
});
