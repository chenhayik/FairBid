/**
 * Unit tests for the SSM parsers in ssm.js.
 *
 * These cover the one property the whole privacy design rests on: that reading
 * a Business Profile cannot surface the owner's NRIC, date of birth, race,
 * gender or residential address. That guarantee is enforced by a text split on
 * the owner-section heading, which is worth pinning precisely because it is
 * heading-dependent rather than structural.
 *
 * Plain node:assert - the functions directory has no test framework, and these
 * need none. Run with `npm test`.
 */

const assert = require("node:assert");
const {
  parseSsmText, parseOwnerName, namesMatch, parseDate, canonical,
} = require("./ssm");

/** A Business Profile reduced to the shape that matters, owner block included. */
const PROFILE = [
  "NAME                         BUSINESS INFORMATION",
  "REGISTRATION NO.",
  "PRINCIPLE PLACE OF BUSINESS   : SUNMAL DENTAL ART",
  "                              : 200803090077 (SA0085324-V)",
  "BUSINESS OWNERSHIP            : 4B, SS 26/6, TMN MAYANG JAYA",
  "BUSINESS START DATE",
  "REGISTRATION DATE                47301, PETALING JAYA",
  "BUSINESS EXPIRY DATE             SELANGOR",
  "LAST AMENDMENT DATE           : SOLE PROPRIETORSHIP",
  "STATUS                        : 05-05-2008",
  "                              : 06-05-2008",
  "                              : 08-10-2020",
  "                              : 28-01-2016",
  "                              : ACTIVE",
  "                                    BUSINESS TYPE",
  "PERKHIDMATAN PERGIGIAN & KESIHATAN",
  "NAME                  INFORMATION OF CURRENT OWNER",
  "RESIDENTIAL ADDRESS",
  "                          : TAN XIAO-IAN",
  "IC (NEW)                  : 12, JALAN SS 22/47A, DAMANSARA JAYA",
  "DATE OF BIRTH                47400, PETALING JAYA",
  "RACE                      : 920330105027",
  "GENDER                    : 30-03-1992",
  "                          : CHINESE",
  "                          : MALE",
].join("\n");

const CERTIFICATE = [
  "CERTIFICATE OF REGISTRATION",
  "This is to certify that the Business carried on under the name",
  "      JIN XIAO LONG TRADING",
  "REGISTRATION NO. : 201903350205 (003058656-T)",
  "has this day been registered until 22 JANUARY in accordance with",
].join("\n");

let failed = 0;
function test(name, fn) {
  try {
    fn();
    console.log(`  ok  ${name}`);
  } catch (err) {
    failed++;
    console.log(`  FAIL  ${name}\n        ${err.message}`);
  }
}

console.log("ssm.js parsers");

test("reads a Business Profile's business fields", () => {
  const out = parseSsmText(PROFILE);
  assert.strictEqual(out.businessName, "SUNMAL DENTAL ART");
  assert.strictEqual(out.registrationNumber, "200803090077");
  assert.strictEqual(out.legacyNumber, "SA0085324-V");
  assert.strictEqual(out.entityStatus, "ACTIVE");
  assert.strictEqual(out.ownership, "SOLE PROPRIETORSHIP");
  assert.strictEqual(out.natureOfBusiness, "PERKHIDMATAN PERGIGIAN & KESIHATAN");
  assert.strictEqual(out.expiryDate, "2020-10-08");
  assert.strictEqual(out.businessStartDate, "2008-05-05");
});

test("no owner personal data can reach any parsed field", () => {
  const values = Object.values(parseSsmText(PROFILE))
      .filter((v) => typeof v === "string").join(" | ").toUpperCase();
  for (const secret of [
    "TAN XIAO-IAN", // owner name
    "920330105027", // NRIC
    "30-03-1992", // date of birth
    "CHINESE", // race
    "MALE", // gender
    "DAMANSARA JAYA", // residential address
  ]) {
    assert.ok(!values.includes(secret.toUpperCase()),
        `leaked ${secret} into parsed output: ${values}`);
  }
});

test("owner dates cannot be mistaken for business dates", () => {
  // The owner block holds 30-03-1992; only the business block's dates count.
  const out = parseSsmText(PROFILE);
  assert.strictEqual(out.businessStartDate, "2008-05-05");
  assert.notStrictEqual(out.expiryDate, "1992-03-30");
});

test("a PREVIOUS OWNER section is excluded too", () => {
  const withPrevious = PROFILE.replace(
      "INFORMATION OF CURRENT OWNER", "INFORMATION OF PREVIOUS OWNER");
  const values = Object.values(parseSsmText(withPrevious))
      .filter((v) => typeof v === "string").join(" | ");
  assert.ok(!values.includes("920330105027"), "leaked a previous owner's NRIC");
});

test("reads a Certificate, which names no owner", () => {
  const out = parseSsmText(CERTIFICATE);
  assert.strictEqual(out.businessName, "JIN XIAO LONG TRADING");
  assert.strictEqual(out.registrationNumber, "201903350205");
  assert.strictEqual(parseOwnerName(CERTIFICATE), null);
});

test("the Registrar's name is never taken as the owner", () => {
  const signed = `${CERTIFICATE}\n      DATUK NOR AZIMAH ABDUL AZIZ\n` +
      "      REGISTRAR OF BUSINESSES";
  assert.strictEqual(parseOwnerName(signed), null);
});

test("finds the owner name on a Profile", () => {
  assert.strictEqual(parseOwnerName(PROFILE), "TAN XIAO-IAN");
});

test("name matching tolerates punctuation and word order", () => {
  assert.strictEqual(namesMatch("TAN XIAO-IAN", "Tan Xiao Ian"), true);
  assert.strictEqual(namesMatch("TAN XIAO-IAN", "Ahmad bin Bakar"), false);
  // Neither side usable - "cannot tell" must stay distinct from "no".
  assert.strictEqual(namesMatch("TAN XIAO-IAN", ""), null);
  assert.strictEqual(namesMatch(null, "Tan Xiao Ian"), null);
});

test("a date with no year is refused rather than guessed", () => {
  assert.strictEqual(parseDate("22 JANUARY"), null);
  assert.strictEqual(parseDate("22 JANUARY 2027"), "2027-01-22");
  assert.strictEqual(parseDate("08-10-2020"), "2020-10-08");
  assert.strictEqual(parseDate("32-13-2020"), null);
});

test("canonical form matches the Dart client's", () => {
  assert.strictEqual(canonical("sa 0085324 - v"), "SA0085324V");
  assert.strictEqual(canonical("201903350205"), "201903350205");
  assert.strictEqual(canonical(null), "");
});

if (failed > 0) {
  console.log(`\n${failed} SSM parser test(s) failed.`);
  process.exit(1);
}
console.log("All SSM parser tests passed.\n");
