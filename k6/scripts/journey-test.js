/*
 * JOURNEY TEST - a real multi-step user flow.
 *
 * Question it answers : does the flow the user performs still meet its SLO when many users
 *                       perform it at once - and which STEP is the one that breaks?
 * Load shape          : steady (default), load, stress, spike, rate or rate-ramp.
 *
 * ADDING A STEP takes one line. Find STEPS below and add:
 *
 *   { name: "statements", path: envString("STATEMENTS_PATH", "/api/new-core/statements"), p95: 2500 },
 *
 * The request, its per-step metric, its threshold and its console row are all generated from
 * that entry - there is nowhere else to edit, and no step can be measured without being named.
 * (A journey that issues four untagged requests produces ONE blended http_req_duration, and
 * "the journey got slower" is then unanswerable.)
 *
 * CONFIGURATION
 * -------------
 * There is deliberately no default login URL, no account in this file, and no default API base
 * beyond TARGET_URL: a built-in login URL lets a run appear to work against an environment
 * nobody chose, and a password written into a scenario file is a password in git.
 *
 *   LOGIN_URL                 required, no default
 *   JOURNEY_USERNAME          required, no default - unless a credential pool is set
 *   JOURNEY_PASSWORD          required, no default - unless a credential pool is set
 *   JOURNEY_USERS_JSON        optional: many accounts, one per virtual user (lib/users.js)
 *   JOURNEY_PROFILE           steady (default) | load | stress | spike | rate | rate-ramp
 *   API_BASE_URL              optional: falls back to TARGET_URL, which every runner sets
 *   <STEP>_PATH               each step's path, defaulted in the STEPS table
 *   REQUEST_HEADERS           optional extra headers, see lib/env.js
 *   STEP_PAUSE                default 0    (think time BETWEEN steps, seconds)
 *   REQUEST_PAUSE             default 0.5  (think time between journeys)
 *
 * LOAD SHAPES - one scenario, six profiles
 * ----------------------------------------
 * CLOSED (VU-based): each VU waits for its own response before sending the next request, so
 * offered load FALLS when the target slows down. Right for "does the flow hold up"; it cannot
 * answer "what can the server take", because it backs off exactly when the server buckles.
 *
 *   steady      TARGET_VUS for TEST_DURATION                       (the default)
 *   load        ramp to TARGET_VUS, hold, ramp down                RAMP_DURATION, HOLD_DURATION
 *   stress      plateaus of STEP_VUS, STRESS_STEPS times, then 0   STEP_DURATION
 *   spike       baseline, spike, back to baseline                  BASELINE_VUS, SPIKE_VUS, ...
 *
 * OPEN (arrival rate): a FIXED number of journey iterations per second is offered whatever the
 * target does, so a target that cannot keep up queues and its latency rises. This is the shape
 * to use when the goal is to LOAD A SERVER rather than to characterise a flow:
 *
 *   rate        TARGET_RPS iterations/s for TEST_DURATION          TARGET_RPS, PREALLOCATED_VUS, MAX_VUS
 *   rate-ramp   that rate rising in RATE_STEPS steps, then 0       + RATE_STEPS, STEP_DURATION
 *
 * READ dropped_iterations BEFORE TRUSTING A rate RUN. If k6 runs out of VUs it drops
 * iterations instead of sending them, and the run then looks like a server that coped
 * perfectly. It is printed in the summary; if it is not zero, raise MAX_VUS or lower
 * TARGET_RPS - and if raising MAX_VUS fixes it, the generator was the bottleneck, not the API.
 *
 * Stress, spike and both rate profiles are SUPPOSED to cross the per-step thresholds; that is
 * the finding, not a broken build. So the failure gate is loosened for them and does not abort -
 * aborting would end the run exactly where the interesting part starts. Only a steady run
 * aborts on the first failed requests, because a broken login should cost seconds, not a whole
 * profile.
 *
 * THE ACCOUNT
 * -----------
 * With JOURNEY_USERS_JSON (a credential pool, see lib/users.js) each VU logs in as its OWN
 * account instead of the whole run sharing one - because thirty VUs on one account serialise on
 * that account's rows, share its cache and share its quota, so a single-account run can report
 * a knee that is an artefact of the test. Each request is tagged `account=user-01`, `user-02`,
 * ... so a slow outlier is visible instead of being averaged away; the account NAME is never a
 * tag, because tags end up on dashboards.
 *
 * A staged or ramped profile starts VUs in waves, so those logins spread across the stages
 * instead of arriving as one burst - which matters, because a burst of N simultaneous logins is
 * the first thing an identity provider rate-limits. An arrival-rate profile still needs one
 * VU per in-flight iteration, so a high TARGET_RPS against a slow target means many VUs, and
 * therefore many logins.
 *
 * A journey usually points at a shared environment reached over the public internet, so
 * absolute latency includes WAN round trips and whatever else the team is doing there. Treat
 * the numbers as "is the flow functional, and roughly how does it scale", then move to a
 * dedicated environment before drawing capacity conclusions.
 */

