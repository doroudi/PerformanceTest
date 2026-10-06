/*
 * LOAD SHAPES, so a scenario can be run as a steady flow, a ramp, a stepped stress test or a
 * spike without a second copy of the scenario.
 *
 * Why this is shared rather than written into each scenario file: the profiles are the same
 * question every time ("how is load offered over time?"), and the journey had none of them -
 * it could only run a flat VU count, so "where does this flow break?" was unanswerable with
 * the one scenario whose whole point is the flow. Keeping the shapes in one file also means
 * the knob NAMES stay the same across test types: STEP_VUS means what it means in
 * stress-test.js, HOLD_DURATION means what it means in load-test.js.
 *
 * Deliberately free of k6 globals so it can be unit-tested outside k6 - see
 * k6/tests/profiles.test.mjs. The caller reads the environment and passes plain values in.
 */

export const PROFILES = ["steady", "load", "stress", "spike", "rate", "rate-ramp"];

/*
 * Which profiles offer load INDEPENDENTLY of how fast the target answers - the "open model".
 *
 * This distinction decides whether a run can challenge a server at all. In a VU-based profile
 * each virtual user waits for its own response before sending the next request, so a target
 * that slows down receives LESS load: the test backs off precisely when you want to see it
 * buckle. An arrival-rate profile emits a fixed number of requests per second whatever
 * happens, so if the target cannot keep up the requests queue and latency rises - which is
 * the measurement you wanted.
 */
export const OPEN_MODEL_PROFILES = ["rate", "rate-ramp"];

// A stress test with fewer than two plateaus cannot show a knee: one step is a load test.
const MINIMUM_STRESS_STEPS = 2;

function positive(value, fallback) {
  const parsed = Number(value);
  return isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function duration(value, fallback) {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : fallback;
}

/*
 * Build the k6 load options for one profile.
 *
 * Returns { options, summary, steady, openModel } where options is the fragment to spread
 * into `export const options` - the `vus`/`duration` shortcut, `stages`, or `scenarios` for
 * an arrival-rate executor - and summary is a sentence for the run log, because a finished run
 * should say which shape produced it.
 *
 * Throws on an unknown profile, listing the real ones: a typo'd JOURNEY_PROFILE would
 * otherwise silently run the default and be filed as a stress result.
 */
export function buildProfile(name, settings) {
  const requested = typeof name === "string" && name.trim() !== "" ? name.trim().toLowerCase() : "steady";
  const input = settings || {};

  const vus = positive(input.vus, 5);
  const baseDuration = duration(input.duration, "1m");

  if (PROFILES.indexOf(requested) === -1) {
    throw new Error(
      "Unknown load profile '" + requested + "'. Use one of: " + PROFILES.join(", ") +
        ".\nSet it with JOURNEY_PROFILE (the journey scenario), or pick the matching test type."
    );
  }

  if (requested === "steady") {
    return {
      steady: true,
      options: { vus: vus, duration: baseDuration },
      summary: vus + " VU(s) for " + baseDuration + ", constant (closed model: offered load falls when the target slows down)",
    };
  }

  if (requested === "load") {
    const rampDuration = duration(input.rampDuration, "1m");
    const holdDuration = duration(input.holdDuration, "5m");

    return {
      steady: false,
      options: {
        stages: [
          { duration: rampDuration, target: vus },
          { duration: holdDuration, target: vus },
          { duration: rampDuration, target: 0 },
        ],
      },
      summary: "ramp to " + vus + " VU(s) over " + rampDuration + ", hold for " + holdDuration + ", ramp down",
    };
  }

  if (requested === "stress") {
    const stepVus = positive(input.stepVus, 10);
    const stepCount = Math.max(MINIMUM_STRESS_STEPS, Math.round(positive(input.stepCount, 4)));
    const stepDuration = duration(input.stepDuration, "1m");

    const stages = [];
    for (let step = 1; step <= stepCount; step += 1) {
      stages.push({ duration: stepDuration, target: stepVus * step });
    }
    // A final plateau at zero, so the run shows whether the system RECOVERS - which is half
    // of what "does it degrade gracefully" means.
    stages.push({ duration: stepDuration, target: 0 });

    return {
      steady: false,
      options: { stages: stages },
      summary:
        stepCount + " plateau(s) of " + stepVus + " VUs added each " + stepDuration +
        " (peak " + stepVus * stepCount + " VUs), then a plateau at 0",
    };
  }

  if (requested === "rate" || requested === "rate-ramp") {
    const targetRps = positive(input.targetRps, 100);
    const preAllocatedVus = positive(input.preAllocatedVus, 50);
    // maxVUs must be at least preAllocatedVUs or k6 refuses to start the scenario.
    const maxVus = Math.max(preAllocatedVus, positive(input.maxVus, 400));
    const scenarioName = typeof input.scenarioName === "string" && input.scenarioName !== "" ? input.scenarioName : "default";

    if (requested === "rate") {
      return {
        steady: false,
        options: {
          scenarios: {
            [scenarioName]: {
              executor: "constant-arrival-rate",
              rate: targetRps,
              timeUnit: "1s",
              duration: baseDuration,
              preAllocatedVUs: preAllocatedVus,
              maxVUs: maxVus,
            },
          },
        },
        summary:
          "a FIXED " + targetRps + " iterations/s for " + baseDuration + " (open model: the offered load does not fall when " +
          "the target slows down), up to " + maxVus + " VUs",
      };
    }

    const stepCount = Math.max(MINIMUM_STRESS_STEPS, Math.round(positive(input.rateSteps, 4)));
    const stepDuration = duration(input.stepDuration, "1m");
    const stepRate = Math.max(1, Math.round(targetRps / stepCount));

    const stages = [];
    for (let step = 1; step <= stepCount; step += 1) {
      stages.push({ duration: stepDuration, target: stepRate * step });
    }
    // Back to zero offered load, so the run also shows whether latency recovers.
    stages.push({ duration: stepDuration, target: 0 });

    return {
      steady: false,
      options: {
        scenarios: {
          [scenarioName]: {
            executor: "ramping-arrival-rate",
            startRate: 0,
            timeUnit: "1s",
            stages: stages,
            preAllocatedVUs: preAllocatedVus,
            maxVUs: maxVus,
          },
        },
      },
      summary:
        "a FIXED offered rate rising by " + stepRate + " iterations/s every " + stepDuration + " to " + stepRate * stepCount +
        "/s, then back to 0 (open model), up to " + maxVus + " VUs",
    };
  }

  // spike
  const baselineVus = positive(input.baselineVus, 5);
  const spikeVus = positive(input.spikeVus, 50);
  const baselineDuration = duration(input.baselineDuration, "30s");
  const spikeDuration = duration(input.spikeDuration, "1m");

  return {
    steady: false,
    options: {
      stages: [
        { duration: baselineDuration, target: baselineVus },
        { duration: spikeDuration, target: spikeVus },
        // The recovery window, and the reason a spike test is worth running: how fast the
        // system comes back after the crowd leaves.
        { duration: baselineDuration, target: baselineVus },
      ],
    },
    summary:
      baselineVus + " VU(s) baseline for " + baselineDuration + ", spike to " + spikeVus +
      " for " + spikeDuration + ", back to baseline for " + baselineDuration + " (recovery)",
  };
}
