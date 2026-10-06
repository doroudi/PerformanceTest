/*
 * Sanity checks for k6/scripts/lib/users.js, runnable without k6:
 *
 *   node k6/tests/users.test.mjs
 *
 * A credentials pool is the one input to a load test that is written by hand, in a hurry,
 * outside the repository - so the parsing has to fail loudly and precisely on the mistakes
 * people actually make, and it has to assign accounts deterministically once it does not.
 * Several of these cases are the failure modes that motivated the module: a shared account
 * serialising every VU on one row, and a duplicate account quietly shrinking the pool.
 */

import assert from "node:assert/strict";

import { accountLabel, describeAssignment, parseUsers, userForVu } from "../scripts/lib/users.js";

// 1. The documented shape: an array of objects.
const fromObjects = parseUsers('[{"username":"a@example.com","password":"pa"},{"username":"b@example.com","password":"pb"}]');
assert.equal(fromObjects.length, 2);
assert.equal(fromObjects[0].username, "a@example.com");
assert.equal(fromObjects[1].password, "pb");

// 2. A wrapped array, and the "email"/"pass" spellings a hand-written file tends to use.
const wrapped = parseUsers('{"users":[{"email":"c@example.com","pass":"pc"}]}');
assert.equal(wrapped.length, 1);
assert.equal(wrapped[0].username, "c@example.com");
assert.equal(wrapped[0].password, "pc");

// 3. "username:password" strings, which is what an env-file style list looks like. The
//    password may contain a colon, so the split has to be on the FIRST one only.
const fromStrings = parseUsers('["d@example.com:pd:with:colons"]');
assert.equal(fromStrings[0].username, "d@example.com");
assert.equal(fromStrings[0].password, "pd:with:colons");

// 4. A string entry that is not "username:password" must be named, not silently dropped.
assert.throws(
  () => parseUsers('["no-colon-here"]'),
  /users\[0\].*not "username:password"/,
  "a malformed string entry must name itself"
);

// 5. Every problem reported at once: three entries fixed in one pass, not three runs.
assert.throws(
  () => parseUsers('[{"username":"a@example.com"},{"password":"p"},{"note":"nothing"}]'),
  (error) => {
    assert.match(error.message, /3 unusable entries/);
    assert.match(error.message, /users\[0\] \(a@example\.com\) has no password/);
    assert.match(error.message, /users\[1\] has no account name/);
    assert.match(error.message, /users\[2\] has no account name/);
    return true;
  },
  "all bad entries must be reported together"
);

// 6. Duplicates are a copy-paste mistake that silently shrinks the pool.
assert.throws(
  () => parseUsers('[{"username":"a@example.com","password":"p"},{"username":"a@example.com","password":"p"}]'),
  /same account more than once: a@example\.com/,
  "duplicate accounts must be rejected rather than silently pooled"
);

// 7. An empty pool is not the same as no pool: it must fail rather than authenticate nobody.
assert.throws(() => parseUsers("[]"), /is empty/);
assert.throws(() => parseUsers('{"users":[]}'), /is empty/);

// 8. Malformed JSON and wrong top-level shapes name the variable and show the shape wanted.
assert.throws(() => parseUsers("{not json"), /not valid JSON/);
assert.throws(() => parseUsers('"a@example.com"'), /must be a JSON array of accounts/);

// 9. Round robin, stable per VU, and wrapping when there are fewer accounts than VUs.
const pool = parseUsers('[{"username":"a","password":"1"},{"username":"b","password":"2"},{"username":"c","password":"3"}]');
assert.equal(userForVu(pool, 1).index, 0);
assert.equal(userForVu(pool, 3).index, 2);
assert.equal(userForVu(pool, 4).index, 0, "the fourth VU wraps to the first account");
assert.equal(userForVu(pool, 31).index, 0);
// Stability is load-bearing: the token cache is per VU, so a VU that changed account
// mid-run would keep sending the previous account's token.
assert.equal(userForVu(pool, 7).index, userForVu(pool, 7).index);

// 10. Defensive: a missing or nonsensical VU id must not produce an undefined account.
assert.equal(userForVu(pool, 0).index, 0);
assert.equal(userForVu(pool, undefined).index, 0);
assert.equal(userForVu([], 1), null);

// 11. Labels are what ends up on a dashboard: an index, never the account name.
assert.equal(accountLabel(0), "user-01");
assert.equal(accountLabel(9), "user-10");
assert.equal(accountLabel(29), "user-30");
assert.ok(!accountLabel(0).includes("@"), "the label must not leak the account name");

// 12. The assignment line says which account a VU owns, and admits when accounts are shared.
const assignment = describeAssignment(pool, 2, 1);
assert.match(assignment, /VU 2 -> user-02 \(b\)/);
assert.ok(!assignment.includes("shared"));
assert.match(describeAssignment(pool, 9, 2), /fewer accounts than VUs, so accounts are shared/);

console.log("users.test.mjs: all assertions passed");
