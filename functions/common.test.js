const assert = require("node:assert");
const test = require("node:test");
const {balanceOf, assertCanPay} = require("./common");

// A stand-in for a Firestore snapshot: only `data()` is used.
const snap = (data) => ({data: () => data});

test("balanceOf: private wallet plus the legacy user-doc field", () => {
  assert.strictEqual(
      balanceOf(snap({walletBalanceSen: 700}), {walletBalanceSen: 300}), 1000);
});

test("balanceOf: missing docs and fields count as 0", () => {
  assert.strictEqual(balanceOf(snap(undefined), undefined), 0);
  assert.strictEqual(balanceOf(undefined, {}), 0);
  assert.strictEqual(balanceOf(snap({}), {walletBalanceSen: 250}), 250);
  assert.strictEqual(balanceOf(snap({walletBalanceSen: 400}), {}), 400);
});

test("balanceOf: a negative private wallet is offset by the legacy balance", () => {
  assert.strictEqual(
      balanceOf(snap({walletBalanceSen: -300}), {walletBalanceSen: 1000}), 700);
});

test("assertCanPay: uses the combined balance and ignores legacy escrowLockedSen", () => {
  const wallet = snap({walletBalanceSen: 500});
  const user = {walletBalanceSen: 500, escrowLockedSen: 200};
  assertCanPay(wallet, user, 1000, "short");
  assert.throws(() => assertCanPay(wallet, user, 1001, "short"), (err) =>
    err.code === "failed-precondition" &&
    err.details.reason === "insufficient_balance" &&
    err.details.availableSen === 1000 &&
    err.details.shortfallSen === 1);
});

test("assertCanPay: empty wallet and user fail with 0 available", () => {
  assert.throws(() => assertCanPay(snap(undefined), undefined, 1, "short"),
      (err) => err.details.availableSen === 0);
});

const {callerUid, assertTwoFactor} = require("./common");
const admin = require("firebase-admin");

test("callerUid: signed out is unauthenticated", () => {
  assert.throws(() => callerUid({}), (err) => err.code === "unauthenticated");
});

test("callerUid: an unverified email is rejected", () => {
  const context = {auth: {uid: "u1", token: {email_verified: false}}};
  assert.throws(() => callerUid(context),
      (err) => err.code === "failed-precondition");
});

test("callerUid: a verified email returns the uid", () => {
  const context = {auth: {uid: "u1", token: {email_verified: true}}};
  assert.strictEqual(callerUid(context), "u1");
});

test("assertTwoFactor: providers and admins need an enrolled factor", async (t) => {
  let factors = [];
  // `admin.auth` is a getter returning the auth() function.
  t.mock.getter(admin, "auth", () => () => ({
    getUser: () => Promise.resolve({multiFactor: {enrolledFactors: factors}}),
  }));
  await assert.rejects(assertTwoFactor("u1", "provider"),
      (err) => err.code === "failed-precondition");
  await assert.rejects(assertTwoFactor("u1", "admin"),
      (err) => err.code === "failed-precondition");
  factors = [{uid: "f1", factorId: "totp"}];
  await assertTwoFactor("u1", "provider");
  await assertTwoFactor("u1", "admin");
});

test("assertTwoFactor: requestors pass without a lookup", async (t) => {
  const auth = t.mock.getter(admin, "auth", () => () => ({}));
  await assertTwoFactor("u1", "requestor");
  assert.strictEqual(auth.mock.callCount(), 0);
});
