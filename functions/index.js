const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");

admin.initializeApp();

/**
 * When an Auth account is deleted, remove its Firestore profile.
 * Auth triggers are 1st-gen only, so this uses firebase-functions/v1.
 */
exports.cleanupUserDoc = functions.auth.user().onDelete(async (user) => {
  const db = admin.firestore();
  const ref = db.doc(`users/${user.uid}`);
  // If the read fails, assume suspended: keeping the IC reserved is safer.
  let suspended = true;
  try {
    suspended = (await ref.get()).get("suspended") === true;
  } catch (_err) {
    functions.logger.warn("suspended read failed", {uid: user.uid});
  }
  await db.recursiveDelete(ref);
  // Best-effort: leftover ID photos, and the IC reservation unless banned.
  try {
    const [files] = await admin.storage().bucket()
        .getFiles({prefix: `verification/${user.uid}/`});
    await Promise.all(files.map((f) => f.delete({ignoreNotFound: true})));
    if (!suspended) {
      const reg = await db.collection("idRegistry")
          .where("uid", "==", user.uid).get();
      await Promise.all(reg.docs.map((d) => d.ref.delete()));
    }
  } catch (_err) {
    functions.logger.warn("verification cleanup failed", {uid: user.uid});
  }
  functions.logger.info(`Deleted Firestore profile for ${user.uid}`);
});

// Trust Score. The math is in trust.js; only the consumer below
// writes the score.

const {computeTrust} = require("./trust");

/**
 * Recomputes a user's trust breakdown whenever the user doc is written.
 * It skips the write if nothing changed, which stops a trigger loop.
 */
exports.recomputeTrustOnUserWrite = functions.firestore
    .document("users/{uid}")
    .onWrite(async (change) => {
      if (!change.after.exists) return; // deletion - nothing to score
      const user = change.after.data();
      const trust = computeTrust(user);

      const stored = user.trust || {};
      const unchanged = user.trustScore === trust.composite &&
          ["reviewScore", "trackRecordScore", "verificationScore",
            "profileScore", "scoreVisible"]
              .every((key) => stored[key] === trust[key]);
      if (unchanged) return;

      await change.after.ref.update({
        trustScore: trust.composite,
        trust: {
          ...trust,
          computedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
      });
    });

/**
 * A new review adds its rating to the reviewee's totals (server-side).
 * A `countedInTrust` flag on the review stops retries counting twice.
 */
exports.recomputeTrustScore = functions.firestore
    .document("users/{revieweeId}/reviews/{reviewId}")
    .onCreate(async (snapshot, context) => {
      const revieweeId = context.params.revieweeId;
      const rating = snapshot.data().rating;
      const userRef = admin.firestore().doc(`users/${revieweeId}`);
      const reviewRef = snapshot.ref;

      await admin.firestore().runTransaction(async (tx) => {
        // All reads before any writes.
        const [userSnap, reviewSnap] = await Promise.all([
          tx.get(userRef),
          tx.get(reviewRef),
        ]);
        if (reviewSnap.data()?.countedInTrust === true) return; // retried event
        const data = userSnap.data() || {};
        tx.update(userRef, {
          ratingSum: (data.ratingSum || 0) + rating,
          ratingCount: (data.ratingCount || 0) + 1,
        });
        tx.update(reviewRef, {countedInTrust: true});
      });
    });

const {uidsToCount} = require("./bundles");

/**
 * When a job completes, both people get +1 completed job.
 * A bundle counts once per person; `completionCounted` blocks retries.
 */
exports.onJobCompleted = functions.firestore
    .document("jobs/{jobId}")
    .onUpdate(async (change) => {
      const before = change.before.data();
      const after = change.after.data();
      if (before.status === "completed" || after.status !== "completed") {
        return;
      }
      const db = admin.firestore();
      const jobRef = change.after.ref;
      const participants =
          [after.acceptedProviderId, after.requestorId].filter(Boolean);
      const bundleId = after.bundleId;
      const markerRefs = bundleId ?
          participants.map((uid) =>
              db.doc(`bundles/${bundleId}/completionCounts/${uid}`)) :
          [];

      await db.runTransaction(async (tx) => {
        // All reads before any writes.
        const [jobSnap, ...markerSnaps] =
            await tx.getAll(jobRef, ...markerRefs);
        if (jobSnap.data()?.completionCounted === true) return; // retried event

        const alreadyCounted = bundleId ?
            participants.filter((uid, i) => markerSnaps[i].exists) :
            [];
        const bump = {
          jobsCompleted: admin.firestore.FieldValue.increment(1),
        };
        uidsToCount(participants, alreadyCounted).forEach((uid) => {
          tx.update(db.doc(`users/${uid}`), bump);
          if (bundleId) {
            tx.set(db.doc(`bundles/${bundleId}/completionCounts/${uid}`), {
              jobId: jobRef.id,
              at: admin.firestore.FieldValue.serverTimestamp(),
            });
          }
        });
        tx.update(jobRef, {completionCounted: true});
      });
    });

// Requestor counters (jobsPosted, hireRate), written only by the server.

/**
 * Adds the deltas to a user's job counters and recalculates `hireRate`.
 * With no jobs posted, `hireRate` is removed instead of showing 0%.
 */
async function bumpRequestorCounters(uid, {postedDelta = 0, assignedDelta = 0}) {
  const db = admin.firestore();
  const ref = db.doc(`users/${uid}`);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return; // defensive: shouldn't happen in practice
    const data = snap.data() || {};
    const jobsPosted = (data.jobsPosted || 0) + postedDelta;
    const jobsAssigned = (data.jobsAssigned || 0) + assignedDelta;
    tx.update(ref, {
      jobsPosted,
      jobsAssigned,
      hireRate: jobsPosted > 0 ?
          Math.round((jobsAssigned / jobsPosted) * 100) :
          admin.firestore.FieldValue.delete(),
    });
  });
}

/** Adds 1 to the requestor's `jobsPosted` when a job is created. */
exports.bumpJobsPostedOnCreate = functions.firestore
    .document("jobs/{jobId}")
    .onCreate(async (snap) => {
      const requestorId = snap.data()?.requestorId;
      if (!requestorId) return;
      await bumpRequestorCounters(requestorId, {postedDelta: 1});
    });

/** Adds 1 to the requestor's `jobsAssigned` when a bid is accepted. */
exports.bumpJobsAssignedOnAccept = functions.firestore
    .document("jobs/{jobId}")
    .onUpdate(async (change) => {
      const before = change.before.data();
      const after = change.after.data();
      if (before.status !== "open" || after.status !== "in_progress") return;
      if (!after.requestorId) return;
      await bumpRequestorCounters(after.requestorId, {assignedDelta: 1});
    });

// Wallet and escrow. Clients can't write money fields, so only these
// callables (using the admin SDK) move money.

const {ESCROW, appendLedger, writeFundedMilestone} = require("./common");
const {normaliseMobile} = require("./payout_method");

/** Rejects unauthenticated calls; returns the caller's uid. */
function callerUid(context) {
  if (!context.auth) {
    throw new functions.https.HttpsError(
        "unauthenticated", "You must be signed in.");
  }
  return context.auth.uid;
}

/** Validates a client-supplied sen amount. */
function checkAmount(amountSen) {
  if (!Number.isInteger(amountSen) || amountSen <= 0) {
    throw new functions.https.HttpsError(
        "invalid-argument", "Enter a valid amount.");
  }
  return amountSen;
}

/** Validates a client-supplied document id. */
function checkId(value, name) {
  if (typeof value !== "string" || value === "") {
    throw new functions.https.HttpsError(
        "invalid-argument", `Missing ${name}.`);
  }
  return value;
}

/** Throws unless `users/{uid}` has role 'admin'. Read inside [tx]. */
async function assertAdmin(tx, db, uid) {
  const snap = await tx.get(db.doc(`users/${uid}`));
  if (snap.data()?.role !== "admin") {
    throw new functions.https.HttpsError(
        "permission-denied", "Only an admin can do this.");
  }
}

/**
 * Throws if the user is suspended. Read inside [tx], before any writes.
 * Suspended users can read, but can't take money or work actions.
 */
async function assertNotSuspended(tx, db, uid) {
  const snap = await tx.get(db.doc(`users/${uid}`));
  if (snap.data()?.suspended === true) {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Your account is suspended. Contact support if you think this is " +
        "a mistake.");
  }
}

const {completesJob} = require("./price_change");

/** Turns a milestones query snapshot into rows for [completesJob]. */
const milestoneRows = (snap) => snap.docs.map((d) => ({id: d.id, ...d.data()}));

/**
 * Requestor accepts a bid; other pending bids are rejected.
 * The bid amount moves from the wallet into escrow as one funded stage.
 */
