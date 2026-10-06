/*
 * A POOL OF TEST ACCOUNTS, one per virtual user.
 *
 * Why this exists: a load test that logs in as the same account 30 times is not a test of
 * the product, it is a test of what one account can do. Real traffic is many users, and
 * the differences matter in ways a single account hides completely:
 *
 *   * per-user rate limits and quotas, which a shared account hits first and reports as
 *     "the API got slow";
 *   * per-user caches, which a shared account makes artificially warm;
 *   * per-user rows in the database - one account's wallets, requests or statements -
 *     where every VU waiting on the same row serializ  es on a lock and the run understates
 *     what the system can do, or manufactures a knee that does not exist;
 *   * and the outlier: with per-account tags you can see that ONE account is slow rather
 *     than averaging it away into a single latency number.
 *
 * WHERE THE CREDENTIALS COME FROM
 * -------------------------------
 * The scenario never reads a file. The runner reads the file, validates it, and passes the
 * whole list as JSON in one environment variable:
 *
 *   JOURNEY_USERS_JSON=[{"username":"a@example.com","password":"..."}, ...]
 *
 * That is deliberate, and it is the shape that works on every path this kit supports:
 *
 *   * in Kubernetes the variable comes from a Secret, so the credentials are never written
 *     into the Job manifest that gets archived next to the results;
 *   * the k6 image only contains k6/scripts, so a credentials file that lived there would
 *     be baked into the image and pushed to a registry with it;
 *   * docker compose mounts k6/scripts read-only and nothing else, so a file outside it is
 *     not visible to the generator at all.
 *
 * JOURNEY_USERS_FILE also works, for running k6 by hand with a file you mounted yourself.
 * It is not the recommended path in a cluster, for the reason above.
 *
 * SHAPES ACCEPTED, because credentials files are written by hand
 * -------------------------------------------------------------
 *   [{ "username": "a@x.com", "password": "p" }, ...]        an array of objects
 *   { "users": [ ... ] }                                     the same, wrapped
 *   ["a@x.com:p", "b@x.com:p2"]                              "username:password" strings
 *
 * "email" is accepted for "username", and "pass" for "password". Anything else is an
 * error that names the entry and what it did contain - a malformed credentials file must
 * fail before a run, not half way through one as a wall of 401s.
 *
 * WHICH USER GETS WHICH VU
 * ------------------------
 * Round robin, and STABLE per VU: VU 1 gets user 1, VU 31 gets user 1 again, and a VU keeps
 * its account for the whole run. Stability is not cosmetic - the token cache is per VU, so
 * a VU that switched account mid-run would keep sending the previous account's token.
 *
 * If there are fewer accounts than VUs, accounts are shared and the run says so once. If
 * there are more accounts than VUs, the extras are unused: raise TARGET_VUS to use them.
 *
 * This module must stay free of k6 globals at import time so it can be unit-tested outside
 * k6 - see k6/tests/users.test.mjs. The two functions that do touch k6 (__ENV, open) are
 * explicit about it.
 */

export const USERS_JSON_ENV = "JOURNEY_USERS_JSON";
export const USERS_FILE_ENV = "JOURNEY_USERS_FILE";

/* Names that mean "the account", and "the secret", in files written by other people. */
const USERNAME_KEYS = ["username", "userName", "email", "user", "login"];
const PASSWORD_KEYS = ["password", "pass", "pwd"];

function firstPresent(source, keys) {
  for (let index = 0; index < keys.length; index += 1) {
    const value = source[keys[index]];
    if (typeof value === "string" && value !== "") {
      return { key: keys[index], value: value };
    }
  }
  return null;
}

/*
 * Turn ONE entry into { username, password }.
 *
 * Returns either { user } or { error }, rather than throwing, so the caller can report
 * every bad entry in one pass instead of one run per mistake.
 */
function normalizeEntry(entry, index) {
  const where = "users[" + index + "]";

  // "username:password" - the shape an env-file style list usually takes. Split on the
  // FIRST colon only, because a password may legitimately contain one.
  if (typeof entry === "string") {
    const separator = entry.indexOf(":");
    if (separator <= 0 || separator === entry.length - 1) {
      return { error: where + ' is the string "' + entry.slice(0, 40) + '", which is not "username:password".' };
    }
    return {
      user: {
        username: entry.slice(0, separator).trim(),
        password: entry.slice(separator + 1),
      },
    };
  }

  if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    return { error: where + " is not an object or a \"username:password\" string." };
  }

  const username = firstPresent(entry, USERNAME_KEYS);
  const password = firstPresent(entry, PASSWORD_KEYS);

  if (!username) {
    return {
      error:
        where + " has no account name. Expected one of: " + USERNAME_KEYS.join(", ") +
        ". Found keys: " + (Object.keys(entry).join(", ") || "(none)"),
    };
  }
  if (!password) {
    return {
      error:
        where + " (" + username.value + ") has no password. Expected one of: " +
        PASSWORD_KEYS.join(", ") + ". Found keys: " + (Object.keys(entry).join(", ") || "(none)"),
    };
  }

  return { user: { username: username.value, password: password.value } };
}

