// Driven by the vector file the Dart client also reads (test/mykad_number_test.dart).

const assert = require("node:assert");
const test = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const {
  validateIc, normalizeIc, maskIc, todayInKl, parseMyKadText,
} = require("./mykad");

const fixture = JSON.parse(fs.readFileSync(
    path.join(__dirname, "..", "test", "fixtures", "mykad_vectors.json"),
    "utf8"));

for (const v of fixture.vectors) {
  test(v.name, () => {
    const out = validateIc(v.input, fixture.today);
    assert.deepStrictEqual(out.issues, v.issues);
    assert.strictEqual(out.ok, v.issues.length === 0);
    if (v.issues.length === 0) {
      assert.strictEqual(out.normalized, v.normalized);
      assert.strictEqual(out.masked, v.masked);
      assert.strictEqual(out.dob, v.dob);
      assert.strictEqual(out.isMale, v.isMale);
      assert.strictEqual(out.pbNeedsReview, v.pbNeedsReview);
    }
  });
}

test("normalizeIc and maskIc", () => {
  assert.strictEqual(normalizeIc("900101-07-1234"), "900101071234");
  assert.strictEqual(normalizeIc(null), "");
  assert.strictEqual(maskIc("900101-07-1234"), "******-07-**34");
  assert.strictEqual(maskIc("123"), "");
});

test("todayInKl rolls over at 16:00 UTC", () => {
  assert.strictEqual(todayInKl(new Date("2026-09-30T15:59:00Z")), "2026-09-30");
  assert.strictEqual(todayInKl(new Date("2026-09-30T16:00:00Z")), "2026-10-01");
});

const CARD = (ic, name, gender) => [
  "KAD PENGENALAN", "MALAYSIA", "MyKad", ic, ...name,
  "NO 12 JALAN MAWAR", "TAMAN BUNGA", "47301 PETALING JAYA", "SELANGOR",
  "WARGANEGARA", "ISLAM", gender,
].join("\n");

test("parseMyKadText: single-line name, male", () => {
  const p = parseMyKadText(CARD("900101-07-1234", ["AHMAD BIN ALI"], "LELAKI"));
  assert.deepStrictEqual(p, {icNumber: "900101071234", name: "AHMAD BIN ALI",
    gender: "male", hasMarkers: true});
});

test("parseMyKadText: two-line name, female", () => {
  const p = parseMyKadText(
      CARD("950505-14-5678", ["NUR AISYAH", "BINTI ABDUL RAHMAN"], "PEREMPUAN"));
  assert.strictEqual(p.name, "NUR AISYAH BINTI ABDUL RAHMAN");
  assert.strictEqual(p.gender, "female");
});

test("parseMyKadText: dashes missing or spaced", () => {
  const a = parseMyKadText(CARD("900101071234", ["TAN A/L LEE"], "LELAKI"));
  const b = parseMyKadText(CARD("900101 07 1234", ["LIM @ LEE"], "LELAKI"));
  assert.strictEqual(a.icNumber, "900101071234");
  assert.strictEqual(b.icNumber, "900101071234");
  assert.strictEqual(b.name, "LIM @ LEE");
});

test("parseMyKadText: no IC / not a MyKad", () => {
  const p = parseMyKadText("Hello world\nInvoice 2026\nTotal RM 12.00");
  assert.deepStrictEqual(p, {icNumber: null, name: null, gender: null,
    hasMarkers: false});
});

test("parseMyKadText: address words without digits never join the name", () => {
  const one = parseMyKadText(["900101-07-1234", "AHMAD BIN ALI",
    "JALAN MAWAR", "TAMAN INDAH", "ISLAM", "LELAKI"].join("\n"));
  assert.strictEqual(one.name, "AHMAD BIN ALI");
  const two = parseMyKadText(["900101-07-1234", "NUR AISYAH",
    "BINTI ABDUL RAHMAN", "KG BARU", "WARGANEGARA"].join("\n"));
  assert.strictEqual(two.name, "NUR AISYAH BINTI ABDUL RAHMAN");
  // A two-line name is cut at an address line, not extended by it.
  const cut = parseMyKadText(["900101-07-1234", "NUR AISYAH",
    "TAMAN INDAH"].join("\n"));
  assert.strictEqual(cut.name, "NUR AISYAH");
  for (const w of ["JALAN", "TAMAN", "KG", "ISLAM"]) {
    for (const p of [one, two, cut]) assert.ok(!p.name.includes(w), w);
  }
});

test("parseMyKadText: lowercase OCR noise before the name is skipped", () => {
  const p = parseMyKadText(["KAD PENGENALAN", "900101-07-1234", "some noise",
    "SITI BINTI ABU", "NO 5 JALAN X", "LELAKI"].join("\n"));
  assert.strictEqual(p.name, "SITI BINTI ABU");
});

test("parseMyKadText: SEKSYEN, BANDAR and PEKAN end the name", () => {
  for (const w of ["SEKSYEN UTAMA", "BANDAR BARU", "PEKAN LAMA"]) {
    const p = parseMyKadText(["900101-07-1234", "AHMAD BIN ALI", w].join("\n"));
    assert.strictEqual(p.name, "AHMAD BIN ALI", w);
  }
});

test("parseMyKadText: a religion word in a name is kept", () => {
  const p = parseMyKadText(CARD("900101-07-1234", ["SAIFUL ISLAM BIN ALI"],
      "LELAKI"));
  assert.strictEqual(p.name, "SAIFUL ISLAM BIN ALI");
  // On a line of its own it still ends the name.
  const q = parseMyKadText(["900101-07-1234", "NUR AISYAH", "HINDU"].join("\n"));
  assert.strictEqual(q.name, "NUR AISYAH");
});
