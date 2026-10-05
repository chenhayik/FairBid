/** Unit tests for the pure helpers in idcheck.js. Run with `npm test`. */

const assert = require("node:assert");
const {verdictFor, icKey} = require("./idcheck");

assert.strictEqual(verdictFor([]), "passed");
assert.strictEqual(verdictFor(["name-mismatch"]), "needsReview");
assert.strictEqual(
    verdictFor(["name-mismatch", "unknown-pb-code", "ocr-failed"]),
    "needsReview");
assert.strictEqual(verdictFor(["passport-not-automated"]), "needsReview");
for (const hard of ["not-an-image", "no-ic-found", "invalid-ic", "underage",
  "ic-mismatch", "duplicate-ic"]) {
  assert.strictEqual(verdictFor(["name-mismatch", hard]), "rejected", hard);
}

const key = icKey("900101-07-1234", "pepper");
assert.match(key, /^[0-9a-f]{64}$/);
assert.strictEqual(icKey("900101071234", "pepper"), key); // normalised
assert.notStrictEqual(icKey("900101071234", "other"), key);
assert.notStrictEqual(icKey("900101071235", "pepper"), key);

console.log("All ID check tests passed.\n");
