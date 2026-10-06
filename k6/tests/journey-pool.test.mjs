/*
 * What a POOLED journey run actually does, checked without k6:
 *
 *   node k6/tests/journey-pool.test.mjs
 *
 * Why this exists, and why it is not another parsing test: the failure this guards against
 * is silent and expensive. If the account is resolved in the wrong place, every VU
 * authenticates as the SAME account while the run looks perfectly healthy - thirty VUs,
 * thirty "successful" logins, one user, and a capacity number that belongs to the test
 * rather than to the system. Nothing in the summary would show it. Only the login requests
 * themselves do.
 *
 * So this runs the real scenario with k6's modules stubbed, and asserts on the calls it
 * makes: which account each VU logs in as, which token each request carries, and which tag
 * the requests are given.
 *
 * The stubs are the only invented part. journey-test.js, lib/auth.js, lib/env.js,
 * lib/users.js and lib/summary.js are the real files, copied unmodified.
 */

import assert from "node:assert/strict";
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// ---------------------------------------------------------------------------
// A scratch tree that node can resolve "k6/http" and "k6" from, containing the real
// scenario files plus minimal stand-ins for the k6 built-ins.
// ---------------------------------------------------------------------------
const root = mkdtempSync(join(tmpdir(), "journey-pool-"));
const scripts = join(root, "scripts");
mkdirSync(join(root, "node_modules", "k6"), { recursive: true });
cpSync("k6/scripts", scripts, { recursive: true });
writeFileSync(join(root, "package.json"), JSON.stringify({ type: "module" }));

// "k6/http" has to RESOLVE to the stub. ESM does not guess file extensions for a bare
// specifier the way CommonJS does, so the stubbed package needs an exports map saying which
// file each subpath is.
writeFileSync(
  join(root, "node_modules", "k6", "package.json"),
  JSON.stringify({
    name: "k6",
    type: "module",
    exports: {
      ".": "./index.js",
      "./http": "./http.js",
      "./encoding": "./encoding.js",
    },
  })
);

// Every call the scenario makes, recorded. This is what the assertions read.
const calls = [];

writeFileSync(
  join(root, "node_modules", "k6", "http.js"),
  [
    "const calls = globalThis.__K6_CALLS;",
    "export default {",
    "  post(url, body, params) {",
    "    calls.push({ method: 'POST', url, body, headers: (params && params.headers) || {}, tags: (params && params.tags) || {} });",
    "    // An opaque token: no dots, so the JWT decoding paths are skipped and the",
    "    // scenario is left with a plain string, which is what it uses.",
    "    const email = JSON.parse(body).Email;",
    "    return { status: 200, body: JSON.stringify({ data: { accessToken: 'token-for-' + email } }) };",
    "  },",
    "  get(url, params) {",
    "    calls.push({ method: 'GET', url, headers: (params && params.headers) || {}, tags: (params && params.tags) || {} });",
    "    return { status: 200, body: '' };",
    "  },",
    "};",
  ].join("\n")
);

writeFileSync(
  join(root, "node_modules", "k6", "index.js"),
  [
    "export function check() {}",
    "export function sleep() {}",
    "export const options = {};",
  ].join("\n")
);

writeFileSync(
  join(root, "node_modules", "k6", "encoding.js"),
  "export default { b64decode: () => '', b64encode: () => '' };"
);

const scenarioUrl = pathToFileURL(join(scripts, "journey-test.js")).href;

/*
 * Load the scenario fresh for each case.
 *
 * A cache-busting query is required: node caches modules by URL, and this scenario reads
 * __ENV at import time, so a second case would otherwise reuse the first case's pool -
 * which is exactly the bug this file exists to catch, arriving in the test instead.
 */
async function loadScenario(env, pool, vu) {
  globalThis.__K6_CALLS = calls;
  globalThis.__ENV = env;
  globalThis.__VU = vu;

  calls.length = 0;
  const module = await import(scenarioUrl + "?case=" + encodeURIComponent(env.__CASE));
  return module;
}

const loginUrl = "https://idp.example.test/accounts/login";
const apiBase = "http://api-service:8080";

function envFor(pool) {
  const env = {
    TARGET_URL: apiBase,
    LOGIN_URL: loginUrl,
    TARGET_VUS: "3",
    TEST_DURATION: "1s",
    REQUEST_PAUSE: "0",
    STEP_PAUSE: "0",
  };
  if (pool) {
    env.JOURNEY_USERS_JSON = JSON.stringify(pool);
  }
  else {
    env.JOURNEY_USERNAME = "single@example.test";
    env.JOURNEY_PASSWORD = "single-password";
  }
  return env;
}

