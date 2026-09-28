/*
 * Environment helpers shared by every scenario.
 *
 * Two rules this file enforces:
 *
 * 1. There is no default TARGET_URL. A wrong default silently load-tests the
 *    wrong thing (which is exactly how the old `http://api-service/` default
 *    behaved once the API was moved to port 8080). A missing target is a
 *    configuration error and must fail loudly, at init time.
 *
 * 2. An empty string means "not set". `Number(__ENV.X || fallback)` looks like
 *    it does that, but it silently accepts garbage ("abc" -> NaN) and cannot
 *    express an intentional 0 for some knobs. Parse explicitly instead.
 */

export function requireEnv(name, example) {
  const raw = __ENV[name];
  if (raw === undefined || String(raw).trim() === "") {
    const hint = example ? ` Example: ${name}=${example}` : "";
    throw new Error(
      `${name} is required but was not set.${hint}\n` +
        "This kit deliberately defines no default so a misconfigured run fails " +
        "loudly instead of quietly measuring the wrong endpoint."
    );
  }
  return String(raw).trim();
}

export function requireTargetUrl() {
  return requireEnv("TARGET_URL", "http://api-service:8080/api/health");
}

export function envString(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || String(raw).trim() === "") {
    return fallback;
  }
  return String(raw).trim();
}

export function envNumber(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || String(raw).trim() === "") {
    return fallback;
  }
  const parsed = Number(String(raw).trim());
  if (!isFinite(parsed) || parsed < 0) {
    throw new Error(`${name} must be a non-negative number, but got "${raw}".`);
  }
  return parsed;
}

export function envBoolean(name, fallback) {
  const value = envString(name, "");
  if (value === "") {
    return fallback;
  }
  return ["1", "true", "yes", "on"].indexOf(value.toLowerCase()) !== -1;
}

/*
 * Sent as the User-Agent on every request so the request shows up as this kit
 * in the API's own logs and APM, rather than as an anonymous client.
 */
export const USER_AGENT = "perf-test-kit/1.0 (k6)";

/*
 * Trend statistics requested on every run. p(90)/p(95)/p(99) are the numbers
 * the regression gate in scripts/compare-summary.ps1 reads back out of the
 * summary, so keep them in sync with that script.
 */
export const TREND_STATS = ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)"];