exports.acceptBid = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const providerId = checkId(data.providerId, "providerId");
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const bidsRef = jobRef.collection("bids");
  const winnerRef = bidsRef.doc(providerId);
  const walletRef = db.doc(`users/${uid}`);

  // Queries can't run inside a transaction, so fetch pending bid refs first.
  // Each is re-read inside the transaction to stay safe from races.
  const candidates = await bidsRef.where("status", "==", "pending").get();
  const otherRefs = candidates.docs
      .map((d) => d.ref)
      .filter((ref) => ref.id !== providerId);

  await db.runTransaction(async (tx) => {
    await assertNotSuspended(tx, db, uid);
    // All reads before any writes.
    const [jobSnap, winnerSnap, walletSnap, ...otherSnaps] =
        await Promise.all([
          tx.get(jobRef),
          tx.get(winnerRef),
          tx.get(walletRef),
          ...otherRefs.map((ref) => tx.get(ref)),
        ]);
    const job = jobSnap.data();
    if (job?.requestorId !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied", "Only the job's requestor can accept a bid.");
    }
    if (job.status !== "open") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This job is no longer open.",
          {reason: "race"});
    }
    const winner = winnerSnap.data();
    if (winner?.status !== "pending") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This bid is no longer pending.",
          {reason: "race"});
    }
    // Use the stored bid amount, never client input; re-check it before
    // the wallet debit.
    const amount = checkAmount(winner.amountSen);
    const wallet = walletSnap.data() || {};
    const available =
        (wallet.walletBalanceSen || 0) - (wallet.escrowLockedSen || 0);
    if (available < amount) {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "Insufficient available balance to accept this bid.", {
            reason: "insufficient_balance",
            shortfallSen: amount - available,
            availableSen: available,
            requiredSen: amount,
          });
    }

    // Writes.
    tx.update(winnerRef, {status: "accepted"});
    for (let i = 0; i < otherRefs.length; i++) {
      // Skip bids withdrawn or resolved since the pre-fetch.
      if (otherSnaps[i].data()?.status === "pending") {
        tx.update(otherRefs[i], {status: "rejected"});
      }
    }
    // The full price goes into escrow now, so `escrowLockedSen` is unused.
    tx.update(walletRef, {
      walletBalanceSen: (wallet.walletBalanceSen || 0) - amount,
    });
    writeFundedMilestone(tx, {
      jobRef, title: job.title, requestorId: uid, providerId, amountSen: amount,
    });
    tx.update(jobRef, {
      status: "in_progress",
      acceptedProviderId: providerId,
      acceptedProviderName: winner.providerName || null,
      acceptedBidAmountSen: amount,
      originalBidAmountSen: amount,
      fundedAtAward: true,
    });
  });
});

/**
 * Requestor releases a delivered milestone and pays the provider.
 * If it was the last one, the job completes and reviews unlock.
 */
exports.releaseMilestone = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const milestoneId = checkId(data.milestoneId, "milestoneId");
  functions.logger.info("releaseMilestone requested",
      {uid, jobId, milestoneId});
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestoneRef = jobRef.collection("milestones").doc(milestoneId);

  await db.runTransaction(async (tx) => {
    await assertNotSuspended(tx, db, uid);
    const [jobSnap, milestoneSnap, allMilestones] = await Promise.all([
      tx.get(jobRef),
      tx.get(milestoneRef),
      tx.get(jobRef.collection("milestones")),
    ]);
    const job = jobSnap.data();
    if (job?.requestorId !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied",
          "Only the job's requestor can release milestones.");
    }
    if (!job.acceptedProviderId) {
      functions.logger.error(
          "releaseMilestone rejected: no accepted provider",
          {uid, jobId, milestoneId});
      throw new functions.https.HttpsError(
          "failed-precondition", "This job has no accepted provider.");
    }
    if (milestoneSnap.data()?.status !== "submitted") {
      functions.logger.error(
          "releaseMilestone rejected: milestone not submitted",
          {uid, jobId, milestoneId, status: milestoneSnap.data()?.status});
      throw new functions.https.HttpsError(
          "failed-precondition", "This milestone has not been delivered yet.");
    }
    const providerRef = db.doc(`users/${job.acceptedProviderId}`);
    const providerSnap = await tx.get(providerRef);
    const amountSen = milestoneSnap.data().amountSen;

    tx.update(providerRef, {
      walletBalanceSen:
          (providerSnap.data()?.walletBalanceSen || 0) + amountSen,
    });
    tx.update(milestoneRef, {status: "released"});
    const wasLast = completesJob(job, milestoneRows(allMilestones), milestoneId);
    if (wasLast) {
      tx.update(jobRef, {status: "completed"});
    }
    appendLedger(tx, {
      fromUid: ESCROW,
      toUid: job.acceptedProviderId,
      amountSen,
      type: "release",
      jobId,
      jobTitle: job.title || null,
      milestoneId,
      participantIds: [job.acceptedProviderId],
    });
    notify(tx, job.acceptedProviderId, {
      type: "payment",
      title: "Payment released",
      body: `${rm(amountSen)} was released to your wallet for ` +
          `"${job.title}"${wasLast ? ". Job complete!" : "."}`,
      route: `/jobs/${jobId}`,
    });
  });
  functions.logger.info("releaseMilestone released",
      {uid, jobId, milestoneId});
});

// Max per top-up. Keep in sync with PlatformConfig.maxTopUpSen.
const MAX_TOPUP_SEN = 1000000; // RM 10,000

// Max wallet balance, so repeated top-ups can't mint unlimited money.
// Keep in sync with PlatformConfig.maxWalletBalanceSen.
const MAX_WALLET_BALANCE_SEN = 5000000; // RM 50,000

/** True only in the Firebase emulator; deployed functions never set this. */
const isEmulator = () => process.env.FUNCTIONS_EMULATOR === "true";

/**
 * Demo top-up with no real payment, so it only works in the emulator.
 * Real top-ups use toyyibPay. Matches PlatformConfig.demoTopUpEnabled.
 */
exports.topUpWallet = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  if (!isEmulator()) {
    functions.logger.error(
        "topUpWallet rejected: demo top-up is emulator-only", {uid});
    throw new functions.https.HttpsError(
        "failed-precondition",
        "Demo top-up is not available. Please top up with a card or " +
        "online banking.");
  }
  const amountSen = checkAmount(data.amountSen);
  functions.logger.info("topUpWallet requested", {uid, amountSen});
  if (amountSen > MAX_TOPUP_SEN) {
    functions.logger.error("topUpWallet rejected: over per-call cap",
        {uid, amountSen, capSen: MAX_TOPUP_SEN});
    throw new functions.https.HttpsError(
        "invalid-argument", "Top-ups are capped at RM 10,000.");
  }
  const db = admin.firestore();
  const walletRef = db.doc(`users/${uid}`);

  await db.runTransaction(async (tx) => {
    await assertNotSuspended(tx, db, uid);
    const walletSnap = await tx.get(walletRef);
    const balance = walletSnap.data()?.walletBalanceSen || 0;
    if (balance + amountSen > MAX_WALLET_BALANCE_SEN) {
      functions.logger.error("topUpWallet rejected: over wallet cap",
          {uid, amountSen, balance, capSen: MAX_WALLET_BALANCE_SEN});
      throw new functions.https.HttpsError(
          "failed-precondition", "Wallet balance is capped at RM 50,000.");
    }
    tx.update(walletRef, {
      walletBalanceSen: admin.firestore.FieldValue.increment(amountSen),
    });
    appendLedger(tx, {
      fromUid: null,
      toUid: uid,
      amountSen,
      type: "topup",
      participantIds: [uid],
    });
  });
  functions.logger.info("topUpWallet credited", {uid, amountSen});
});

/** Withdraws from the caller's available balance; rejects overdrafts. */
exports.withdrawFromWallet = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const amountSen = checkAmount(data.amountSen);
  functions.logger.info("withdrawFromWallet requested", {uid, amountSen});
  const db = admin.firestore();
  const walletRef = db.doc(`users/${uid}`);

  await db.runTransaction(async (tx) => {
    await assertNotSuspended(tx, db, uid);
    const [walletSnap, methodSnap, payoutSnap] = await Promise.all([
      tx.get(walletRef),
      tx.get(walletRef.collection("private").doc("payoutMethod")),
      tx.get(walletRef.collection("private").doc("payout")),
    ]);
    // Money needs somewhere to go, and new details wait out a 24-hour hold.
    const method = methodSnap.data();
    if (!method) {
      throw new functions.https.HttpsError("failed-precondition",
          "Add a payout method before your first withdrawal.");
    }
    if (method.availableAt && method.availableAt.toMillis() > Date.now()) {
      throw new functions.https.HttpsError("failed-precondition",
          "Your payout method was just changed. For your security you can " +
          "withdraw again 24 hours after the change.");
    }
    if (method.proxyType === "mobile" &&
        normaliseMobile(payoutSnap.data()?.phone ?? walletSnap.data()?.phone) !==
            method.mobile) {
      throw new functions.https.HttpsError("failed-precondition",
          "Your profile phone number changed. Update your DuitNow payout " +
          "method to match it first.");
    }
    const wallet = walletSnap.data() || {};
    const balance = wallet.walletBalanceSen || 0;
    // Use the available balance; money locked for a bid can't be withdrawn.
    const available = balance - (wallet.escrowLockedSen || 0);
    if (available < amountSen) {
      functions.logger.error("withdrawFromWallet rejected: insufficient balance",
          {uid, amountSen, available});
      throw new functions.https.HttpsError(
          "failed-precondition", "Insufficient wallet balance.");
    }
    tx.update(walletRef, {walletBalanceSen: balance - amountSen});
    appendLedger(tx, {
      fromUid: uid,
      toUid: null,
      amountSen,
      type: "withdraw",
      participantIds: [uid],
    });
    // Always send a receipt when money leaves the wallet.
    notify(tx, uid, {
      type: "payment",
      title: "Withdrawal complete",
      body: `${rm(amountSen)} sent to ${method.masked} (demo: no real ` +
          "bank transfer is made).",
      route: "/profile/earnings",
    });
  });
  functions.logger.info("withdrawFromWallet completed", {uid, amountSen});
});

// toyyibPay top-up. Money only moves in `creditToyyibpayTopup`, which
// re-checks the bill with toyyibPay and credits the amount we stored.

const {defineSecret} = require("firebase-functions/params");
const toyyibpaySecret = defineSecret("TOYYIBPAY_SECRET_KEY");
const TOYYIBPAY_BASE = "https://dev.toyyibpay.com";
const TOYYIBPAY_CATEGORY = "0zghdj8k";
const TOYYIBPAY_RETURN_URL = "https://fairbid-c9340.web.app/payment-return";
const TOYYIBPAY_CALLBACK_URL =
    "https://us-central1-fairbid-c9340.cloudfunctions.net/toyyibpayCallback";

/**
 * Creates a toyyibPay bill and returns its payment page URL.
 * Same caps as `topUpWallet`; no money moves until the bill is paid.
 */