import http from "k6/http";
import { check, sleep } from "k6";
import encoding from "k6/encoding";

import { USER_AGENT, TREND_STATS, buildRequestHeaders, envNumber, envString } from "./lib/env.js";
import { makeHandleSummary } from "./lib/summary.js";
import { accountLabel, describeAssignment, loadUsers, userForVu } from "./lib/users.js";
import { buildProfile } from "./lib/profiles.js";

const testType = "journey";

/*
 * Report EVERY missing required variable in one pass.
 *
 * requireEnv throws on the first one it finds, so a half-configured run tells you about
 * LOGIN_URL, then JOURNEY_USERNAME, then JOURNEY_PASSWORD over three separate attempts.
 * Collecting them first turns three round trips into one.
 */
function assertPresent(names) {
  const missing = names.filter(function (name) {
    const raw = __ENV[name];
    return raw === undefined || String(raw).trim() === "";
  });

  if (missing.length > 0) {
    throw new Error(
      "The journey test is missing required configuration: " +
        missing.join(", ") +
        ".\nPass them as environment variables, never in this file. For example:\n" +
        "  -EnvVars LOGIN_URL=https://idp.example.com/accounts/login," +
        "JOURNEY_USERNAME=someone@example.com,JOURNEY_PASSWORD=***"
    );
  }
}

// No fallback login URL and no account anywhere in this file: a built-in login URL lets
// a run appear to work against an environment nobody chose, and a password written into
// a scenario file is a password in git.
//
// The account and password are only required when there is no credential POOL. With a pool
// (JOURNEY_USERS_JSON) each VU has its own, and demanding one named account as well would
// be asking for a value the run never uses.
const pool = loadUsers();

assertPresent(pool ? ["LOGIN_URL"] : ["LOGIN_URL", "JOURNEY_USERNAME", "JOURNEY_PASSWORD"]);

const loginUrl = envString("LOGIN_URL", "");
const username = envString("JOURNEY_USERNAME", "");
const password = envString("JOURNEY_PASSWORD", "");

if (pool && envString("JOURNEY_USERNAME", "") !== "") {
  console.log(
    "[journey] JOURNEY_USERNAME is set but a pool of " + pool.users.length + " account(s) came from " +
      pool.source + "; the pool wins and the single account is unused."
  );
}

/*
 * The journey authenticates itself, so the generic mechanism in lib/auth.js is redundant
 * here - and it is not merely redundant, it is expensive. With AUTH_MODE left on, every VU
 * logs in TWICE on its first iteration: once for the journey, once for lib/auth.js. That
 * doubles the login burst at exactly the moment the identity provider is at its busiest,
 * and on an IdP that rate-limits it turns into a wall of "login response has no token"
 * errors that look like the API failing.
 *
 * The runners pass AUTH_MODE=off. This warns when something else did not, because the
 * symptom is otherwise invisible: the run works, it is just measuring more logins than it
 * claims to.
 */
