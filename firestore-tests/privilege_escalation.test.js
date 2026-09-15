/**
 * F1 - Privilege escalation via the self-writable `role` field.
 *
 * The `users/{userId}` update rule (firestore.rules:68) forbids a client from
 * touching the Trust Score, wallet and suspension fields - but NOT `role` or
 * `verificationStatus`. Since `isAdmin()` (firestore.rules:17), the Storage
 * rules' `isAdmin()` and the Cloud Functions' `assertAdmin()`
 * (functions/index.js:240) all read `users/{uid}.role`, a client that can
 * write that field owns the admin role outright.
 *
 * Run (from this directory):
 *   npx firebase-tools emulators:exec --only firestore "npx mocha privilege_escalation.test.js --timeout 20000"
 */

const fs = require("fs");
const path = require("path");
const assert = require("assert");
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const {doc, setDoc, updateDoc, getDoc} = require("firebase/firestore");

const RULES_PATH = path.resolve(__dirname, "../firestore.rules");

/** @type {import("@firebase/rules-unit-testing").RulesTestEnvironment} */
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "fairbid-escalation-test",
    firestore: {rules: fs.readFileSync(RULES_PATH, "utf8")},
  });
});

after(async () => {
  if (testEnv) await testEnv.cleanup();
});

afterEach(async () => {
  await testEnv.clearFirestore();
});

async function seed(docs) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    for (const [p, data] of docs) await setDoc(doc(db, p), data);
  });
}

const dbAs = (uid) => testEnv.authenticatedContext(uid).firestore();

/** Attempt an operation; report whether the rules ALLOWED it, never throws. */
async function allowed(op) {
  try {
    await op;
    return true;
  } catch (e) {
    return false;
  }
}

describe("F1 - privilege escalation via self-writable role", () => {
  const ATTACKER = "attacker1";
  const VICTIM = "victim1";

  beforeEach(async () => {
    await seed([
      [`users/${ATTACKER}`, {
        role: "requestor",
        displayName: "Mallory",
        verificationStatus: "none",
        walletBalanceSen: 0,
      }],
      [`users/${VICTIM}`, {
        role: "provider",
        displayName: "Victim",
        verificationStatus: "approved",
        walletBalanceSen: 250000,
      }],
      // The private sub-doc: payout bank details + phone, owner+admin only.
      [`users/${VICTIM}/private/payout`, {
        bankName: "Maybank",
        accountHolder: "VICTIM BIN VICTIM",
        accountLast4: "4821",
        branchCode: "MBBEMYKL",
        phone: "+60123456789",
      }],
    ]);
  });

  it("PROOF: unprivileged user escalates to admin and reads a victim's bank details", async () => {
    const attacker = dbAs(ATTACKER);
    const victimPayout = doc(attacker, `users/${VICTIM}/private/payout`);

    // Step 1 - baseline: the attacker must NOT be able to read payout data.
    const before = await allowed(getDoc(victimPayout));

    // Step 2 - the hole: write role:"admin" onto the attacker's own profile.
    const escalated = await allowed(
        updateDoc(doc(attacker, `users/${ATTACKER}`), {role: "admin"}),
    );

    // Step 3 - impact: retry the exact read that was denied in step 1.
    let after = false;
    let stolen = null;
    try {
      const snap = await getDoc(victimPayout);
      after = true;
      stolen = snap.data();
    } catch (e) {
      after = false;
    }

    // Step 4 - the same gap self-approves provider verification (KYC bypass).
    const selfApproved = await allowed(
        updateDoc(doc(attacker, `users/${ATTACKER}`),
            {verificationStatus: "approved"}),
    );

    console.log("\n  ---------- F1 proof-of-concept ----------");
    console.log(`  1. read victim payout as plain requestor : ${before ? "ALLOWED" : "DENIED (correct)"}`);
    console.log(`  2. write own role = "admin"              : ${escalated ? "ALLOWED  <-- VULNERABILITY" : "DENIED (correct)"}`);
    console.log(`  3. read victim payout as self-made admin : ${after ? "ALLOWED  <-- PII DISCLOSED" : "DENIED (correct)"}`);
    console.log(`  4. self-approve verificationStatus       : ${selfApproved ? "ALLOWED  <-- KYC BYPASS" : "DENIED (correct)"}`);
    if (stolen) {
      console.log(`  Exfiltrated: ${stolen.accountHolder} / ${stolen.bankName} ` +
                  `****${stolen.accountLast4} / ${stolen.phone}`);
    }
    console.log("  -----------------------------------------\n");

    assert.strictEqual(before, false,
        "payout must be unreadable by a non-admin");
    assert.strictEqual(escalated, false,
        "a user must not be able to write their own role");
    assert.strictEqual(after, false,
        "payout must stay unreadable - no escalation path");
    assert.strictEqual(selfApproved, false,
        "a user must not be able to approve their own verification");
  });

  // ---- Regression tests: these FAIL today and PASS once the rule is fixed. --
  it("REGRESSION: must deny a user promoting their own role to admin",
      async () => {
        const attacker = dbAs(ATTACKER);
        await assertFails(
            updateDoc(doc(attacker, `users/${ATTACKER}`), {role: "admin"}));
      });

  it("REGRESSION: must deny a user self-approving verificationStatus",
      async () => {
        const attacker = dbAs(ATTACKER);
        await assertFails(updateDoc(doc(attacker, `users/${ATTACKER}`),
            {verificationStatus: "approved"}));
      });

  it("REGRESSION: must deny claiming role admin at profile creation",
      async () => {
        const fresh = dbAs("newcomer1");
        await assertFails(setDoc(doc(fresh, "users/newcomer1"), {
          role: "admin",
          displayName: "New",
          walletBalanceSen: 0,
        }));
      });

  it("still allows a legitimate profile edit (displayName)", async () => {
    const attacker = dbAs(ATTACKER);
    await assertSucceeds(updateDoc(doc(attacker, `users/${ATTACKER}`),
        {displayName: "Mallory Updated"}));
  });

  // The fix must not break the two real onboarding flows, which submit for
  // review by writing verificationStatus: 'pending' from the client
  // (onboarding_repository.dart:106, requestor_onboarding_repository.dart:91).
  it("still allows submitting for review (verificationStatus -> pending)",
      async () => {
        const attacker = dbAs(ATTACKER);
        await assertSucceeds(updateDoc(doc(attacker, `users/${ATTACKER}`), {
          verificationStatus: "pending",
          displayName: "Mallory",
          onboarding: {step: "done"},
        }));
      });

  it("still allows a normal sign-up to create its own profile", async () => {
    const fresh = dbAs("newcomer2");
    await assertSucceeds(setDoc(doc(fresh, "users/newcomer2"), {
      role: "provider",
      displayName: "New Provider",
      email: "new@example.com",
      walletBalanceSen: 0,
      verificationStatus: "none",
      onboardingComplete: false,
    }));
  });
});
