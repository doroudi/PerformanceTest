/*
 * Sanity checks for k6/scripts/lib/profiles.js, runnable without k6:
 *
 *   node k6/tests/profiles.test.mjs
 *
 * A load profile is the one input that decides what a result MEANS, so the failures worth
 * guarding are not crashes - they are shapes that look plausible and are not what was asked
 * for. Two in particular:
 *
 *   * a stress test that is really a load test, because it grew one plateau instead of
 *     several, and therefore cannot show a knee at all;
 *   * a stress run that still ABORTS on the first failed request, which ends the test exactly
 *     where the interesting part starts.
 */

import assert from "node:assert/strict";

import { OPEN_MODEL_PROFILES, PROFILES, buildProfile } from "../scripts/lib/profiles.js";

const settings = {
  vus: 5,
  duration: "1m",
  stepVus: 10,
  stepCount: 4,
  stepDuration: "30s",
  rampDuration: "20s",
  holdDuration: "2m",
  baselineVus: 5,
  spikeVus: 50,
  baselineDuration: "30s",
  spikeDuration: "1m",
};

// 1. steady is the default shape, and it is unchanged from what the journey always did.
{
  const profile = buildProfile("steady", settings);
  assert.equal(profile.steady, true);
  assert.deepEqual(profile.options, { vus: 5, duration: "1m" });
  assert.ok(!profile.options.stages, "steady must not carry stages");
}

// 2. An absent or empty profile name means steady, not an error: JOURNEY_PROFILE is optional.
assert.equal(buildProfile("", settings).steady, true);
assert.equal(buildProfile(undefined, settings).steady, true);

// 3. A stress run is plateaus that GROW, then a plateau at zero.
{
  const profile = buildProfile("stress", settings);
  assert.equal(profile.steady, false);
  assert.deepEqual(profile.options.stages, [
    { duration: "30s", target: 10 },
    { duration: "30s", target: 20 },
    { duration: "30s", target: 30 },
    { duration: "30s", target: 40 },
    { duration: "30s", target: 0 },
  ]);
  assert.match(profile.summary, /4 plateau\(s\)/);
  assert.match(profile.summary, /peak 40 VUs/);
}

// 4. One plateau cannot show a knee, so a step count below two is raised to two rather than
//    quietly producing a load test with a stress test's name.
{
  const profile = buildProfile("stress", Object.assign({}, settings, { stepCount: 1 }));
  assert.equal(profile.options.stages.length, 3, "two plateaus plus the ramp-down");
  assert.equal(profile.options.stages[0].target, 10);
  assert.equal(profile.options.stages[1].target, 20);
}

// 5. The ramp-down is part of the shape: "does it recover" is half of what a stress test asks.
{
  const stages = buildProfile("stress", settings).options.stages;
  assert.equal(stages[stages.length - 1].target, 0, "the last plateau must be zero");
}

// 6. load ramps, holds, ramps down - in that order.
{
  const profile = buildProfile("load", settings);
  assert.deepEqual(profile.options.stages, [
    { duration: "20s", target: 5 },
    { duration: "2m", target: 5 },
    { duration: "20s", target: 0 },
  ]);
}

// 7. spike returns to the baseline, which is the point of measuring recovery.
{
  const profile = buildProfile("spike", settings);
  assert.deepEqual(profile.options.stages, [
    { duration: "30s", target: 5 },
    { duration: "1m", target: 50 },
    { duration: "30s", target: 5 },
  ]);
  assert.match(profile.summary, /recovery/);
}

// 8. Every profile explains itself for the run log: a finished run should say which shape
//    produced its numbers.
PROFILES.forEach(function (name) {
  const profile = buildProfile(name, settings);
  assert.equal(typeof profile.summary, "string");
  assert.ok(profile.summary.length > 20, name + " must describe itself");
});

// 9. A typo must fail loudly and list the real names. Silently running steady would file a
//    load test as a stress result, which is worse than a crash.
assert.throws(
  () => buildProfile("stres", settings),
  (error) => {
    assert.match(error.message, /Unknown load profile 'stres'/);
    assert.match(error.message, /steady, load, stress, spike/);
    return true;
  }
);

// 10. Nonsensical numbers fall back rather than producing a stage with target NaN, which k6
//     accepts and then runs as something nobody asked for.
{
  const profile = buildProfile("stress", { stepVus: "abc", stepCount: 0, stepDuration: "" });
  assert.deepEqual(profile.options.stages, [
    { duration: "1m", target: 10 },
    { duration: "1m", target: 20 },
    { duration: "1m", target: 30 },
    { duration: "1m", target: 40 },
    { duration: "1m", target: 0 },
  ]);
}

// 11. The profile name is case-insensitive and trimmed: it arrives from a shell.
assert.ok(buildProfile("  STRESS ", settings).options.stages);
assert.equal(buildProfile("Steady", settings).steady, true);

// 12. The OPEN model exists, because it is the only shape that can challenge a server: a
//     VU-based profile backs off exactly when the target slows down, so it can never push a
//     server that is already struggling.
{
  const profile = buildProfile("rate", { duration: "2m", targetRps: 300, preAllocatedVus: 20, maxVus: 200, scenarioName: "journey" });

  assert.equal(profile.steady, false, "a rate run must not use the steady failure gate");
  assert.ok(OPEN_MODEL_PROFILES.includes("rate"));
  assert.deepEqual(profile.options.scenarios, {
    journey: {
      executor: "constant-arrival-rate",
      rate: 300,
      timeUnit: "1s",
      duration: "2m",
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  });
  assert.ok(!profile.options.stages, "an arrival-rate scenario must not also carry stages");
  assert.ok(!profile.options.vus, "nor a fixed VU count - that would be a different executor");
}

// 13. rate-ramp holds a RISING offered rate, and ends at zero so recovery is visible too.
{
  const profile = buildProfile("rate-ramp", {
    targetRps: 400, rateSteps: 4, stepDuration: "1m", preAllocatedVus: 50, maxVus: 800, scenarioName: "journey",
  });

  assert.deepEqual(profile.options.scenarios.journey.stages, [
    { duration: "1m", target: 100 },
    { duration: "1m", target: 200 },
    { duration: "1m", target: 300 },
    { duration: "1m", target: 400 },
    { duration: "1m", target: 0 },
  ]);
  assert.equal(profile.options.scenarios.journey.startRate, 0);
  assert.match(profile.summary, /open model/);
}

// 14. maxVUs below preAllocatedVUs would make k6 refuse to start the scenario at all, so the
//     ceiling is raised rather than passed through.
{
  const profile = buildProfile("rate", { targetRps: 10, preAllocatedVus: 100, maxVus: 10 });
  assert.equal(profile.options.scenarios.default.maxVUs, 100);
}

// 15. Every profile is reachable by name and described in PROFILES - the list is what the
//     runners validate against, so a profile missing from it is unusable from the CLI.
{
  const names = PROFILES.slice().sort();
  assert.deepEqual(names, ["load", "rate", "rate-ramp", "spike", "steady", "stress"]);
  PROFILES.forEach(function (name) {
    assert.ok(buildProfile(name, settings).summary.length > 20, name + " must describe itself");
  });
}

console.log("profiles.test.mjs: all assertions passed");
