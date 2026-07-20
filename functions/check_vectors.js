// Vector-parity check for Trust Score v2 (`npm test`). Runs computeTrust
// (trust.js) against the shared fixtures that also pin the Dart mirror
// (PlatformConfig.trustBreakdownFor), so the two implementations cannot
// drift apart silently. Plain node, no test framework.
const fs = require("fs");
const path = require("path");
const {computeTrust} = require("./trust");

const fixturePath =
    path.join(__dirname, "..", "test", "fixtures", "trust_vectors.json");
const {vectors} = JSON.parse(fs.readFileSync(fixturePath, "utf8"));

let failures = 0;
for (const v of vectors) {
  const actual = computeTrust({
    ratingSum: v.ratingSum,
    ratingCount: v.ratingCount,
    verificationStatus: v.verificationStatus,
    jobsCompleted: v.jobsCompleted,
    disputesLost: v.disputesLost,
    displayName: v.hasDisplayName ? "x" : "",
    phone: v.hasPhone ? "x" : "",
    bio: v.hasBio ? "x" : "",
    profilePhotoUrl: v.hasPhoto ? "x" : "",
    location: v.hasLocation ? "x" : "",
  });
  for (const [key, expected] of Object.entries(v.expected)) {
    if (actual[key] !== expected) {
      console.error(
          `FAIL ${v.name}: ${key} = ${actual[key]}, expected ${expected}`);
      failures++;
    }
  }
}

if (failures > 0) {
  console.error(`${failures} vector assertion(s) failed.`);
  process.exit(1);
}
console.log(`OK — ${vectors.length} trust vectors match.`);