const pool = [
  { username: "first@example.test", password: "p1" },
  { username: "second@example.test", password: "p2" },
  { username: "third@example.test", password: "p3" },
];

// ---------------------------------------------------------------------------
// Case 1: a pool, three VUs. Each must authenticate as its OWN account.
// ---------------------------------------------------------------------------
for (const vu of [1, 2, 3]) {
  const env = envFor(pool);
  env.__CASE = "pooled-vu" + vu;
  const scenario = await loadScenario(env, pool, vu);

  // setup() must NOT hand out a single token: with a pool, one token for everyone is the
  // bug. It reports the pool size and lets each VU log in as itself.
  const data = scenario.setup();
  assert.deepEqual(
    data,
    { pooled: 3 },
    "setup() must not fetch a shared token when a pool is configured"
  );
  assert.equal(calls.length, 0, "setup() must not log in when a pool is configured");

  scenario.default(data);

  const login = calls.find((call) => call.method === "POST");
  assert.ok(login, "each VU must log in at least once");
  const expected = pool[vu - 1].username;
  assert.equal(
    JSON.parse(login.body).Email,
    expected,
    "VU " + vu + " must log in as its own account, not someone else's"
  );
  assert.equal(JSON.parse(login.body).Password, pool[vu - 1].password, "with its own password");

  // The journey steps must carry THAT VU's token, and be tagged with the account index -
  // the tag is what makes an outlier account visible in the dashboard.
  const steps = calls.filter((call) => call.method === "GET");
  assert.equal(steps.length, scenario.STEPS.length, "every step in the table must be requested");
  steps.forEach((step, position) => {
    assert.equal(
      step.headers.Authorization,
      "Bearer token-for-" + expected,
      "each step must use the token minted for this VU's account"
    );
    assert.equal(step.tags.account, "user-0" + vu, "each step must be tagged with the account");
    // Asserted against the scenario's OWN table, so editing a step's path does not leave a
    // stale expectation behind here.
    assert.equal(
      step.url,
      apiBase + scenario.STEPS[position].path,
      "step " + position + " must hit the path the table configures"
    );
    assert.equal(step.tags.name, scenario.STEPS[position].name, "and be tagged with the table's name");
  });
  assert.equal(calls.filter((call) => call.method === "POST").length, 1, "one login per VU, not one per step");
}

// ---------------------------------------------------------------------------
// Case 1b: a step's path is overridable per environment, which is the point of reading the
// <STEP>_PATH variables at all.
// ---------------------------------------------------------------------------
{
  const env = envFor(pool);
  env.KYC_STEP_PATH = "/custom/kyc";
  env.WALLETS_PATH = "/custom/wallets";
  env.__CASE = "path-overrides";
  const scenario = await loadScenario(env, pool, 1);
  scenario.default(scenario.setup());

  const urls = calls.filter((call) => call.method === "GET").map((call) => call.url);
  assert.ok(urls.includes(apiBase + "/custom/kyc"), "KYC_STEP_PATH must be honoured");
  assert.ok(urls.includes(apiBase + "/custom/wallets"), "WALLETS_PATH must be honoured");
}

// ---------------------------------------------------------------------------
// Case 2: more VUs than accounts - accounts are shared, deterministically.
// ---------------------------------------------------------------------------
{
  const env = envFor(pool);
  env.__CASE = "pooled-wrap";
  const scenario = await loadScenario(env, pool, 4);
  scenario.default(scenario.setup());

  const login = calls.find((call) => call.method === "POST");
  assert.equal(
    JSON.parse(login.body).Email,
    "first@example.test",
    "the fourth VU wraps back to the first account"
  );
  assert.equal(calls.filter((call) => call.method === "GET")[0].tags.account, "user-01");
}

// ---------------------------------------------------------------------------
// Case 3: no pool - the original behaviour, unchanged. One login in setup(), shared by
// every VU, and no account tag (a run with one account has nothing to compare).
// ---------------------------------------------------------------------------
{
  const env = envFor(null);
  env.__CASE = "single";
  const scenario = await loadScenario(env, null, 1);

  const data = scenario.setup();
  assert.equal(
    data.token,
    "token-for-single@example.test",
    "without a pool, setup() logs in once and hands the token to every VU"
  );

  calls.length = 0;
  scenario.default(data);

  assert.equal(calls.filter((call) => call.method === "POST").length, 0, "no login per VU without a pool");
  const steps = calls.filter((call) => call.method === "GET");
  assert.equal(steps.length, 3);
  steps.forEach((step) => {
    assert.equal(step.headers.Authorization, "Bearer token-for-single@example.test");
    assert.equal(step.tags.account, undefined, "no account tag when there is only one account");
  });
}