exports.createToyyibpayBill = functions.runWith({secrets: [toyyibpaySecret]})
    .https.onCall(async (data, context) => {
      const uid = callerUid(context);
      const amountSen = checkAmount(data.amountSen);
      functions.logger.info("createToyyibpayBill requested", {uid, amountSen});
      if (amountSen > MAX_TOPUP_SEN) {
        functions.logger.error("createToyyibpayBill rejected: over per-call cap",
            {uid, amountSen, capSen: MAX_TOPUP_SEN});
        throw new functions.https.HttpsError(
            "invalid-argument", "Top-ups are capped at RM 10,000.");
      }
      const db = admin.firestore();
      const userSnap = await db.doc(`users/${uid}`).get();
      const user = userSnap.data() || {};
      if (user.suspended === true) {
        functions.logger.error("createToyyibpayBill rejected: suspended user",
            {uid});
        throw new functions.https.HttpsError(
            "permission-denied",
            "Your account is suspended. Contact support if you think this " +
            "is a mistake.");
      }
      if ((user.walletBalanceSen || 0) + amountSen > MAX_WALLET_BALANCE_SEN) {
        functions.logger.error("createToyyibpayBill rejected: over wallet cap",
            {uid, amountSen, capSen: MAX_WALLET_BALANCE_SEN});
        throw new functions.https.HttpsError(
            "failed-precondition", "Wallet balance is capped at RM 50,000.");
      }

      // billAmount is cents == sen, so amountSen is passed through unchanged.
      const form = new URLSearchParams({
        userSecretKey: toyyibpaySecret.value(),
        categoryCode: TOYYIBPAY_CATEGORY,
        billName: "FairBid_TopUp",
        billDescription: "Wallet_topup",
        billPriceSetting: "1",
        billPayorInfo: "1",
        billAmount: String(amountSen),
        billReturnUrl: TOYYIBPAY_RETURN_URL,
        billCallbackUrl: TOYYIBPAY_CALLBACK_URL,
        // Unique per bill, or toyyibPay may treat a new payment as a repeat.
        billExternalReferenceNo: `${uid}-${Date.now()}`,
        billTo: user.displayName || "FairBid user",
        billEmail: user.email || "user@fairbid.app",
        // toyyibPay rejects an empty phone, so use a placeholder if none.
        billPhone: user.phone || "0123456789",
        billPaymentChannel: "2",
        billExpiryDays: "1",
      });
      const res = await fetch(`${TOYYIBPAY_BASE}/index.php/api/createBill`, {
        method: "POST",
        headers: {"Content-Type": "application/x-www-form-urlencoded"},
        body: form,
      });
      const parsed = await res.json().catch(() => null);
      const billCode = Array.isArray(parsed) ? parsed[0]?.BillCode : null;
      if (!billCode) {
        // Never logs the secret - `parsed` is toyyibPay's own reply.
        functions.logger.error("createToyyibpayBill: no BillCode", {parsed});
        throw new functions.https.HttpsError(
            "internal", "Could not start the payment. Please try again.");
      }

      await db.doc(`topups/${billCode}`).set({
        uid,
        amountSen,
        status: "pending",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      functions.logger.info("createToyyibpayBill created",
          {uid, amountSen, billCode});
      return {billCode, paymentUrl: `${TOYYIBPAY_BASE}/${billCode}`};
    });

/**
 * Checks a bill with toyyibPay and credits the wallet at most once.
 * Used by the webhook and the reconcile call. Returns `{credited, reason}`.
 */
async function creditToyyibpayTopup(billCode) {
  const db = admin.firestore();
  const form = new URLSearchParams({
    userSecretKey: toyyibpaySecret.value(),
    billCode,
  });
  const res = await fetch(
      `${TOYYIBPAY_BASE}/index.php/api/getBillTransactions`, {
        method: "POST",
        headers: {"Content-Type": "application/x-www-form-urlencoded"},
        body: form,
      });
  const transactions = await res.json().catch(() => null);
  const paid = Array.isArray(transactions) ?
      transactions.find((t) => t.billpaymentStatus === "1") : null;
  if (!paid) {
    functions.logger.info("creditToyyibpayTopup: not paid", {billCode});
    return {credited: false, reason: "not_paid"};
  }

  const topupRef = db.doc(`topups/${billCode}`);
  const topupSnap = await topupRef.get();
  if (!topupSnap.exists) {
    functions.logger.error("creditToyyibpayTopup: unknown bill", {billCode});
    return {credited: false, reason: "unknown_bill"};
  }

  // toyyibPay gives the amount as ringgit text ("10.00"); convert to sen.
  const paidSen = Math.round(parseFloat(paid.billpaymentAmount) * 100);
  if (paidSen !== topupSnap.data().amountSen) {
    functions.logger.error("toyyibpay amount mismatch", {
      billCode, expected: topupSnap.data().amountSen, got: paidSen,
    });
    return {credited: false, reason: "amount_mismatch"};
  }

  return db.runTransaction(async (tx) => {
    const snap = await tx.get(topupRef);
    const rec = snap.data();
    if (!rec) {
      functions.logger.error("creditToyyibpayTopup: record vanished",
          {billCode});
      return {credited: false, reason: "unknown_bill"};
    }
    if (rec.status === "credited") {
      functions.logger.info("creditToyyibpayTopup: already credited",
          {billCode, uid: rec.uid, amountSen: rec.amountSen});
      return {credited: true, reason: "already_credited"}; // idempotent no-op
    }

    const walletRef = db.doc(`users/${rec.uid}`);
    const walletSnap = await tx.get(walletRef);
    const wallet = walletSnap.data() || {};
    const newBalance = (wallet.walletBalanceSen || 0) + rec.amountSen;
    if (newBalance > MAX_WALLET_BALANCE_SEN) {
      // Paid money is always credited; the cap is only a pre-check.
      functions.logger.warn("toyyibpay credit exceeds wallet cap",
          {billCode, uid: rec.uid, newBalance});
    }
    tx.update(walletRef, {
      walletBalanceSen: admin.firestore.FieldValue.increment(rec.amountSen),
    });
    tx.update(topupRef, {
      status: "credited",
      creditedAt: admin.firestore.FieldValue.serverTimestamp(),
      invoiceNo: paid.billpaymentInvoiceNo,
    });
    // Same ledger entry as topUpWallet, plus a `ref` to the bill.
    appendLedger(tx, {
      fromUid: null,
      toUid: rec.uid,
      amountSen: rec.amountSen,
      type: "topup",
      ref: billCode,
      participantIds: [rec.uid],
    });
    functions.logger.info("creditToyyibpayTopup: credited",
        {billCode, uid: rec.uid, amountSen: rec.amountSen});
    return {credited: true, reason: "credited"};
  });
}

/**
 * toyyibPay's webhook. Replies 200 once we have decided (credit or reject);
 * replies 500 only if toyyibPay's API can't be reached, so it retries.
 */
exports.toyyibpayCallback = functions.runWith({secrets: [toyyibpaySecret]})
    .https.onRequest(async (req, res) => {
      if (req.method !== "POST") {
        res.status(405).send("Method Not Allowed");
        return;
      }
      const billCode = req.body?.billcode;
      if (!billCode) {
        res.status(400).send("missing billcode");
        return;
      }
      try {
        const {credited, reason} = await creditToyyibpayTopup(billCode);
        functions.logger.info("toyyibpayCallback handled",
            {billCode, credited, reason});
        const messages = {
          not_paid: "not paid",
          unknown_bill: "unknown bill",
          amount_mismatch: "amount mismatch",
        };
        res.status(200).send(messages[reason] || "ok");
      } catch (err) {
        // Never logs the secret or the raw request body.
        functions.logger.error(
            "toyyibpayCallback failed", {billCode, message: err?.message});
        res.status(500).send("error");
      }
    });

/**
 * Backup for a missed webhook: the client calls this after the WebView closes.
 * The caller must own the bill; it uses the same credit helper.
 */
exports.reconcileToyyibpayTopup =
    functions.runWith({secrets: [toyyibpaySecret]})
        .https.onCall(async (data, context) => {
          const uid = callerUid(context);
          const billCode = checkId(data.billCode, "billCode");
          functions.logger.info("reconcileToyyibpayTopup requested",
              {uid, billCode});
          const topupSnap =
              await admin.firestore().doc(`topups/${billCode}`).get();
          if (topupSnap.data()?.uid !== uid) {
            functions.logger.error(
                "reconcileToyyibpayTopup rejected: bill not owned by caller",
                {uid, billCode});
            throw new functions.https.HttpsError(
                "permission-denied", "This top-up does not belong to you.");
          }
          const {credited, reason} = await creditToyyibpayTopup(billCode);
          functions.logger.info("reconcileToyyibpayTopup result",
              {uid, billCode, credited, reason});
          return {credited};
        });

/**
 * Admin ruling on a flagged review. Hiding it also removes its rating from
 * the reviewee's totals; keeping it just clears the flag.
 */
exports.moderateReview = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const revieweeId = checkId(data.revieweeId, "revieweeId");
  const reviewId = checkId(data.reviewId, "reviewId");
  const hide = data.hide === true;
  const db = admin.firestore();
  const userRef = db.doc(`users/${revieweeId}`);
  const reviewRef = userRef.collection("reviews").doc(reviewId);

  await db.runTransaction(async (tx) => {
    await assertAdmin(tx, db, uid);
    const [userSnap, reviewSnap] = await Promise.all([
      tx.get(userRef), tx.get(reviewRef),
    ]);
    const review = reviewSnap.data();
    if (!review) {
      throw new functions.https.HttpsError("not-found", "Review not found.");
    }

    if (hide && !review.hidden) {
      // The `!review.hidden` check stops a double subtract if moderated twice.
      tx.update(userRef, {
        ratingSum:
            Math.max(0, (userSnap.data()?.ratingSum || 0) - review.rating),
        ratingCount: Math.max(0, (userSnap.data()?.ratingCount || 0) - 1),
      });
    }
    tx.update(reviewRef, {
      flagged: false,
      hidden: hide,
      moderatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (hide) {
      notify(tx, revieweeId, {
        type: "review",
        title: "A review was removed",
        body: "A review you reported was taken down after moderation, and " +
            "your Trust Score has been adjusted.",
        route: "/profile",
      });
    }
  });
});

// Account suspension. Only admins can set `suspended` (rules block clients);
// it blocks the app screens and the money callables.

/**
 * Admin suspends (true) or reinstates (false) a user, with an optional reason.
 * The user is notified either way.
 */
exports.setUserSuspended = functions.https.onCall(async (data, context) => {
  const callerId = callerUid(context);
  const targetUid = checkId(data.uid, "uid");
  const suspend = data.suspended === true;
  const reason = typeof data.reason === "string" ? data.reason.trim() : "";
  const db = admin.firestore();
  const targetRef = db.doc(`users/${targetUid}`);

  await db.runTransaction(async (tx) => {
    await assertAdmin(tx, db, callerId);
    const targetSnap = await tx.get(targetRef);
    if (!targetSnap.exists) {
      throw new functions.https.HttpsError("not-found", "User not found.");
    }
    if (targetUid === callerId) {
      throw new functions.https.HttpsError(
          "failed-precondition", "You can't suspend your own account.");
    }
    if (targetSnap.data().role === "admin") {
      throw new functions.https.HttpsError(
          "failed-precondition", "An admin account can't be suspended.");
    }

    tx.update(targetRef, suspend ? {
      suspended: true,
      suspensionReason: reason || null,
      suspendedAt: admin.firestore.FieldValue.serverTimestamp(),
      suspendedBy: callerId,
    } : {
      suspended: false,
      suspensionReason: null,
      suspendedAt: null,
      suspendedBy: null,
    });
    notify(tx, targetUid, suspend ? {
      type: "account",
      title: "Your account has been suspended",
      body: reason ?
          `An administrator suspended your account: "${reason}". Contact ` +
          "support if you think this is a mistake." :
          "An administrator suspended your account. Contact support if you " +
          "think this is a mistake.",
      route: "/suspended",
    } : {
      type: "account",
      title: "Your account has been reinstated",
      body: "An administrator lifted the suspension on your account. " +
          "Welcome back to FairBid.",
      route: "/home",
    });
  });
});

/**
 * Admin-only: removes all 2FA factors for a user who lost their authenticator.
 * Refresh tokens are revoked so the old session ends.
 */
exports.adminClearMfa = functions.https.onCall(async (data, context) => {
  const callerId = callerUid(context);
  const targetUid = checkId(data.uid, "uid");
  const db = admin.firestore();

  const callerSnap = await db.doc(`users/${callerId}`).get();
  if (callerSnap.data()?.role !== "admin") {
    throw new functions.https.HttpsError(
        "permission-denied", "Only an admin can do this.");
  }

  await admin.auth().updateUser(targetUid, {
    multiFactor: {enrolledFactors: null},
  });
  await admin.auth().revokeRefreshTokens(targetUid);
});

// Disputes. Raising one freezes the milestone; an admin ruling pays out escrow.

const {disputeRefundPlan} = require("./payouts");

/**
 * A participant disputes a funded or delivered milestone, which freezes it.
 * No money moves until an admin rules.
 */
exports.raiseDispute = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const milestoneId = checkId(data.milestoneId, "milestoneId");
  const statement =
      typeof data.statement === "string" ? data.statement.trim() : "";
  if (statement === "") {
    throw new functions.https.HttpsError(
        "invalid-argument", "Describe the issue.");
  }
  const evidenceUrls = Array.isArray(data.evidenceUrls) ?
      data.evidenceUrls.filter((url) => typeof url === "string") : [];

  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestoneRef = jobRef.collection("milestones").doc(milestoneId);
  const disputeRef = db.collection("disputes").doc();

  await db.runTransaction(async (tx) => {
    await assertNotSuspended(tx, db, uid);
    const [jobSnap, milestoneSnap] =
        await Promise.all([tx.get(jobRef), tx.get(milestoneRef)]);
    const job = jobSnap.data();
    const isRequestor = job?.requestorId === uid;
    const isProvider = job?.acceptedProviderId === uid;
    if (!isRequestor && !isProvider) {
      throw new functions.https.HttpsError(
          "permission-denied",
          "Only the job's participants can raise a dispute.");
    }
    const milestone = milestoneSnap.data();
    if (milestone?.status !== "funded" && milestone?.status !== "submitted") {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "Only a funded or delivered milestone can be disputed.");
    }

    // disputedBy lets the raiser withdraw it from the milestone card.
    tx.update(milestoneRef, {status: "disputed", disputedBy: uid});
    tx.set(disputeRef, {
      jobId,
      jobTitle: job.title || null,
      milestoneId,
      milestoneDescription: milestone.description || "",
      amountSen: milestone.amountSen,
      // Where the milestone goes back to if the dispute is withdrawn.
      milestoneStatusBefore: milestone.status,
      raisedByUid: uid,
      raisedByRole: isRequestor ? "requestor" : "provider",
      requestorId: job.requestorId,
      providerId: job.acceptedProviderId,
      statement,
      evidenceUrls,
      conversationId: `${jobId}_${job.acceptedProviderId}`,
      participantIds: [job.requestorId, job.acceptedProviderId],
      status: "open",
      resolution: null,
      rulingNote: null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      resolvedAt: null,
      ...(job.bundleId ? {bundleId: job.bundleId} : {}),
    });
    notify(tx, isRequestor ? job.acceptedProviderId : job.requestorId, {
      type: "dispute",
      title: "A dispute was raised",
      body: `The ${isRequestor ? "client" : "provider"} disputed ` +
          `"${milestone.description}" on "${job.title}". An admin will ` +
          "review it.",
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * The person who raised an open dispute withdraws it. The milestone goes back
 * to where it was (in escrow, or delivered) and no money moves.
 */
exports.withdrawDispute = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const milestoneId = checkId(data.milestoneId, "milestoneId");
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestoneRef = jobRef.collection("milestones").doc(milestoneId);
  const openQuery = db.collection("disputes")
      .where("jobId", "==", jobId)
      .where("milestoneId", "==", milestoneId)
      .where("status", "==", "open");

  await db.runTransaction(async (tx) => {
    const [jobSnap, milestoneSnap, disputes] = await Promise.all([
      tx.get(jobRef), tx.get(milestoneRef), tx.get(openQuery),
    ]);
    const disputeDoc = disputes.docs[0];
    const dispute = disputeDoc?.data();
    if (!dispute || milestoneSnap.data()?.status !== "disputed") {
      throw new functions.https.HttpsError(
          "failed-precondition", "There is no open dispute to withdraw.");
    }
    if (dispute.raisedByUid !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied", "Only the person who raised it can withdraw it.");
    }
    const job = jobSnap.data();
    tx.update(milestoneRef, {
      status: dispute.milestoneStatusBefore === "submitted" ?
          "submitted" : "funded",
      disputedBy: null,
    });
    tx.update(disputeDoc.ref, {
      status: "withdrawn",
      resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const isRequestor = dispute.raisedByRole === "requestor";
    notify(tx, isRequestor ? job.acceptedProviderId : job.requestorId, {
      type: "dispute",
      title: "Dispute withdrawn",
      body: `The ${isRequestor ? "client" : "provider"} withdrew their ` +
          `dispute on "${job.title}". The work carries on as before.`,
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * Admin rules on a dispute. `release` pays the provider. `refund` gives the
 * client back all money still held and ends the job.
 */
exports.resolveDispute = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const disputeId = checkId(data.disputeId, "disputeId");
  const resolution = data.resolution;
  if (resolution !== "release" && resolution !== "refund") {
    throw new functions.https.HttpsError(
        "invalid-argument", "Resolution must be 'release' or 'refund'.");
  }
  const rulingNote =
      typeof data.rulingNote === "string" ? data.rulingNote.trim() : "";

  const db = admin.firestore();
  const disputeRef = db.doc(`disputes/${disputeId}`);

  await db.runTransaction(async (tx) => {
    await assertAdmin(tx, db, uid);
    const disputeSnap = await tx.get(disputeRef);
    const dispute = disputeSnap.data();
    if (dispute?.status !== "open") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This dispute has already been closed.");
    }

    const jobRef = db.doc(`jobs/${dispute.jobId}`);
    const milestonesRef = jobRef.collection("milestones");
    const milestoneRef = milestonesRef.doc(dispute.milestoneId);
    const requestorRef = db.doc(`users/${dispute.requestorId}`);
    const providerRef = db.doc(`users/${dispute.providerId}`);
    const [milestoneSnap, allMilestones, requestorSnap, providerSnap, jobSnap,
      openOnJob] = await Promise.all([
      tx.get(milestoneRef),
      tx.get(milestonesRef),
      tx.get(requestorRef),
      tx.get(providerRef),
      tx.get(jobRef),
      tx.get(db.collection("disputes")
          .where("jobId", "==", dispute.jobId)
          .where("status", "==", "open")),
    ]);
    if (milestoneSnap.data()?.status !== "disputed") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This milestone is not under dispute.");
    }
    const job = jobSnap.data();
    const amountSen = dispute.amountSen;
    const released = resolution === "release";
    let refundedSen = 0;

    if (released) {
      // Provider is paid. If it was the last milestone, the job completes.
      tx.update(providerRef, {
        walletBalanceSen:
            (providerSnap.data()?.walletBalanceSen || 0) + amountSen,
      });
      tx.update(milestoneRef, {status: "released", disputedBy: null});
      if (completesJob(job, milestoneRows(allMilestones),
          dispute.milestoneId)) {
        tx.update(jobRef, {status: "completed"});
      }
      appendLedger(tx, {
        fromUid: ESCROW,
        toUid: dispute.providerId,
        amountSen,
        type: "dispute_release",
        jobId: dispute.jobId,
        jobTitle: dispute.jobTitle || null,
        milestoneId: dispute.milestoneId,
        participantIds: [dispute.providerId],
      });
    } else {
      // Refund: every stage still holding money goes back and the job ends,
      // so it can't simply be funded again as if nothing happened.
      const plan = disputeRefundPlan(milestoneRows(allMilestones));
      refundedSen = plan.refunds.reduce((sum, r) => sum + r.amountSen, 0);
      const wallet = requestorSnap.data() || {};
      tx.update(requestorRef, {
        walletBalanceSen: (wallet.walletBalanceSen || 0) + refundedSen,
      });
      for (const refund of plan.refunds) {
        tx.update(milestonesRef.doc(refund.id),
            {status: "refunded", disputedBy: null});
        appendLedger(tx, {
          fromUid: ESCROW,
          toUid: dispute.requestorId,
          amountSen: refund.amountSen,
          type: refund.id === dispute.milestoneId ?
              "dispute_refund" : "refund",
          jobId: dispute.jobId,
          jobTitle: dispute.jobTitle || null,
          milestoneId: refund.id,
          participantIds: [dispute.requestorId],
        });
      }
      for (const id of plan.deleteIds) tx.delete(milestonesRef.doc(id));
      tx.update(jobRef, {
        status: "cancelled",
        cancelledBy: "dispute",
        cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
        cancellationReason: "Ended after an admin refunded the client",
        cancellationRequestedBy: null,
        cancellationRequestedAt: null,
        priceChangeRequest: null,
      });
      // Other open disputes on this job end with it; their money is refunded.
      for (const other of openOnJob.docs) {
        if (other.id === disputeId) continue;
        tx.update(other.ref, {
          status: "resolved",
          resolution: "refund",
          rulingNote: "Closed because the job ended after another dispute.",
          resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      // A ruling against the provider counts against their track record.
      tx.update(providerRef, {
        disputesLost: admin.firestore.FieldValue.increment(1),
      });
    }
    tx.update(disputeRef, {
      status: "resolved",
      resolution,
      rulingNote: rulingNote || null,
      resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const note = rulingNote ? ` Admin's note: "${rulingNote}"` : "";
    notify(tx, dispute.providerId, {
      type: "dispute",
      title: released ? "Dispute decided: you were paid" :
          "Dispute decided: the client was refunded",
      body: released ?
          `${rm(amountSen)} for "${dispute.jobTitle}" was paid to your ` +
          `wallet.${note}` :
          `The client got ${rm(refundedSen)} back and ` +
          `"${dispute.jobTitle}" has ended.${note}`,
      route: `/jobs/${dispute.jobId}`,
    });
    notify(tx, dispute.requestorId, {
      type: "dispute",
      title: released ? "Dispute decided: the provider was paid" :
          "Dispute decided: you were refunded",
      body: released ?
          `${rm(amountSen)} for "${dispute.jobTitle}" was paid to the ` +
          `provider.${note}` :
          `${rm(refundedSen)} is back in your wallet and ` +
          `"${dispute.jobTitle}" has ended.${note}`,
      route: `/jobs/${dispute.jobId}`,
    });
  });
});

/**
 * Admin-only, safe to re-run: recounts each user's `jobsCompleted` and
 * `disputesLost` from the source data. The trust consumer rebuilds scores.
 */
exports.backfillTrust = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const db = admin.firestore();
  const callerSnap = await db.doc(`users/${uid}`).get();
  if (callerSnap.data()?.role !== "admin") {
    throw new functions.https.HttpsError(
        "permission-denied", "Only an admin can do this.");
  }

  const count = async (query) => (await query.count().get()).data().count;
  const users = await db.collection("users").get();
  let updated = 0;
  for (const doc of users.docs) {
    const [asProvider, asRequestor, refunds] = await Promise.all([
      count(db.collection("jobs")
          .where("acceptedProviderId", "==", doc.id)
          .where("status", "==", "completed")),
      count(db.collection("jobs")
          .where("requestorId", "==", doc.id)
          .where("status", "==", "completed")),
      count(db.collection("disputes")
          .where("providerId", "==", doc.id)
          .where("resolution", "==", "refund")),
    ]);
    // Always write: it fixes the counters and re-triggers the trust recompute.
    await doc.ref.update({
      jobsCompleted: asProvider + asRequestor,
      disputesLost: refunds,
    });
    updated++;
  }
  return {users: users.size, updated};
});

// Job cancellation: one side asks, the other accepts (an admin can override).
// It never strands escrow: it is blocked, or the money is refunded.

const STAGE_DELIVERED_MESSAGE =
    "A delivered or disputed stage must be released or resolved before " +
    "this job can be cancelled.";

const {
  canCancelFunded,
  cancellationPlan,
  planIncrease,
  planDecrease,
  finishedByDecrease,
} = require("./payouts");

/** Returns why the job can't be cancelled now, or null if it can. */
function cancellationBlocker(milestonesSnap) {
  return canCancelFunded(milestoneRows(milestonesSnap)) ?
    null : STAGE_DELIVERED_MESSAGE;
}

/**
 * Cancels the job and settles money: unfunded milestones are deleted and
 * funded stages refunded. Caller checks authority and [cancellationBlocker].
 */
function finaliseCancellation(tx, jobRef, job, milestonesSnap, cancelledBy,
    requestorWalletRef, requestorWalletSnap) {
  const wallet = requestorWalletSnap.data() || {};
  const plan = cancellationPlan(milestoneRows(milestonesSnap));
  for (const id of plan.deleteIds) {
    tx.delete(jobRef.collection("milestones").doc(id));
  }
  const refundSen = plan.refunds.reduce((sum, r) => sum + r.amountSen, 0);
  if (refundSen > 0) {
    tx.update(requestorWalletRef, {
      walletBalanceSen: (wallet.walletBalanceSen || 0) + refundSen,
    });
  }
  for (const refund of plan.refunds) {
    appendLedger(tx, {
      fromUid: ESCROW,
      toUid: job.requestorId,
      amountSen: refund.amountSen,
      type: "refund",
      jobId: jobRef.id,
      jobTitle: job.title || null,
      milestoneId: refund.id,
      participantIds: [job.requestorId],
    });
  }
  tx.update(jobRef, {
    status: "cancelled",
    cancelledBy,
    cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
    cancellationRequestedBy: null,
    cancellationRequestedAt: null,
    priceChangeRequest: null,
  });
}

/**
 * Either party asks to cancel an in-progress job; the other side must accept.
 * Refused while escrow is held.
 */
exports.requestJobCancellation =
  functions.https.onCall(async (data, context) => {
    const uid = callerUid(context);
    const jobId = checkId(data.jobId, "jobId");
    const reason = typeof data.reason === "string" ? data.reason.trim() : "";
    const db = admin.firestore();
    const jobRef = db.doc(`jobs/${jobId}`);
    const milestonesRef = jobRef.collection("milestones");

    await db.runTransaction(async (tx) => {
      const [jobSnap, milestones] = await Promise.all([
        tx.get(jobRef),
        tx.get(milestonesRef),
      ]);
      const job = jobSnap.data();
      const isRequestor = job?.requestorId === uid;
      const isProvider = job?.acceptedProviderId === uid;
      if (!isRequestor && !isProvider) {
        throw new functions.https.HttpsError(
            "permission-denied",
            "Only the job's participants can cancel it.");
      }
      if (job.status !== "in_progress") {
        throw new functions.https.HttpsError(
            "failed-precondition", "This job is not in progress.");
      }
      if (job.cancellationRequestedBy) {
        throw new functions.https.HttpsError(
            "failed-precondition",
            "A cancellation request is already pending.");
      }
      if (job.priceChangeRequest) {
        throw new functions.https.HttpsError(
            "failed-precondition", "Resolve the pending price change first.");
      }
      const blocker = cancellationBlocker(milestones);
      if (blocker) {
        throw new functions.https.HttpsError("failed-precondition", blocker);
      }
      tx.update(jobRef, {
        cancellationRequestedBy: isRequestor ? "requestor" : "provider",
        cancellationReason: reason || null,
        cancellationRequestedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      notify(tx, isRequestor ? job.acceptedProviderId : job.requestorId, {
        type: "cancellation",
        title: "Cancellation requested",
        body: `The ${isRequestor ? "client" : "provider"} asked to cancel ` +
            `"${job.title}". Accept or decline from the job page.`,
        route: `/jobs/${jobId}`,
      });
    });
  });

/**
 * The other party accepts or declines a cancellation request.
 * Accepting re-checks the escrow guard and cancels the job.
 */
exports.respondToJobCancellation =
  functions.https.onCall(async (data, context) => {
    const uid = callerUid(context);
    const jobId = checkId(data.jobId, "jobId");
    const accept = data.accept === true;
    const db = admin.firestore();
    const jobRef = db.doc(`jobs/${jobId}`);
    const milestonesRef = jobRef.collection("milestones");

    await db.runTransaction(async (tx) => {
      const [jobSnap, milestones] = await Promise.all([
        tx.get(jobRef),
        tx.get(milestonesRef),
      ]);
      const job = jobSnap.data();
      if (job?.status !== "in_progress" || !job.cancellationRequestedBy) {
        throw new functions.https.HttpsError(
            "failed-precondition", "There is no pending cancellation request.");
      }
      // The responder must be the party that did NOT raise the request.
      const responderRole = job.requestorId === uid ? "requestor" :
          job.acceptedProviderId === uid ? "provider" : null;
      if (!responderRole) {
        throw new functions.https.HttpsError(
            "permission-denied", "Only the job's participants can respond.");
      }
      if (responderRole === job.cancellationRequestedBy) {
        throw new functions.https.HttpsError(
            "failed-precondition",
            "You raised this request; the other party must respond.");
      }

      // The requester gets told the outcome.
      const requesterUid = responderRole === "requestor" ?
          job.acceptedProviderId : job.requestorId;
      if (!accept) {
        tx.update(jobRef, {
          cancellationRequestedBy: null,
          cancellationReason: null,
          cancellationRequestedAt: null,
        });
        notify(tx, requesterUid, {
          type: "cancellation",
          title: "Cancellation declined",
          body: `The other party declined to cancel "${job.title}". The ` +
              "job continues.",
          route: `/jobs/${jobId}`,
        });
        return;
      }
      const blocker = cancellationBlocker(milestones);
      if (blocker) {
        throw new functions.https.HttpsError("failed-precondition", blocker);
      }
      const requestorWalletRef = db.doc(`users/${job.requestorId}`);
      const requestorWalletSnap = await tx.get(requestorWalletRef);
      finaliseCancellation(tx, jobRef, job, milestones, uid, requestorWalletRef,
          requestorWalletSnap);
      notify(tx, requesterUid, {
        type: "cancellation",
        title: "Job cancelled",
        body: `Both parties agreed: "${job.title}" has been cancelled.`,
        route: `/jobs/${jobId}`,
      });
    });
  });

// Price change. Either party proposes a new price; the other accepts or declines.
// `acceptedBidAmountSen` is the live price; checks are in price_change.js.

const {validatePriceChange} = require("./price_change");

/** Which side of [job] [uid] is on, or null. */
function jobRole(job, uid) {
  if (job?.requestorId === uid) return "requestor";
  if (job?.acceptedProviderId === uid) return "provider";
  return null;
}

/** The uid of the other participant. */
const counterpartyUid = (job, role) =>
  role === "requestor" ? job.acceptedProviderId : job.requestorId;

/** Proposes a new price; nothing changes until the other party accepts. */
exports.requestPriceChange = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const newAmountSen = checkAmount(data.newAmountSen);
  const reason = typeof data.reason === "string" ? data.reason.trim() : "";
  if (reason === "" || reason.length > 500) {
    throw new functions.https.HttpsError(
        "invalid-argument",
        "Give a reason for the change (up to 500 characters).");
  }
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);

  await db.runTransaction(async (tx) => {
    await assertNotSuspended(tx, db, uid);
    const [jobSnap, milestones] = await Promise.all([
      tx.get(jobRef),
      tx.get(jobRef.collection("milestones")),
    ]);
    const job = jobSnap.data();
    const role = jobRole(job, uid);
    if (!role) {
      throw new functions.https.HttpsError(
          "permission-denied",
          "Only the job's participants can change its price.");
    }
    if (job.priceChangeRequest) {
      throw new functions.https.HttpsError(
          "failed-precondition", "A price change is already pending.");
    }
    if (job.cancellationRequestedBy) {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "Resolve the pending cancellation request first.");
    }
    const problem = validatePriceChange({
      job, milestones: milestones.docs.map((d) => d.data()), newAmountSen,
    });
    if (problem) {
      throw new functions.https.HttpsError("failed-precondition", problem);
    }
    tx.update(jobRef, {
      priceChangeRequest: {
        by: role,
        newAmountSen,
        reason,
        requestedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
    });
    notify(tx, counterpartyUid(job, role), {
      type: "price_change",
      title: "Price change requested",
      body: `The ${role === "requestor" ? "client" : "provider"} proposed ` +
          `changing the price of "${job.title}" from ` +
          `${rm(job.acceptedBidAmountSen)} to ${rm(newAmountSen)}.`,
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * Moves money for a price change of [delta] sen on a funded-at-award job.
 * Increase: wallet to escrow. Decrease: refund. True means the job is done.
 */
function repriceFundedStages(tx, {job, jobRef, milestonesRef, rows, walletRef,
  wallet, delta}) {
  const balance = wallet.walletBalanceSen || 0;
  const ledger = {
    jobId: jobRef.id,
    jobTitle: job.title || null,
    participantIds: [job.requestorId],
  };
  if (delta > 0) {
    tx.update(walletRef, {walletBalanceSen: balance - delta});
    const plan = planIncrease(rows, delta);
    if (plan.grow) {
      tx.update(milestonesRef.doc(plan.grow.id),
          {amountSen: plan.grow.amountSen});
      appendLedger(tx, {
        ...ledger, fromUid: job.requestorId, toUid: ESCROW, amountSen: delta,
        type: "fund", milestoneId: plan.grow.id,
      });
    } else {
      writeFundedMilestone(tx, {
        jobRef, title: job.title, requestorId: job.requestorId,
        providerId: job.acceptedProviderId, amountSen: delta,
        order: plan.add.order, description: "Price change",
      });
    }
    return false;
  }
  const refundSen = -delta;
  const plan = planDecrease(rows, refundSen);
  tx.update(walletRef, {walletBalanceSen: balance + refundSen});
  for (const {id, amountSen} of plan.updates) {
    tx.update(milestonesRef.doc(id), {amountSen});
  }
  for (const id of plan.deleteIds) tx.delete(milestonesRef.doc(id));
  appendLedger(tx, {
    ...ledger, fromUid: ESCROW, toUid: job.requestorId, amountSen: refundSen,
    type: "refund", milestoneId: plan.deleteIds[0] ?? plan.updates[0].id,
  });
  return finishedByDecrease(rows, plan.deleteIds);
}

/**
 * The other party accepts or declines a price change. Accepting re-checks it,
 * moves the money.
 */
exports.respondToPriceChange =
  functions.https.onCall(async (data, context) => {
    const uid = callerUid(context);
    const jobId = checkId(data.jobId, "jobId");
    const accept = data.accept === true;
    const db = admin.firestore();
    const jobRef = db.doc(`jobs/${jobId}`);
    const milestonesRef = jobRef.collection("milestones");

    await db.runTransaction(async (tx) => {
      await assertNotSuspended(tx, db, uid);
      const [jobSnap, milestones] = await Promise.all([
        tx.get(jobRef),
        tx.get(milestonesRef),
      ]);
      const job = jobSnap.data();
      const request = job?.priceChangeRequest;
      if (job?.status !== "in_progress" || !request) {
        throw new functions.https.HttpsError(
            "failed-precondition", "There is no pending price change.");
      }
      const role = jobRole(job, uid);
      if (!role) {
        throw new functions.https.HttpsError(
            "permission-denied", "Only the job's participants can respond.");
      }
      if (role === request.by) {
        throw new functions.https.HttpsError(
            "failed-precondition",
            "You raised this request; the other party must respond.");
      }
      const requesterUid = counterpartyUid(job, role);

      if (!accept) {
        tx.update(jobRef, {priceChangeRequest: null});
        notify(tx, requesterUid, {
          type: "price_change",
          title: "Price change declined",
          body: `The other party declined the new price for "${job.title}". ` +
              "The price is unchanged.",
          route: `/jobs/${jobId}`,
        });
        return;
      }

      const oldSen = job.acceptedBidAmountSen;
      const newSen = request.newAmountSen;
      const walletRef = db.doc(`users/${job.requestorId}`);
      const walletSnap = await tx.get(walletRef);
      const problem = validatePriceChange({
        job, milestones: milestones.docs.map((d) => d.data()),
        newAmountSen: newSen,
      });
      if (problem) {
        throw new functions.https.HttpsError("failed-precondition", problem);
      }
      const wallet = walletSnap.data() || {};
      const delta = newSen - oldSen;
      if (delta > 0) {
        const available =
            (wallet.walletBalanceSen || 0) - (wallet.escrowLockedSen || 0);
        if (available < delta) {
          throw new functions.https.HttpsError(
              "failed-precondition",
              "Insufficient available balance to accept this price change.", {
                reason: "insufficient_balance",
                shortfallSen: delta - available,
                availableSen: available,
                requiredSen: delta,
              });
        }
      }

      // Writes.
      const completed = repriceFundedStages(tx, {
        job, jobRef, milestonesRef, rows: milestoneRows(milestones),
        walletRef, wallet, delta,
      });
      const count = (job.priceChangeCount || 0) + 1;
      tx.update(jobRef, {
        acceptedBidAmountSen: newSen,
        originalBidAmountSen: job.originalBidAmountSen ?? oldSen,
        priceChangeCount: count,
        priceChangeRequest: null,
        ...(completed ? {status: "completed"} : {}),
      });
      tx.set(jobRef.collection("events").doc(`price_change_${count}`), {
        type: "price_changed",
        title: `Price changed: ${rm(oldSen)} → ${rm(newSen)}`,
        at: admin.firestore.FieldValue.serverTimestamp(),
      });
      const body = `The price of "${job.title}" is now ${rm(newSen)}. ` +
          (delta > 0 ?
              "The extra amount has been moved into escrow." :
              "The difference was refunded to the client.");
      notify(tx, requesterUid, {
        type: "price_change", title: "Price change accepted", body,
        route: `/jobs/${jobId}`,
      });
      notify(tx, uid, {
        type: "price_change", title: "Price changed", body,
        route: `/jobs/${jobId}`,
      });
    });
  });

/** The party that raised a price change takes it back. */
exports.withdrawPriceChange = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);

  await db.runTransaction(async (tx) => {
    const job = (await tx.get(jobRef)).data();
    const request = job?.priceChangeRequest;
    if (!request) {
      throw new functions.https.HttpsError(
          "failed-precondition", "There is no pending price change.");
    }
    const role = jobRole(job, uid);
    if (!role || role !== request.by) {
      throw new functions.https.HttpsError(
          "permission-denied", "Only the party that asked can withdraw it.");
    }
    tx.update(jobRef, {priceChangeRequest: null});
    notify(tx, counterpartyUid(job, role), {
      type: "price_change",
      title: "Price change withdrawn",
      body: `The price change request for "${job.title}" was withdrawn.`,
      route: `/jobs/${jobId}`,
    });
  });
});

// Bidding deadline. Rules block late bids, so this sweep cancels open jobs
// whose deadline passed with no accepted bid.

/**
 * Every 6 hours, cancels open jobs whose bidding deadline has passed.
 * Needs the Blaze plan, Cloud Scheduler, and the index in firestore.indexes.json.
 */
exports.closeExpiredJobs = functions.pubsub
    .schedule("every 6 hours")
    .onRun(async () => {
      const now = admin.firestore.Timestamp.now();
      const snap = await admin.firestore().collection("jobs")
          .where("status", "==", "open")
          .where("deadline", "<=", now)
          .get();
      const batch = admin.firestore().batch();
      snap.docs.forEach((doc) => batch.update(doc.ref, {
        status: "cancelled",
        cancelledBy: "system",
        cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
        cancellationReason: "Bidding deadline passed, no bid was accepted.",
      }));
      if (!snap.empty) await batch.commit();
      functions.logger.info(`closeExpiredJobs: closed ${snap.size} job(s)`);
    });

// Chat stays open 14 days after a job ends, then is read-only (kept as evidence).
const CHAT_GRACE_MS = 14 * 24 * 60 * 60 * 1000;

/**
 * Sets a conversation's `chatClosesAt` 14 days after its job ends.
 * Never creates the conversation or deletes messages.
 */
exports.closeChatOnJobEnd = functions.firestore
    .document("jobs/{jobId}")
    .onUpdate(async (change, context) => {
      const before = change.before.data();
      const after = change.after.data();
      const ended = after.status === "completed" || after.status === "cancelled";
      const wasEnded =
          before.status === "completed" || before.status === "cancelled";
      if (ended === wasEnded) return; // no relevant status change
      if (!after.acceptedProviderId) return; // no conversation to gate

      const db = admin.firestore();
      const convRef = db.doc(
          `conversations/${context.params.jobId}_${after.acceptedProviderId}`);
      const snap = await convRef.get();
      if (!snap.exists) return;
      await convRef.update({
        chatClosesAt: ended ?
            admin.firestore.Timestamp.fromMillis(Date.now() + CHAT_GRACE_MS) :
            null,
      });
    });

// Notifications. Code calls `notify()` inside its transaction; a trigger
// then sends the FCM push.

/** Formats sen as `RM 1,234.50` for notification copy. */
function rm(sen) {
  return `RM ${(sen / 100).toLocaleString("en-MY",
      {minimumFractionDigits: 2, maximumFractionDigits: 2})}`;
}

/**
 * Queues a notification for [uid] in the caller's transaction or batch, so it
 * commits together with the event. A trigger sends the push later.
 */
function notify(txOrBatch, uid, {type, title, body, route = null}) {
  if (!uid) return; // defensive: never write to users/undefined
  const ref = admin.firestore()
      .collection("users").doc(uid).collection("notifications").doc();
  txOrBatch.set(ref, {
    type,
    title,
    body,
    route,
    read: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

/**
 * Sends a new notification as an FCM push to the user's devices.
 * Dead tokens are removed. Delivery is best-effort; the in-app list is the truth.
 */
exports.onNotificationCreated = functions.firestore
    .document("users/{uid}/notifications/{notificationId}")
    .onCreate(async (snap, context) => {
      const {uid} = context.params;
      const n = snap.data();
      const userRef = admin.firestore().doc(`users/${uid}`);
      const userSnap = await userRef.get();
      const tokens = userSnap.data()?.fcmTokens || [];
      if (tokens.length === 0) return; // no device registered

      const res = await admin.messaging().sendEachForMulticast({
        tokens,
        notification: {title: n.title, body: n.body},
        // Data values must be strings; the app routes on `route` when tapped.
        data: {route: n.route || "", type: n.type || ""},
        android: {
          priority: "high",
          notification: {channelId: "fairbid_default"},
        },
      });

      const dead = [];
      res.responses.forEach((r, i) => {
        const code = r.error?.code;
        if (code === "messaging/registration-token-not-registered" ||
            code === "messaging/invalid-registration-token") {
          dead.push(tokens[i]);
        }
      });
      if (dead.length > 0) {
        await userRef.update({
          fcmTokens: admin.firestore.FieldValue.arrayRemove(...dead),
        });
      }
    });

/** New bid: tell the requestor. A trigger because bids are client writes. */
exports.onBidCreated = functions.firestore
    .document("jobs/{jobId}/bids/{bidId}")
    .onCreate(async (snap, context) => {
      const bid = snap.data();
      const jobSnap = await admin.firestore()
          .doc(`jobs/${context.params.jobId}`).get();
      const job = jobSnap.data();
      if (!job?.requestorId) return;
      const batch = admin.firestore().batch();
      notify(batch, job.requestorId, {
        type: "bid_received",
        title: "New bid on your job",
        body: `${bid.providerName || "A provider"} bid ` +
            `${rm(bid.amountSen || 0)} on "${job.title}".`,
        route: `/jobs/${context.params.jobId}`,
      });
      await batch.commit();
    });

/** Bid accepted: tell the winner. Losers aren't notified, to avoid noise. */
exports.onBidAccepted = functions.firestore
    .document("jobs/{jobId}/bids/{bidId}")
    .onUpdate(async (change, context) => {
      const before = change.before.data();
      const after = change.after.data();
      if (before.status === after.status || after.status !== "accepted") return;
      const jobSnap = await admin.firestore()
          .doc(`jobs/${context.params.jobId}`).get();
      const batch = admin.firestore().batch();
      notify(batch, context.params.bidId, {
        type: "bid_accepted",
        title: "Your bid was accepted!",
        body: `You won "${jobSnap.data()?.title || "a job"}" for ` +
            `${rm(after.amountSen || 0)}. The payment is secured in escrow ` +
            "- you can get started.",
        route: `/jobs/${context.params.jobId}`,
      });
      await batch.commit();
    });

/** Work delivered: tell the requestor to review and release. */
exports.onMilestoneDelivered = functions.firestore
    .document("jobs/{jobId}/milestones/{milestoneId}")
    .onUpdate(async (change, context) => {
      const before = change.before.data();
      const after = change.after.data();
      if (before.status === after.status || after.status !== "submitted") {
        return;
      }
      const jobSnap = await admin.firestore()
          .doc(`jobs/${context.params.jobId}`).get();
      const job = jobSnap.data();
      if (!job?.requestorId) return;
      const batch = admin.firestore().batch();
      notify(batch, job.requestorId, {
        type: "milestone",
        title: "Work delivered",
        body: `${job.acceptedProviderName || "Your provider"} marked ` +
            `"${after.description || job.title}" as delivered. Review it ` +
            `and release ${rm(after.amountSen || 0)}.`,
        route: `/jobs/${context.params.jobId}`,
      });
      await batch.commit();
    });

/** New chat message → tell the other participant, never the sender. */
exports.onMessageCreated = functions.firestore
    .document("conversations/{conversationId}/messages/{messageId}")
    .onCreate(async (snap, context) => {
      const message = snap.data();
      const convSnap = await admin.firestore()
          .doc(`conversations/${context.params.conversationId}`).get();
      const conv = convSnap.data();
      if (!conv) return;
      const recipientId = (conv.participantIds || [])
          .find((id) => id !== message.senderId);
      if (!recipientId) return;
      const senderName = message.senderId === conv.requestorId ?
          conv.requestorName : conv.providerName;
      const batch = admin.firestore().batch();
      notify(batch, recipientId, {
        type: "message",
        title: senderName || "New message",
        body: (message.text || "").length > 80 ?
            `${message.text.slice(0, 77)}...` : (message.text || ""),
        route: `/messages/${context.params.conversationId}`,
      });
      await batch.commit();
    });

/**
 * Verification decided: tell the applicant, only when the status changes.
 * Other profile edits don't send a push.
 */
exports.onVerificationDecided = functions.firestore
    .document("users/{uid}")
    .onUpdate(async (change, context) => {
      const before = change.before.data().verificationStatus;
      const after = change.after.data().verificationStatus;
      if (before === after) return;
      if (after !== "approved" && after !== "rejected") return;
      const approved = after === "approved";
      const batch = admin.firestore().batch();
      notify(batch, context.params.uid, {
        type: "verification",
        title: approved ? "You're verified!" : "Verification rejected",
        body: approved ?
            "Your documents were approved. You now have full marketplace " +
            "access." :
            "Your documents were not approved. Re-submit them from your " +
            "profile to unlock the marketplace.",
        route: "/home",
      });
      await batch.commit();
      // Uploaded ID/SSM documents are deleted once a human has ruled on them.
      await require("./ssm").deleteSsmDocument(context.params.uid);
      await require("./idcheck").deleteIdDocuments(context.params.uid);
    });

/** New review → tell the reviewee. */
exports.onReviewCreated = functions.firestore
    .document("users/{revieweeId}/reviews/{reviewId}")
    .onCreate(async (snap, context) => {
      const review = snap.data();
      const batch = admin.firestore().batch();
      notify(batch, context.params.revieweeId, {
        type: "review",
        title: "You received a review",
        body: `${review.reviewerName || "Someone"} rated you ` +
            `${review.rating}★${review.jobTitle ?
                ` on "${review.jobTitle}"` : ""}.`,
        route: "/profile",
      });
      await batch.commit();
    });

// Job timeline: server-written events at `jobs/{jobId}/events/{eventId}`.
// Fixed event ids make trigger retries safe (overwrite, not duplicate).

/** Writes (or, on a retried trigger, overwrites) one timeline entry. */
function logJobEvent(jobId, eventId, type, title) {
  return admin.firestore()
      .doc(`jobs/${jobId}/events/${eventId}`)
      .set({type, title, at: admin.firestore.FieldValue.serverTimestamp()});
}

/** A job posting starts its timeline. */
exports.logJobPosted = functions.firestore.document("jobs/{jobId}")
    .onCreate((snap, ctx) =>
      logJobEvent(ctx.params.jobId, "posted", "posted", "Job posted"));

/** Logs job status changes on the timeline; other writes are ignored. */
exports.logJobStatusChange = functions.firestore
    .document("jobs/{jobId}")
    .onUpdate((change, ctx) => {
      const before = change.before.data();
      const after = change.after.data();
      if (before.status === after.status) return null;
      const jobId = ctx.params.jobId;
      if (before.status === "open" && after.status === "in_progress") {
        return logJobEvent(jobId, "assigned", "assigned",
            `Provider assigned: ${after.acceptedProviderName || "provider"} ` +
            `(${rm(after.acceptedBidAmountSen || 0)})`);
      }
      if (after.status === "completed") {
        return logJobEvent(jobId, "completed", "completed", "Job completed");
      }
      if (after.status === "cancelled") {
        return logJobEvent(jobId, "cancelled", "cancelled",
            `Job cancelled${after.cancellationReason ?
                `: ${after.cancellationReason}` : ""}`);
      }
      return null;
    });

/** Logs milestone status changes on the timeline. */
exports.logMilestoneStatusChange = functions.firestore
    .document("jobs/{jobId}/milestones/{milestoneId}")
    .onWrite((change, ctx) => {
      const before = change.before.exists ? change.before.data() : null;
      const after = change.after.exists ? change.after.data() : null;
      if (!after || before?.status === after.status) return null; // deletion
      const jobId = ctx.params.jobId;
      const milestoneId = ctx.params.milestoneId;
      const d = after.description;
      const amt = after.amountSen;
      // Dispute steps can repeat, so they get the trigger's unique event id.
      const once = `${milestoneId}_${ctx.eventId}`;
      const wasDisputed = before?.status === "disputed";
      if (wasDisputed &&
          (after.status === "funded" || after.status === "submitted")) {
        return logJobEvent(jobId, once, "dispute_withdrawn",
            `Dispute withdrawn. "${d}" is back on track.`);
      }
      switch (after.status) {
        case "funded":
          return logJobEvent(jobId, `${milestoneId}_funded`, "funded",
              `Funded "${d}": ${rm(amt)}`);
        case "submitted":
          return logJobEvent(jobId, `${milestoneId}_submitted`, "submitted",
              `Work delivered: "${d}"`);
        case "released":
          return wasDisputed ?
              logJobEvent(jobId, once, "released",
                  `Admin decided for the provider: ${rm(amt)} paid for ` +
                  `"${d}"`) :
              logJobEvent(jobId, `${milestoneId}_released`, "released",
                  `Payment released: "${d}" (${rm(amt)})`);
        case "disputed":
          return logJobEvent(jobId, once, "disputed",
              `Dispute raised on "${d}". ${rm(amt)} is on hold until an ` +
              "admin decides.");
        case "refunded":
          return logJobEvent(jobId, once, "refunded", wasDisputed ?
              `Admin decided for the client: ${rm(amt)} refunded for "${d}"` :
              `Refunded to the client: "${d}" (${rm(amt)})`);
        default:
          return null;
      }
    });

// Gemini posting assistant. The API key stays server-side in Secret Manager.
// Every failure returns null so the post-job form keeps working.

const {GoogleGenAI, Type, ThinkingLevel, MediaResolution} =
    require("@google/genai");
const geminiKey = defineSecret("GEMINI_KEY");
// Gemini Flash-Lite model id.
const GEMINI_MODEL = "gemini-3.1-flash-lite";

/** System instruction for the fair-price guide. */
const PRICE_SYSTEM = "You estimate fair market prices for home services " +
    "in Malaysia. Give a realistic ringgit range for the job described, " +
    "based only on what it states. If a photo is provided, factor it in. " +
    "Never invent a price from an assumed brand name, measurement, or " +
    "detail the description does not give. Do not use em dashes.";

/** System instruction for the one-shot post draft. */
const DRAFT_SYSTEM = "You help customers on FairBid, a Malaysian " +
    "home-services marketplace, turn one rough note into a complete job " +
    "posting. Pick the category that fits best from the allowed list. " +
    "Write a title of at most 8 plain words naming the job, with no price " +
    "and no pleading. Write the description exactly as the description " +
    "helper would: up to three sections labelled What needs doing, then " +
    "Access & details, then Expected outcome, each label on its own line, " +
    "bullet fragments starting with the character '•' under Access & " +
    "details, a blank line between sections, about 50 to 80 words, plain " +
    "prose, no markdown and no em dashes. Drop a section rather than " +
    "padding it. Give a realistic ringgit range for the job in Malaysia. " +
    "Never invent prices, deadlines, brand names, measurements or " +
    "commitments the note did not state; leave out what you do not know. " +
    "If a photo is provided, use it to be more specific.";

/** Structured-output schema for the one-shot draft. */
const DRAFT_SCHEMA = {
  type: Type.OBJECT,
  properties: {
    title: {type: Type.STRING},
    category: {type: Type.STRING, enum: require("./bundles").CATEGORIES},
    description: {type: Type.STRING},
    minRm: {type: Type.NUMBER},
    maxRm: {type: Type.NUMBER},
  },
  required: ["title", "category", "description", "minRm", "maxRm"],
  propertyOrdering: ["title", "category", "description", "minRm", "maxRm"],
};

/** Structured-output schema for the fair-price guide: a ringgit range. */
const PRICE_SCHEMA = {
  type: Type.OBJECT,
  properties: {
    minRm: {type: Type.NUMBER},
    maxRm: {type: Type.NUMBER},
  },
  required: ["minRm", "maxRm"],
  propertyOrdering: ["minRm", "maxRm"],
};

/**
 * Parses the model's price reply into `{minSen, maxSen}`, or null if bad.
 * Wrapped in try/catch because a cut-off reply can still throw.
 */
function parsePriceJson(text) {
  try {
    const {minRm, maxRm} = JSON.parse(String(text));
    if (typeof minRm !== "number" || typeof maxRm !== "number") return null;
    if (!(minRm > 0) || !(maxRm >= minRm) || maxRm > 1000000) return null;
    return {minSen: Math.round(minRm * 100), maxSen: Math.round(maxRm * 100)};
  } catch (_) {
    return null;
  }
}

/** Parses the draft reply, or null if unusable (blank title, odd range). */
function parseDraftJson(text) {
  try {
    const draft = JSON.parse(String(text));
    const title = String(draft.title || "").trim().slice(0, 120);
    const description = String(draft.description || "").trim();
    const category = String(draft.category || "").trim();
    if (title === "" || description === "") return null;
    if (!require("./bundles").CATEGORIES.includes(category)) return null;
    const range = parsePriceJson(text); // same minRm/maxRm sanity checks
    return {
      title,
      category,
      description,
      minSen: range?.minSen ?? null,
      maxSen: range?.maxSen ?? null,
    };
  } catch (_) {
    return null;
  }
}

const {IMG_PREFIX} = require("./common");
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

/** Fetches a job photo as base64, or null; only our own bucket is allowed. */
async function fetchInlineImage(photoUrl) {
  try {
    if (typeof photoUrl !== "string" || !photoUrl.startsWith(IMG_PREFIX)) {
      return null;
    }
    const res = await fetch(photoUrl, {signal: AbortSignal.timeout(5000)});
    if (!res.ok) return null;
    const mimeType = res.headers.get("content-type") || "";
    if (!mimeType.startsWith("image/")) return null;
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length === 0 || buf.length > MAX_IMAGE_BYTES) return null;
    return {mimeType, data: buf.toString("base64")};
  } catch (_) {
    return null;
  }
}

/**
 * Serves the post-a-job assists by `kind` ('price' or 'draft').
 * Returns the suggestion or null; the client treats null as a soft miss.
 */
exports.suggestJobDetails = functions
    .runWith({secrets: [geminiKey]})
    .https.onCall(async (data, context) => {
      callerUid(context); // signed-in users only
      const kind = data.kind;
      const category = String(data.category || "").slice(0, 60);
      const roughText = String(data.roughText || "").trim().slice(0, 600);
      const photoUrl = data.photoUrl;
      if (kind !== "price" && kind !== "draft") {
        throw new functions.https.HttpsError(
            "invalid-argument", "Unknown kind.");
      }
      if (roughText.length < 3) {
        throw new functions.https.HttpsError(
            "invalid-argument", "Tell us a bit more first.");
      }

      try {
        const ai = new GoogleGenAI({apiKey: geminiKey.value()});

        const config = kind === "draft" ? {
          systemInstruction: DRAFT_SYSTEM,
          temperature: 0.4,
          maxOutputTokens: 768,
          responseMimeType: "application/json",
          responseSchema: DRAFT_SCHEMA,
          thinkingConfig: {thinkingLevel: ThinkingLevel.MINIMAL},
        } : {
          systemInstruction: PRICE_SYSTEM,
          temperature: 0.2,
          maxOutputTokens: 256,
          responseMimeType: "application/json",
          responseSchema: PRICE_SCHEMA,
          thinkingConfig: {thinkingLevel: ThinkingLevel.MINIMAL},
        };
        // A draft has no category yet; the model picks it.
        const text = kind === "draft" ?
            `Customer's note: ${roughText}` :
            `Category: ${category}\nJob description: ${roughText}`;

        const img = photoUrl ? await fetchInlineImage(photoUrl) : null;
        let contents;
        if (img) {
          contents = [{text}, {inlineData: img}];
          config.mediaResolution = MediaResolution.MEDIA_RESOLUTION_LOW;
        } else {
          contents = text;
        }

        const response = await ai.models.generateContent({
          model: GEMINI_MODEL,
          contents,
          config,
        });
        const responseText = response.text;
        if (kind === "draft") return parseDraftJson(responseText);
        return parsePriceJson(responseText);
      } catch (err) {
        const status = typeof err?.status === "number" ? err.status :
            (typeof err?.code === "number" ? err.code : null);
        // 400/403/404 are config bugs, so log them as errors; other failures
        // are soft misses. Never log the API key or request body.
        if (status === 400 || status === 403 || status === 404) {
          functions.logger.error("assist MISCONFIGURED",
              {status, model: GEMINI_MODEL, kind});
        } else {
          functions.logger.info("assist soft-miss (quota/offline/transient)",
              {status, kind});
        }
        return null; // advisory only - never a hard failure
      }
    });

// Triggers defined in other modules, re-exported so the Firebase CLI
// finds them.

exports.extractSsmDocument = require("./ssm").extractSsmDocument;
exports.savePayoutMethod = require("./payout_method").savePayoutMethod;
exports.extractIdDocument = require("./idcheck").extractIdDocument;

exports.createBundle = require("./bundles").createBundle;
exports.submitBundleBid = require("./bundles").submitBundleBid;
exports.withdrawBundleBid = require("./bundles").withdrawBundleBid;
exports.cancelBundle = require("./bundles").cancelBundle;
exports.previewBundleAward = require("./bundle_award").previewBundleAward;
exports.awardBundle = require("./bundle_award").awardBundle;
exports.closeExpiredBundles = require("./bundles").closeExpiredBundles;
