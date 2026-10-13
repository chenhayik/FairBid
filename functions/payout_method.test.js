const assert = require("node:assert");
const test = require("node:test");
const {
  normaliseMobile,
  checkBankAccount,
  buildPayoutMethod,
} = require("./payout_method");

const INVALID = {code: "invalid-argument"};

const profile = {
  phone: "+60 12-345 6789",
  ssmNumber: "202301012345",
  isBusiness: false,
};

test("mobile numbers are normalised to 01X form", () => {
  assert.strictEqual(normaliseMobile("+60 12-345 6789"), "0123456789");
  assert.strictEqual(normaliseMobile("011-2345 6789"), "01123456789");
  assert.strictEqual(normaliseMobile("03-1234 5678"), null); // a landline
  assert.strictEqual(normaliseMobile(""), null);
});

test("bank accounts must match the bank's length", () => {
  assert.strictEqual(
      checkBankAccount("MBBEMYKL", "512345678901").last4, "8901");
  assert.throws(() => checkBankAccount("MBBEMYKL", "12345"), INVALID); // Maybank is 12
  assert.throws(() => checkBankAccount("MBBEMYKL", "5123-4567-8901"), INVALID); // not digits
  assert.throws(() => checkBankAccount("NOTABANK", "512345678901"), INVALID);
  // A bank with no known length takes 8 to 17 digits.
  checkBankAccount("ARBKMYKL", "12345678");
  assert.throws(() => checkBankAccount("ARBKMYKL", "1234567"), INVALID);
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
  assert.throws(() => buildPayoutMethod({method: "duitnow", proxyType: "mobile"},
      {...profile, phone: ""}), INVALID);
});

test("SSM IDs are for business providers only", () => {
  assert.throws(() => buildPayoutMethod({method: "duitnow", proxyType: "brn"},
      profile), INVALID);
  assert.strictEqual(
      buildPayoutMethod({method: "duitnow", proxyType: "brn"},
          {...profile, isBusiness: true}).masked,
      "DuitNow SSM •••• 2345");
});

test("MyKad is no longer offered", () => {
  assert.throws(() => buildPayoutMethod({method: "duitnow", proxyType: "mykad"},
      profile), INVALID);
});

test("an unknown method or ID type is refused", () => {
  assert.throws(() => buildPayoutMethod({method: "cash"}, profile), INVALID);
  assert.throws(() => buildPayoutMethod({method: "duitnow", proxyType: "qr"},
      profile), INVALID);
});
