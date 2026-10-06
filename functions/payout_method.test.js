const assert = require("node:assert");
const {
  normaliseMobile,
  checkBankAccount,
  buildPayoutMethod,
} = require("./payout_method");

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

/** Asserts [fn] throws the callable's `invalid-argument` error. */
function rejects(fn) {
  assert.throws(fn, (err) => err.code === "invalid-argument");
}

const profile = {
  phone: "+60 12-345 6789",
  ssmNumber: "202301012345",
  isBusiness: false,
};

console.log("payout_method.js");

test("mobile numbers are normalised to 01X form", () => {
  assert.strictEqual(normaliseMobile("+60 12-345 6789"), "0123456789");
  assert.strictEqual(normaliseMobile("011-2345 6789"), "01123456789");
  assert.strictEqual(normaliseMobile("03-1234 5678"), null); // a landline
  assert.strictEqual(normaliseMobile(""), null);
});

test("bank accounts must match the bank's length", () => {
  assert.strictEqual(
      checkBankAccount("MBBEMYKL", "512345678901").last4, "8901");
  rejects(() => checkBankAccount("MBBEMYKL", "12345")); // Maybank is 12
  rejects(() => checkBankAccount("MBBEMYKL", "5123-4567-8901")); // not digits
  rejects(() => checkBankAccount("NOTABANK", "512345678901"));
  // A bank with no known length takes 8 to 17 digits.
  checkBankAccount("ARBKMYKL", "12345678");
  rejects(() => checkBankAccount("ARBKMYKL", "1234567"));
});

test("a bank method is masked to its last 4 digits", () => {
  const m = buildPayoutMethod(
      {method: "bank", bankSwift: "MBBEMYKL", accountNumber: "512345678901"},
      profile);
  assert.deepStrictEqual(m, {
    method: "bank",
    proxyType: null,
    bankName: "Maybank",
    bankSwift: "MBBEMYKL",
    masked: "Maybank •••• 8901",
  });
});

test("a DuitNow mobile ID always uses the profile phone", () => {
  const m = buildPayoutMethod(
      {method: "duitnow", proxyType: "mobile", mobile: "0199999999"},
      profile);
  assert.strictEqual(m.masked, "DuitNow 012-•••• 789"); // not 019...
  assert.strictEqual(m.mobile, "0123456789");
  rejects(() => buildPayoutMethod({method: "duitnow", proxyType: "mobile"},
      {...profile, phone: ""}));
});

test("SSM IDs are for business providers only", () => {
  rejects(() => buildPayoutMethod({method: "duitnow", proxyType: "brn"},
      profile));
  assert.strictEqual(
      buildPayoutMethod({method: "duitnow", proxyType: "brn"},
          {...profile, isBusiness: true}).masked,
      "DuitNow SSM •••• 2345");
});

test("MyKad is no longer offered", () => {
  rejects(() => buildPayoutMethod({method: "duitnow", proxyType: "mykad"},
      profile));
});

test("an unknown method or ID type is refused", () => {
  rejects(() => buildPayoutMethod({method: "cash"}, profile));
  rejects(() => buildPayoutMethod({method: "duitnow", proxyType: "qr"},
      profile));
});

if (failed > 0) {
  console.log(`\n${failed} payout method test(s) failed.`);
  process.exit(1);
}
console.log("All payout method tests passed.\n");