const configuredAuthMode = envString("AUTH_MODE", "");
if (configuredAuthMode !== "" && configuredAuthMode.toLowerCase() !== "off") {
  console.warn(
    "[journey] AUTH_MODE=" + configuredAuthMode + " is set, but this scenario authenticates itself. lib/auth.js " +
      "will therefore log in once MORE per VU on top of each VU's own login. Set AUTH_MODE=off to stop that."
  );
}

// The API base is API_BASE_URL, or TARGET_URL - which both runners already set, validate
// and record, so `-TargetUrl <api base>` is enough to run a journey. At least one must be
if (envString("API_BASE_URL", "") === "" && envString("TARGET_URL", "") === "") {
  throw new Error(
    "The journey test needs a base URL. Pass -TargetUrl <api base> to the runner, or set " +
      "API_BASE_URL. There is deliberately no default: a built-in URL would let a run " +
      "measure an environment nobody chose."
  );
}

const apiBaseUrl = (envString("API_BASE_URL", "") || envString("TARGET_URL", "")).replace(/\/+$/, "");

/*
 * ============================ THE STEPS ============================
 * One line per step. Everything else is generated from this table:
 *
 *   name   what the step is called in metrics, thresholds and the console summary.
 *          Keep it free of "/" so it is safe as a Prometheus label value and as a k6
 *          threshold selector.
 *   path   appended to the API base. Defaulted here, overridable per environment.
 *   p95    the SLO for THIS step, in milliseconds - because an SLO belongs to an endpoint,
 *          not to a journey.
 *
 * Add one, remove one, reorder them: the iteration runs them in order and each keeps its
 * own metrics.
 * ===================================================================
 */
const STEPS = [
  { name: "kyc-step", path: envString("KYC_STEP_PATH", "/kyc/step"), p95: 2000 },
  { name: "wallets", path: envString("WALLETS_PATH", "/wallets"), p95: 2000 },
  { name: "requests-active", path: envString("REQUESTS_ACTIVE_PATH", "/requests/active"), p95: 2000 },
];

// Exported so the harness in k6/tests can assert against the table itself rather than against
// a second copy of the paths - a copy that would go stale the first time somebody edits a step.
export { STEPS };

const STEP_LOGIN = "login";

const stepPause = envNumber("STEP_PAUSE", 0);
const requestPause = envNumber("REQUEST_PAUSE", 0.5);

/*
 * The load shape: steady by default, or load/stress/spike. Same knob names as the
 * single-endpoint scenarios, so STEP_VUS here means what it means in stress-test.js.
 */
const journeyProfile = envString("JOURNEY_PROFILE", "steady");
const profile = buildProfile(journeyProfile, {
  vus: envNumber("TARGET_VUS", 5),
  duration: envString("TEST_DURATION", "1m"),
  stepVus: envNumber("STEP_VUS", 10),
  stepCount: envNumber("STRESS_STEPS", 4),
  stepDuration: envString("STEP_DURATION", "1m"),
  rampDuration: envString("RAMP_DURATION", "1m"),
  holdDuration: envString("HOLD_DURATION", "5m"),
  baselineVus: envNumber("BASELINE_VUS", 5),
  spikeVus: envNumber("SPIKE_VUS", 50),
  baselineDuration: envString("BASELINE_DURATION", "30s"),
  spikeDuration: envString("SPIKE_DURATION", "1m"),
  // The open-model profiles: a FIXED offered rate, which is the only way to keep pushing a
  // server that is already slowing down.
  targetRps: envNumber("TARGET_RPS", 100),
  preAllocatedVus: envNumber("PREALLOCATED_VUS", 50),
  maxVus: envNumber("MAX_VUS", 400),
  rateSteps: envNumber("RATE_STEPS", 4),
  scenarioName: "journey",
});

console.log("[journey] load profile: " + journeyProfile + " - " + profile.summary);