// ---------------------------------------------------------------------------
// Case 4: a pool and a single account both configured - the pool wins, and says so.
// ---------------------------------------------------------------------------
{
  const env = envFor(pool);
  env.JOURNEY_USERNAME = "ignored@example.test";
  env.JOURNEY_PASSWORD = "ignored";
  env.__CASE = "both";
  const scenario = await loadScenario(env, pool, 2);
  scenario.default(scenario.setup());

  const login = calls.find((call) => call.method === "POST");
  assert.equal(
    JSON.parse(login.body).Email,
    "second@example.test",
    "the pool wins over a leftover single account"
  );
}

// ---------------------------------------------------------------------------
// Case 5: the supported combination - a pool with AUTH_MODE=off, which is what every runner
// passes for a journey run. One login per VU, and nothing from lib/auth.js.
// ---------------------------------------------------------------------------
{
  const env = envFor(pool);
  env.AUTH_MODE = "off";
  env.__CASE = "pooled-authmode-off";
  const scenario = await loadScenario(env, pool, 1);

  const data = scenario.setup();
  const before = calls.length;
  scenario.default(data);

  assert.equal(
    calls.length - before,
    4,
    "one login plus three steps - not a second login through lib/auth.js as well"
  );
  assert.equal(
    calls.filter((call) => call.method === "POST" && call.tags.name === "auth/login").length,
    0,
    "lib/auth.js must stay out of it when the journey authenticates itself"
  );
}

// ---------------------------------------------------------------------------
// Case 6: AUTH_MODE left on. The journey cannot stop lib/auth.js from logging in as well -
// that is the runner's job - but it must SAY so, because the symptom is otherwise invisible:
// the run succeeds while measuring twice the logins it claims to.
// ---------------------------------------------------------------------------
{
  const env = envFor(pool);
  env.AUTH_MODE = "json-login";
  env.__CASE = "pooled-authmode-on";

  const warnings = [];
  const originalWarn = console.warn;
  console.warn = (message) => warnings.push(String(message));

  let scenario;
  try {
    scenario = await loadScenario(env, pool, 1);
  }
  finally {
    console.warn = originalWarn;
  }

  assert.equal(
    warnings.filter((warning) => /AUTH_MODE=json-login/.test(warning) && /logs? in once MORE per VU/.test(warning)).length,
    1,
    "a redundant AUTH_MODE must be reported, not silently tolerated"
  );

  scenario.default(scenario.setup());
  assert.equal(
    calls.filter((call) => call.method === "POST" && call.tags.name === "auth/login").length,
    1,
    "with AUTH_MODE on, the duplicate login really does happen - which is why the warning exists"
  );
}

// ---------------------------------------------------------------------------
// Case 7: the load profile reaches the scenario's options, and the per-step thresholds are
// generated from the STEPS table rather than hand-written next to it.
// ---------------------------------------------------------------------------
{
  // steady: the vus/duration shortcut, and the failure gate that aborts.
  const steady = await loadScenario(Object.assign(envFor(null), { __CASE: "profile-steady" }), null, 1);
  assert.equal(steady.options.stages, undefined, "steady must not carry stages");
  assert.equal(typeof steady.options.vus, "number");
  assert.equal(typeof steady.options.duration, "string");
  assert.equal(
    steady.options.thresholds.http_req_failed[0].abortOnFail,
    true,
    "a steady journey must still abort on a broken login"
  );

  // stress: stages that grow and then return to zero, and NO abort - the run is meant to
  // degrade, and aborting would end it exactly where the interesting part starts.
  const stressEnv = Object.assign(envFor(null), {
    JOURNEY_PROFILE: "stress",
    STEP_VUS: "5",
    STRESS_STEPS: "3",
    STEP_DURATION: "15s",
    __CASE: "profile-stress",
  });
  const stress = await loadScenario(stressEnv, null, 1);

  assert.equal(stress.options.vus, undefined, "a staged profile must not also set vus");
  assert.deepEqual(stress.options.stages, [
    { duration: "15s", target: 5 },
    { duration: "15s", target: 10 },
    { duration: "15s", target: 15 },
    { duration: "15s", target: 0 },
  ]);
  assert.deepEqual(
    stress.options.thresholds.http_req_failed,
    ["rate<0.05"],
    "a stress journey must not abort at the first failed request"
  );

  // Every step in the table has its own threshold, generated from the table - so adding a
  // step cannot leave it unmeasured.
  ["login", "kyc-step", "wallets", "requests-active"].forEach(function (step) {
    assert.ok(
      stress.options.thresholds["http_req_duration{name:" + step + "}"],
      "step '" + step + "' must have a generated per-step threshold"
    );
  });
}

rmSync(root, { recursive: true, force: true });
console.log("journey-pool.test.mjs: all assertions passed");