/*
 * Parse the pool.
 *
 * Throws on anything malformed, with every problem listed at once: a credentials file with
 * three mistakes should take one run to fix, not three.
 */
export function parseUsers(payload, source) {
  const label = source || USERS_JSON_ENV;

  let parsed = payload;
  if (typeof payload === "string") {
    try {
      parsed = JSON.parse(payload);
    }
    catch (error) {
      throw new Error(
        "The credential pool in " + label + " is not valid JSON: " + error.message +
          "\nIt should look like: [{\"username\":\"a@example.com\",\"password\":\"...\"}]"
      );
    }
  }

  // {"users": [...]} is accepted because it is a natural way to write the file.
  const entries = Array.isArray(parsed) ? parsed : (parsed && Array.isArray(parsed.users) ? parsed.users : null);

  if (!entries) {
    throw new Error(
      "The credential pool in " + label + " must be a JSON array of accounts, or an object with a \"users\" array." +
        "\nGot: " + (parsed === null ? "null" : typeof parsed)
    );
  }

  if (entries.length === 0) {
    throw new Error("The credential pool in " + label + " is empty, so no virtual user could authenticate.");
  }

  const users = [];
  const problems = [];

  for (let index = 0; index < entries.length; index += 1) {
    const result = normalizeEntry(entries[index], index);
    if (result.error) {
      problems.push(result.error);
      continue;
    }
    users.push(result.user);
  }

  if (problems.length > 0) {
    throw new Error(
      "The credential pool in " + label + " has " + problems.length + " unusable entr" +
        (problems.length === 1 ? "y" : "ies") + ":\n  " + problems.join("\n  ")
    );
  }

  // Duplicates are almost always a copy-paste mistake, and they silently reduce the pool
  // to fewer accounts than the operator asked for.
  const seen = {};
  const duplicates = [];
  users.forEach(function (user) {
    if (seen[user.username]) {
      duplicates.push(user.username);
    }
    seen[user.username] = true;
  });

  if (duplicates.length > 0) {
    throw new Error(
      "The credential pool in " + label + " lists the same account more than once: " +
        duplicates.join(", ") + ".\nDuplicates do not add concurrency - use distinct accounts."
    );
  }

  return users;
}

/* The account for a virtual user id (1-based), round robin and stable. */
export function userForVu(users, vu) {
  if (!users || users.length === 0) {
    return null;
  }

  let position = Number(vu);
  if (!isFinite(position) || position < 1) {
    position = 1;
  }

  const index = (Math.floor(position) - 1) % users.length;
  return { user: users[index], index: index };
}

/*
 * A label for metrics and logs.
 *
 * The account NAME is a person's email address, and tags end up on a dashboard, in a
 * summary and sometimes in a screenshot. The index is what a run actually needs: "is one
 * account the outlier", not "whose account is it".
 */
export function accountLabel(index) {
  const position = Number(index) + 1;
  return "user-" + (position < 10 ? "0" + position : String(position));
}

/* Read the pool from the environment, or from a file the caller mounted, or not at all. */
export function loadUsers() {
  if (typeof __ENV === "undefined") {
    return null;
  }

  const inline = __ENV[USERS_JSON_ENV];
  if (typeof inline === "string" && inline.trim() !== "") {
    return { users: parseUsers(inline, USERS_JSON_ENV), source: USERS_JSON_ENV };
  }

  const file = __ENV[USERS_FILE_ENV];
  if (typeof file === "string" && file.trim() !== "") {
    if (typeof open !== "function") {
      throw new Error(
        USERS_FILE_ENV + " is set to '" + file + "' but this k6 context cannot read files. " +
          "Set " + USERS_JSON_ENV + " instead, or pass the file to the runner (k6/run-journey.ps1 -UsersFile)."
      );
    }

    let text;
    try {
      text = open(file);
    }
    catch (error) {
      throw new Error(
        "Could not read the credential pool file '" + file + "' (" + USERS_FILE_ENV + "): " + error.message +
          "\nIn a cluster the k6 image only contains k6/scripts, so a file outside it is not in the container: " +
          "pass the pool as " + USERS_JSON_ENV + " (the runners do this from a credentials file)."
      );
    }

    return { users: parseUsers(text, file), source: file };
  }

  return null;
}

/*
 * One line saying which account this VU is using, and whether accounts are shared.
 *
 * Printed once per VU, on first use - the same volume as the token line lib/auth.js already
 * prints, and it is the only way to tell from a finished run which account owned which VU.
 */
export function describeAssignment(users, vu, index) {
  const shared = users.length < Number(vu);
  return (
    "[users] VU " + vu + " -> " + accountLabel(index) + " (" + users[index].username + ")" +
    (shared ? " - fewer accounts than VUs, so accounts are shared" : "")
  );
}