/*
 * Per-step SLOs, generated from the table above.
 *
 * This is the payoff of naming every request: a single slow step fails its own threshold
 * instead of averaging away inside one journey-wide number.
 */
const thresholds = { checks: ["rate>0.99"] };
thresholds["http_req_duration{name:" + STEP_LOGIN + "}"] = ["p(95)<3000"];
STEPS.forEach(function (step) {
  thresholds["http_req_duration{name:" + step.name + "}"] = ["p(95)<" + step.p95];
});

if (profile.steady) {
  // abortOnFail: a journey where authentication or the first step is broken should stop in
  // seconds, not spend the whole duration generating 401s. A whole run of failures is the
  // most expensive possible way to learn that a password changed.
  thresholds.http_req_failed = [{ threshold: "rate<0.01", abortOnFail: true, delayAbortEval: "20s" }];
}
else {
  // A stress or spike run is SUPPOSED to make the target fail; aborting at the first sign of
  // it would stop the run exactly where the interesting part begins. Loosened, and no abort.
  thresholds.http_req_failed = ["rate<0.05"];
}

export const options = Object.assign(
  {
    discardResponseBodies: true,
    summaryTrendStats: TREND_STATS,
    userAgent: USER_AGENT,
    tags: { test_type: testType },
  },
  profile.options,
  { thresholds: thresholds }
);

/*
 * Log in and return the access token.
 *
 * `account` is { username, password } when this VU has its own from a pool, and null for a
 * single-account run. Exported so a scenario that wants to authenticate per iteration (or to
 * measure the identity provider) can reuse it rather than duplicating the request shape.
 */
export function login(account, tag) {
  const accountName = account ? account.username : username;
  const accountPassword = account ? account.password : password;

  const response = http.post(
    loginUrl,
    JSON.stringify({ Email: accountName, Password: accountPassword, RememberMe: true }),
    {
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      // Load-bearing. Options.discardResponseBodies is true for this test - the
      // generator's memory must not become the thing under test - and that would
      // discard THIS response too, leaving JSON.parse with an empty body. The result
      // is a run where the login POST returns 200 and looks healthy in the metrics
      // while every iteration fails with a confusing parse error.
      responseType: "text",
      tags: tag ? { name: STEP_LOGIN, account: tag } : { name: STEP_LOGIN },
    }
  );

  if (response.status < 200 || response.status >= 300) {
    throw new Error(
      "Login failed: HTTP " +
        response.status +
        " from " +
        loginUrl +
        (account ? " as " + accountName : "") +
        ".\n" +
        "Check JOURNEY_USERNAME/JOURNEY_PASSWORD, or the entry for this account in the credential pool." +
        " Response: " +
        String(response.body).slice(0, 300)
    );
  }

  let payload;
  try {
    payload = JSON.parse(response.body);
  }
  catch (error) {
    throw new Error(
      "Login returned HTTP " +
        response.status +
        " but the body is not JSON. Got: " +
        String(response.body).slice(0, 200)
    );
  }

  const token = payload && payload.data ? payload.data.accessToken : null;
  if (!token) {
    throw new Error(
      "Login response has no data.accessToken. Got keys: " +
        (payload ? Object.keys(payload).join(", ") : "(no object)") +
        (payload && payload.data ? " / data keys: " + Object.keys(payload.data).join(", ") : "")
    );
  }

  logTokenLifetime(token);
  return token;
}

/*
 * Decode the JWT payload and say when the token expires.
 *
 * Worth the few lines: this scenario logs in ONCE for the whole run, so the token has
 * to outlive the test. Logging the expiry turns "the journey started returning 401s
 * after six hours" from a mystery into an obvious consequence. A failure to decode is
 * ignored - the token is opaque to us and the run is still valid.
 */
function logTokenLifetime(token) {
  try {
    const segments = String(token).split(".");
    if (segments.length < 2) {
      return;
    }

    const payload = JSON.parse(encoding.b64decode(segments[1], "rawurl", "s"));
    if (!payload || typeof payload.exp !== "number") {
      return;
    }

    const expiresAt = new Date(payload.exp * 1000);
    const secondsRemaining = Math.round(payload.exp - Date.now() / 1000);

    console.log(
      "[journey] logged in as sub=" +
        (payload.sub || "?") +
        "; token expires " +
        expiresAt.toISOString() +
        " (" +
        Math.round(secondsRemaining / 60) +
        " minutes from now)"
    );

    // The run is set up to authenticate once, so a token that expires before the test
    // ends silently converts every later step into a 401.
    if (secondsRemaining < 300) {
      console.warn(
        "[journey] the access token expires in under 5 minutes and this test logs in only once. " +
          "Expect 401s near the end of a longer run; use a longer-lived token or log in per iteration."
      );
    }
  }
  catch (ignored) {
    // Opaque token, or a JWT we cannot decode: not worth failing a load test over.
  }
}

/*
 * This VU's account and token, when the run has a pool.
 *
 * Module state is per VU - k6 gives every VU its own JavaScript runtime - so `cachedToken`
 * below is this VU's token and nobody else's, which is exactly what a per-account run needs.
 *
 * The lookup is deliberately NOT done at module scope: it needs __VU, and module scope is
 * the init context, where __VU is 0. Resolving there would hand every VU the first account
 * in the pool - one account, many sessions, which is the thing this feature exists to avoid.
 */
let cachedToken = null;
let cachedAccount = null;

function tokenForThisVu() {
  if (cachedToken !== null) {
    return cachedToken;
  }

  const assignment = userForVu(pool.users, __VU);
  cachedAccount = accountLabel(assignment.index);

  // One line per VU, which is the same volume as the token line below and is the only way
  // to tell from a finished run which account owned which VU.
  console.log(describeAssignment(pool.users, __VU, assignment.index));

  cachedToken = login(assignment.user, cachedAccount);
  return cachedToken;
}

/*
 * Single-account runs log in once here, before any VU starts, so the whole run shares one
 * token and the login is measured once rather than once per VU.
 *
 * A pooled run cannot do that: setup() runs in its own context where there is no VU to
 * attribute an account to, so each VU authenticates as itself on first use instead.
 */
export function setup() {
  if (pool) {
    return { pooled: pool.users.length };
  }
  return { token: login() };
}

function requestStep(name, url, headers, account) {
  const tags = { name: name };
  if (account) {
    tags.account = account;
  }

  const response = http.get(url, {
    headers: headers,
    tags: tags,
  });

  // A check per step, so summary.json names the step that returned a bad status
  // rather than reporting one aggregate "some request failed".
  const assertions = {};
  assertions[name + " responded 2xx"] = (result) => result.status >= 200 && result.status < 400;
  check(response, assertions);

  return response;
}

export default function (data) {
  // A pooled run resolves its token (and its account) on first use, per VU.
  const token = data.token ? data.token : tokenForThisVu();
  const account = data.token ? null : cachedAccount;

  // buildRequestHeaders() keeps REQUEST_HEADERS working as an escape hatch for extra
  // headers (a tenant id, a gateway token). The Authorization header set here wins,
  // because the token in `data` is the logged-in one for this run.
  const headers = Object.assign({}, buildRequestHeaders(), {
    Authorization: "Bearer " + token,
  });

  // One pass through the table. Adding a step to STEPS adds it here, with its own metric,
  // its own threshold and its own console row.
  STEPS.forEach(function (step, index) {
    requestStep(step.name, apiBaseUrl + step.path, headers, account);

    // Think time BETWEEN steps - not after the last one, which would be dead time before the
    // journey's own pause.
    if (stepPause > 0 && index < STEPS.length - 1) {
      sleep(stepPause);
    }
  });

  sleep(requestPause);
}

export const handleSummary = makeHandleSummary({
  test_type: testType,
  target_url: apiBaseUrl,
});
