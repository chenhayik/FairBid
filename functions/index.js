const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const {FieldValue, Timestamp} = require("firebase-admin/firestore");
const {defineSecret} = require("firebase-functions/params");
const {GoogleGenAI, Type, ThinkingLevel, MediaResolution} =
    require("@google/genai");
const {computeTrust, reviewRatingDelta} = require("./trust");
const {
  callerUid, docId, assertAdmin, assertTwoFactor, throwIfSuspended,
  assertCanPay, jobRole,
  counterpartyUid, notifyUser, logJobEvent, ESCROW, appendLedger,
  writeFundedMilestone, IMG_PREFIX, walletRef, balanceOf, adjustWallet,
} = require("./common");
const {
  disputeRefundPlan, canCancelFunded, cancellationPlan, planIncrease,
  planDecrease, finishedByDecrease,
} = require("./payouts");
const {completesJob, validatePriceChange} = require("./price_change");
const bundles = require("./bundles");
const bundleAward = require("./bundle_award");
const scheduling = require("./scheduling");
const payoutMethod = require("./payout_method");
const ssm = require("./ssm");
const idcheck = require("./idcheck");
const {withBusyRetry, errorStatus} = require("./gemini_retry");
const aiQuota = require("./ai_quota");

admin.initializeApp();

/**
 * What:   Auth trigger that removes a deleted account's data.
 * Input:  The deleted Auth user (1st-gen only, so firebase-functions/v1).
 * Output: Profile tree and ID photos deleted; the IC reservation too unless
 *         the user was suspended.
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
   // The AI assist counter (ai_quota.js) sits outside the profile tree.
  await db.doc(`aiUsage/${user.uid}`).delete().catch(() => {});
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

/**
 * What:   Recomputes and stores one user's Trust Score.
 * Input:  [userRef]; reads `users/{uid}` and its `private/payout` doc (phone).
 * Output: `trustScore` and `trust` updated via trust.js; skipped when nothing
 *         changed, which stops a trigger loop.
 */
async function refreshTrust(userRef) {
  const [userSnap, payoutSnap] = await Promise.all([
    userRef.get(),
    userRef.collection("private").doc("payout").get(),
  ]);
  if (!userSnap.exists) return;
  const user = userSnap.data();
  const trust = computeTrust(user, payoutSnap.data() || {});

  const stored = user.trust || {};
  const unchanged = user.trustScore === trust.composite &&
      ["reviewScore", "trackRecordScore", "verificationScore",
        "profileScore", "scoreVisible"]
          .every((key) => stored[key] === trust[key]);
  if (unchanged) return;

  await userRef.update({
    trustScore: trust.composite,
    trust: {...trust, computedAt: FieldValue.serverTimestamp()},
  });
}

/**
 * What:   Trigger that keeps a user's Trust Score current.
 * Input:  Every write to `users/{uid}`.
 * Output: `trustScore` and `trust` updated via trust.js; skipped when nothing
 *         changed, which stops a trigger loop.
 */
exports.recomputeTrustOnUserWrite = functions.firestore
    .document("users/{uid}")
    .onWrite(async (change) => {
        if (!change.after.exists) return;
        await refreshTrust(change.after.ref);
     });

 /**
  * What:   Trigger that refreshes the Trust Score when the phone changes.
  * Input:  A write to `users/{uid}/private/payout`.
  * Output: Score refreshed by refreshTrust; skipped if the phone is the same.
  */
 exports.recomputeTrustOnPhoneWrite = functions.firestore
     .document("users/{uid}/private/payout")
     .onWrite(async (change, context) => {
       const before = change.before.exists ? change.before.data().phone : null;
       const after = change.after.exists ? change.after.data().phone : null;
       if (before === after) return;
       await refreshTrust(admin.firestore().doc(`users/${context.params.uid}`));
     });


/**
 * What:   Trigger that adds a new review's rating to the reviewee's totals.
 * Input:  A new `users/{revieweeId}/reviews/{reviewId}` doc.
 * Output: `ratingSum` and `ratingCount` bumped once; `countedInTrust` on the
 *         review stops retries counting twice.
 */
exports.recomputeTrustScore = functions.firestore
    .document("users/{revieweeId}/reviews/{reviewId}")
    .onCreate(async (snapshot, context) => {
      const rating = snapshot.data().rating;
      const userRef = admin.firestore().doc(`users/${context.params.revieweeId}`);
      const reviewRef = snapshot.ref;

      await admin.firestore().runTransaction(async (tx) => {
        if ((await tx.get(reviewRef)).data()?.countedInTrust === true) return;
        tx.update(userRef, {
          ratingSum: FieldValue.increment(rating),
          ratingCount: FieldValue.increment(1),
        });
        tx.update(reviewRef, {countedInTrust: true});
      });
    });

/**
 * What:   Trigger that credits both people when a job completes.
 * Input:  A `jobs/{jobId}` update to status "completed".
 * Output: +1 `jobsCompleted` each; a bundle counts once per person (markers in
 *         `bundles/{id}/completionCounts`) and `completionCounted` blocks retries.
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
        const [jobSnap, ...markerSnaps] =
            await tx.getAll(jobRef, ...markerRefs);
        if (jobSnap.data()?.completionCounted === true) return;

        participants.filter((uid, i) => !markerSnaps[i]?.exists).forEach((uid) => {
          tx.update(db.doc(`users/${uid}`),
              {jobsCompleted: FieldValue.increment(1)});
          if (bundleId) {
            tx.set(db.doc(`bundles/${bundleId}/completionCounts/${uid}`), {
              jobId: jobRef.id,
              at: FieldValue.serverTimestamp(),
            });
          }
        });
        tx.update(jobRef, {completionCounted: true});
      });
    });

/**
 * What:   Job-counter updater for a requestor.
 * Input:  [uid] and {postedDelta, assignedDelta} to add (default 0).
 * Output: `jobsPosted` and `jobsAssigned` bumped in one transaction; `hireRate`
 *         recalculated, or removed while no jobs are posted (not shown as 0%).
 */
async function bumpRequestorCounters(uid, {postedDelta = 0, assignedDelta = 0}) {
  const db = admin.firestore();
  const ref = db.doc(`users/${uid}`);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return;
    const data = snap.data() || {};
    const jobsPosted = (data.jobsPosted || 0) + postedDelta;
    const jobsAssigned = (data.jobsAssigned || 0) + assignedDelta;
    tx.update(ref, {
      jobsPosted,
      jobsAssigned,
      hireRate: jobsPosted > 0 ?
          Math.round((jobsAssigned / jobsPosted) * 100) :
          FieldValue.delete(),
    });
  });
}

/**
 * What:   Trigger that counts a posted job.
 * Input:  A new `jobs/{jobId}` doc.
 * Output: The requestor's `jobsPosted` +1 and `hireRate` recalculated.
 */
exports.bumpJobsPostedOnCreate = functions.firestore
    .document("jobs/{jobId}")
    .onCreate(async (snap) => {
      const requestorId = snap.data()?.requestorId;
      if (!requestorId) return;
      await bumpRequestorCounters(requestorId, {postedDelta: 1});
    });

/**
 * What:   Trigger that counts an assigned job.
 * Input:  A `jobs/{jobId}` update from "open" to "in_progress".
 * Output: The requestor's `jobsAssigned` +1 and `hireRate` recalculated.
 */
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

/**
 * What:   Validator for a client-sent sen amount.
 * Input:  [amountSen] from the callable's data.
 * Output: [amountSen]; throws `invalid-argument` unless a positive integer.
 */
function checkAmount(amountSen) {
  if (!Number.isInteger(amountSen) || amountSen <= 0) {
    throw new functions.https.HttpsError(
        "invalid-argument", "Enter a valid amount.");
  }
  return amountSen;
}

/**
 * What:   Suspension guard inside a transaction.
 * Input:  [tx] and the caller [uid]; reads `users/{uid}`.
 * Output: Nothing; throws `permission-denied` when suspended.
 * Notes:  Call it before any write. Suspended users can read, but can't take
 *         money or work actions.
 */
async function assertNotSuspended(tx, uid) {
  throwIfSuspended(
      (await tx.get(admin.firestore().doc(`users/${uid}`))).data());
}

/**
 * What:   Milestone rows for the payout rules.
 * Input:  A milestones query snapshot.
 * Output: [{id, ...milestone data}].
 */
const milestoneRows = (snap) => snap.docs.map((d) => ({id: d.id, ...d.data()}));

/**
 * What:   Callable for the requestor to accept one bid on an open job.
 * Input:  {jobId, providerId} from bid_repository.dart.
 * Output: Bid accepted, other pending bids rejected, the amount moved to
 *         escrow as stage m0; job in_progress.
 * Notes:  Throws failed-precondition with reason "race" or "insufficient_balance".
 */
exports.acceptBid = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = docId(data.jobId, "jobId");
  const providerId = docId(data.providerId, "providerId");
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const bidsRef = jobRef.collection("bids");
  const winnerRef = bidsRef.doc(providerId);

  await db.runTransaction(async (tx) => {
    const [jobSnap, winnerSnap, userSnap, walletSnap, pendingBids] =
        await Promise.all([
          tx.get(jobRef),
          tx.get(winnerRef),
          tx.get(db.doc(`users/${uid}`)),
          tx.get(walletRef(db, uid)),
          tx.get(bidsRef.where("status", "==", "pending")),
        ]);
    const user = userSnap.data() || {};
    throwIfSuspended(user);
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
    // Use the stored bid amount, never client input.
    const amount = checkAmount(winner.amountSen);
    assertCanPay(walletSnap, user, amount,
        "Insufficient available balance to accept this bid.");

    tx.update(winnerRef, {status: "accepted"});
    pendingBids.docs
        .filter((bid) => bid.id !== providerId)
        .forEach((bid) => tx.update(bid.ref, {status: "rejected"}));
    adjustWallet(tx, db, uid, -amount);
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
      schedulingRequired: true,
    });
  });
});

/**
 * What:   Callable for the requestor to release a delivered stage.
 * Input:  {jobId, milestoneId} from milestone_repository.dart.
 * Output: Provider paid and notified; the last stage completes the job.
 */
exports.releaseMilestone = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = docId(data.jobId, "jobId");
  const milestoneId = docId(data.milestoneId, "milestoneId");
  functions.logger.info("releaseMilestone requested",
      {uid, jobId, milestoneId});
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestoneRef = jobRef.collection("milestones").doc(milestoneId);

  await db.runTransaction(async (tx) => {
    await assertNotSuspended(tx, uid);
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
    const amountSen = milestoneSnap.data().amountSen;

    adjustWallet(tx, db, job.acceptedProviderId, amountSen);
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
    notifyUser(tx, job.acceptedProviderId, {
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

/**
 * What:   Per-top-up cap, in sen.
 * Output: 1,000,000 (RM 10,000); keep in sync with PlatformConfig.maxTopUpSen.
 */
const MAX_TOPUP_SEN = 1000000; // RM 10,000

/**
 * What:   Wallet balance cap, in sen.
 * Output: 5,000,000 (RM 50,000), so repeated top-ups can't mint unlimited
 *         money; keep in sync with PlatformConfig.maxWalletBalanceSen.
 */
const MAX_WALLET_BALANCE_SEN = 5000000; // RM 50,000

/**
 * What:   Emulator check.
 * Output: True only in the Firebase emulator; deployed functions never set it.
 */
const isEmulator = () => process.env.FUNCTIONS_EMULATOR === "true";

/**
 * What:   Per-top-up cap guard.
 * Input:  [amountSen], the callable name [fn] for the log, caller [uid].
 * Output: Nothing; throws `invalid-argument` when over MAX_TOPUP_SEN.
 */
function capTopUp(amountSen, fn, uid) {
  if (amountSen > MAX_TOPUP_SEN) {
    functions.logger.error(`${fn} rejected: over per-call cap`,
        {uid, amountSen, capSen: MAX_TOPUP_SEN});
    throw new functions.https.HttpsError(
        "invalid-argument", "Top-ups are capped at RM 10,000.");
  }
}

/**
 * What:   Callable that tops up the wallet with no real payment.
 * Input:  {amountSen} from wallet_repository.dart.
 * Output: Wallet credited and a ledger entry written.
 * Notes:  Emulator only; matches PlatformConfig.demoTopUpEnabled. Real top-ups
 *         use toyyibPay.
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
  capTopUp(amountSen, "topUpWallet", uid);
  const db = admin.firestore();

  await db.runTransaction(async (tx) => {
    const [userSnap, walletSnap] = await Promise.all([
      tx.get(db.doc(`users/${uid}`)),
      tx.get(walletRef(db, uid)),
    ]);
    throwIfSuspended(userSnap.data());
    const balance = balanceOf(walletSnap, userSnap.data());
    if (balance + amountSen > MAX_WALLET_BALANCE_SEN) {
      functions.logger.error("topUpWallet rejected: over wallet cap",
          {uid, amountSen, balance, capSen: MAX_WALLET_BALANCE_SEN});
      throw new functions.https.HttpsError(
          "failed-precondition", "Wallet balance is capped at RM 50,000.");
    }
    adjustWallet(tx, db, uid, amountSen);
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

/**
 * What:   Callable that withdraws from the caller's available balance.
 * Input:  {amountSen} from wallet_repository.dart.
 * Output: Wallet debited, ledger entry and receipt written.
 * Notes:  Needs a payout method past its 24-hour hold; rejects overdrafts.
 */
exports.withdrawFromWallet = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const amountSen = checkAmount(data.amountSen);
  functions.logger.info("withdrawFromWallet requested", {uid, amountSen});
  const db = admin.firestore();
  const userRef = db.doc(`users/${uid}`);

  await db.runTransaction(async (tx) => {
    const [userSnap, walletSnap, methodSnap, payoutSnap] = await Promise.all([
      tx.get(userRef),
      tx.get(walletRef(db, uid)),
      tx.get(userRef.collection("private").doc("payoutMethod")),
      tx.get(userRef.collection("private").doc("payout")),
    ]);
    throwIfSuspended(userSnap.data());
    await assertTwoFactor(uid, userSnap.data()?.role);
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
        payoutMethod.normaliseMobile(
            payoutSnap.data()?.phone ?? userSnap.data()?.phone) !==
            method.mobile) {
      throw new functions.https.HttpsError("failed-precondition",
          "Your profile phone number changed. Update your DuitNow payout " +
          "method to match it first.");
    }
    const balance = balanceOf(walletSnap, userSnap.data());
    if (balance < amountSen) {
      functions.logger.error("withdrawFromWallet rejected: insufficient balance",
          {uid, amountSen, balance});
      throw new functions.https.HttpsError(
          "failed-precondition", "Insufficient wallet balance.");
    }
    adjustWallet(tx, db, uid, -amountSen);
    appendLedger(tx, {
      fromUid: uid,
      toUid: null,
      amountSen,
      type: "withdraw",
      participantIds: [uid],
    });
    notifyUser(tx, uid, {
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

const toyyibpaySecret = defineSecret("TOYYIBPAY_SECRET_KEY");
const TOYYIBPAY_BASE = "https://dev.toyyibpay.com";
const TOYYIBPAY_CATEGORY = "0zghdj8k";
const TOYYIBPAY_RETURN_URL = "https://fairbid-c9340.web.app/payment-return";
const TOYYIBPAY_CALLBACK_URL =
    "https://us-central1-fairbid-c9340.cloudfunctions.net/toyyibpayCallback";

/**
 * What:   Callable that creates a toyyibPay bill.
 * Input:  {amountSen} from wallet_repository.dart.
 * Output: {billCode, paymentUrl}; a `topups/{billCode}` record is stored.
 * Notes:  Same caps as topUpWallet; no money moves until the bill is paid.
 */
exports.createToyyibpayBill = functions.runWith({secrets: [toyyibpaySecret]})
    .https.onCall(async (data, context) => {
      const uid = callerUid(context);
      const amountSen = checkAmount(data.amountSen);
      functions.logger.info("createToyyibpayBill requested", {uid, amountSen});
      capTopUp(amountSen, "createToyyibpayBill", uid);
      const db = admin.firestore();
      const [userSnap, walletSnap] = await Promise.all([
        db.doc(`users/${uid}`).get(),
        walletRef(db, uid).get(),
      ]);
      const user = userSnap.data() || {};
      if (user.suspended === true) {
        functions.logger.error("createToyyibpayBill rejected: suspended user",
            {uid});
      }
      throwIfSuspended(user);
      if (balanceOf(walletSnap, user) + amountSen > MAX_WALLET_BALANCE_SEN) {
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
        createdAt: FieldValue.serverTimestamp(),
      });
      functions.logger.info("createToyyibpayBill created",
          {uid, amountSen, billCode});
      return {billCode, paymentUrl: `${TOYYIBPAY_BASE}/${billCode}`};
    });

/**
 * What:   Credits a paid toyyibPay bill to the wallet, at most once.
 * Input:  [billCode]; asks toyyibPay for the bill's payments and reads
 *         `topups/{billCode}`.
 * Output: `{credited, reason}`; reason is not_paid, unknown_bill,
 *         amount_mismatch, already_credited or credited. Used by the webhook
 *         and the reconcile call.
 * How:    The paid ringgit text is converted to sen and must equal the amount
 *         we stored; the credit, topup status and ledger entry share one
 *         transaction.
 * Notes:  Paid money is always credited, even if it passes the wallet cap.
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

  // toyyibPay gives the amount as ringgit text ("10.00"); convert to sen.
  const paidSen = Math.round(parseFloat(paid.billpaymentAmount) * 100);
  const topupRef = db.doc(`topups/${billCode}`);

  return db.runTransaction(async (tx) => {
    const rec = (await tx.get(topupRef)).data();
    if (!rec) {
      functions.logger.error("creditToyyibpayTopup: unknown bill", {billCode});
      return {credited: false, reason: "unknown_bill"};
    }
    if (paidSen !== rec.amountSen) {
      functions.logger.error("toyyibpay amount mismatch",
          {billCode, expected: rec.amountSen, got: paidSen});
      return {credited: false, reason: "amount_mismatch"};
    }
    // Idempotency guard: the webhook and reconcile can both arrive.
    if (rec.status === "credited") {
      functions.logger.info("creditToyyibpayTopup: already credited",
          {billCode, uid: rec.uid, amountSen: rec.amountSen});
      return {credited: true, reason: "already_credited"};
    }

    const [userSnap, walletSnap] = await Promise.all([
      tx.get(db.doc(`users/${rec.uid}`)),
      tx.get(walletRef(db, rec.uid)),
    ]);
    const newBalance = balanceOf(walletSnap, userSnap.data()) + rec.amountSen;
    if (newBalance > MAX_WALLET_BALANCE_SEN) {
      // Paid money is always credited; the cap is only a pre-check.
      functions.logger.warn("toyyibpay credit exceeds wallet cap",
          {billCode, uid: rec.uid, newBalance});
    }
    adjustWallet(tx, db, rec.uid, rec.amountSen);
    tx.update(topupRef, {
      status: "credited",
      creditedAt: FieldValue.serverTimestamp(),
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
 * What:   toyyibPay's webhook (HTTP POST).
 * Input:  Form body with `billcode`.
 * Output: 200 once decided (credited or rejected); 500 only when toyyibPay's
 *         API can't be reached, so it retries.
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
 * What:   Callable backup for a missed webhook.
 * Input:  {billCode} from wallet_repository.dart, after the payment WebView closes.
 * Output: {credited}; the caller must own the bill.
 */
exports.reconcileToyyibpayTopup =
    functions.runWith({secrets: [toyyibpaySecret]})
        .https.onCall(async (data, context) => {
          const uid = callerUid(context);
          const billCode = docId(data.billCode, "billCode");
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
 * What:   Admin callable that rules on a flagged review.
 * Input:  {revieweeId, reviewId, hide} from moderation_repository.dart.
 * Output: Hiding removes the rating from the reviewee's totals and notifies
 *         them; un-hiding a hidden review adds it back; keeping just clears
 *         the flag.
 */
exports.moderateReview = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const revieweeId = docId(data.revieweeId, "revieweeId");
  const reviewId = docId(data.reviewId, "reviewId");
  const hide = data.hide === true;
  const db = admin.firestore();
  const userRef = db.doc(`users/${revieweeId}`);
  const reviewRef = userRef.collection("reviews").doc(reviewId);

  await db.runTransaction(async (tx) => {
    await assertAdmin(uid, tx);
    const [userSnap, reviewSnap] = await Promise.all([
      tx.get(userRef), tx.get(reviewRef),
    ]);
    const review = reviewSnap.data();
    if (!review) {
      throw new functions.https.HttpsError("not-found", "Review not found.");
    }

    // Hiding takes the rating out; un-hiding puts it back. Moderating a
    // review twice the same way changes nothing.
    const delta = reviewRatingDelta(review, hide);
    if (delta.count !== 0) {
      tx.update(userRef, {
        ratingSum: Math.max(0, (userSnap.data()?.ratingSum || 0) + delta.sum),
        ratingCount:
            Math.max(0, (userSnap.data()?.ratingCount || 0) + delta.count),
      });
    }
    tx.update(reviewRef, {
      flagged: false,
      hidden: hide,
      moderatedAt: FieldValue.serverTimestamp(),
    });
    if (hide) {
      notifyUser(tx, revieweeId, {
        type: "review",
        title: "A review was removed",
        body: "A review you reported was taken down after moderation, and " +
            "your Trust Score has been adjusted.",
        route: "/profile",
      });
    }
  });
});

/**
 * What:   Admin callable that suspends or reinstates a user.
 * Input:  {uid, suspended, reason?} from user_admin_repository.dart.
 * Output: `suspended` fields set (blocks the app and money callables); the
 *         user is notified either way.
 */
exports.setUserSuspended = functions.https.onCall(async (data, context) => {
  const callerId = callerUid(context);
  const targetUid = docId(data.uid, "uid");
  const suspend = data.suspended === true;
  const reason = typeof data.reason === "string" ? data.reason.trim() : "";
  const db = admin.firestore();
  const targetRef = db.doc(`users/${targetUid}`);

  await db.runTransaction(async (tx) => {
    await assertAdmin(callerId, tx);
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
      suspendedAt: FieldValue.serverTimestamp(),
      suspendedBy: callerId,
    } : {
      suspended: false,
      suspensionReason: null,
      suspendedAt: null,
      suspendedBy: null,
    });
    notifyUser(tx, targetUid, suspend ? {
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
 * What:   Admin callable that clears a user's 2FA.
 * Input:  {uid} from user_admin_repository.dart.
 * Output: All enrolled factors removed and refresh tokens revoked, so the old
 *         session ends.
 */
exports.adminClearMfa = functions.https.onCall(async (data, context) => {
  const callerId = callerUid(context);
  const targetUid = docId(data.uid, "uid");
  await assertAdmin(callerId);

  await admin.auth().updateUser(targetUid, {
    multiFactor: {enrolledFactors: null},
  });
  await admin.auth().revokeRefreshTokens(targetUid);
});

// Disputes. Raising one freezes the milestone; an admin ruling pays out escrow.

/**
 * What:   `rulingNote` of disputes closed when another one ended the job.
 * Output: A string; backfillTrust uses it to skip those disputes.
 */
const AUTO_CLOSED_NOTE = "Closed because the job ended after another dispute.";

/**
 * What:   Callable for a participant to dispute a funded or delivered stage.
 * Input:  {jobId, milestoneId, statement, evidenceUrls?} from dispute_repository.dart.
 * Output: Stage frozen as "disputed" and a dispute created; no money moves
 *         until an admin rules.
 */
exports.raiseDispute = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = docId(data.jobId, "jobId");
  const milestoneId = docId(data.milestoneId, "milestoneId");
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
    await assertNotSuspended(tx, uid);
    const [jobSnap, milestoneSnap] =
        await Promise.all([tx.get(jobRef), tx.get(milestoneRef)]);
    const job = jobSnap.data();
    const role = jobRole(job, uid);
    if (!role) {
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
      raisedByRole: role,
      requestorId: job.requestorId,
      providerId: job.acceptedProviderId,
      statement,
      evidenceUrls,
      conversationId: `${jobId}_${job.acceptedProviderId}`,
      participantIds: [job.requestorId, job.acceptedProviderId],
      status: "open",
      resolution: null,
      rulingNote: null,
      createdAt: FieldValue.serverTimestamp(),
      resolvedAt: null,
      ...(job.bundleId ? {bundleId: job.bundleId} : {}),
    });
    notifyUser(tx, counterpartyUid(job, role), {
      type: "dispute",
      title: "A dispute was raised",
      body: `The ${role === "requestor" ? "client" : "provider"} disputed ` +
          `"${milestone.description}" on "${job.title}". An admin will ` +
          "review it.",
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * What:   Callable for the raiser to withdraw an open dispute.
 * Input:  {jobId, milestoneId} from dispute_repository.dart.
 * Output: The stage returns to where it was (funded or delivered); no money
 *         moves; the other party is notified.
 */
exports.withdrawDispute = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = docId(data.jobId, "jobId");
  const milestoneId = docId(data.milestoneId, "milestoneId");
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestoneRef = jobRef.collection("milestones").doc(milestoneId);
  const openQuery = db.collection("disputes")
      .where("jobId", "==", jobId)
      .where("milestoneId", "==", milestoneId)
      .where("status", "==", "open");

  await db.runTransaction(async (tx) => {
    await assertNotSuspended(tx, uid);
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
      resolvedAt: FieldValue.serverTimestamp(),
    });
    const isRequestor = dispute.raisedByRole === "requestor";
    notifyUser(tx, isRequestor ? job.acceptedProviderId : job.requestorId, {
      type: "dispute",
      title: "Dispute withdrawn",
      body: `The ${isRequestor ? "client" : "provider"} withdrew their ` +
          `dispute on "${job.title}". The work carries on as before.`,
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * What:   Admin callable that rules on an open dispute.
 * Input:  {disputeId, resolution: "release"|"refund", rulingNote?} from
 *         dispute_repository.dart.
 * Output: release: provider paid. refund: every held stage refunded and the
 *         job cancelled. Both parties are notified.
 */
exports.resolveDispute = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const disputeId = docId(data.disputeId, "disputeId");
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
    await assertAdmin(uid, tx);
    const disputeSnap = await tx.get(disputeRef);
    const dispute = disputeSnap.data();
    if (dispute?.status !== "open") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This dispute has already been closed.");
    }

    const jobRef = db.doc(`jobs/${dispute.jobId}`);
    const milestonesRef = jobRef.collection("milestones");
    const milestoneRef = milestonesRef.doc(dispute.milestoneId);
    const providerRef = db.doc(`users/${dispute.providerId}`);
    const [milestoneSnap, allMilestones, jobSnap, openOnJob] =
        await Promise.all([
          tx.get(milestoneRef),
          tx.get(milestonesRef),
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
      adjustWallet(tx, db, dispute.providerId, amountSen);
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
      adjustWallet(tx, db, dispute.requestorId, refundedSen);
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
        cancelledAt: FieldValue.serverTimestamp(),
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
          rulingNote: AUTO_CLOSED_NOTE,
          resolvedAt: FieldValue.serverTimestamp(),
        });
      }
      // A ruling against the provider counts against their track record.
      tx.update(providerRef, {disputesLost: FieldValue.increment(1)});
    }
    tx.update(disputeRef, {
      status: "resolved",
      resolution,
      rulingNote: rulingNote || null,
      resolvedAt: FieldValue.serverTimestamp(),
    });
    const note = rulingNote ? ` Admin's note: "${rulingNote}"` : "";
    notifyUser(tx, dispute.providerId, {
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
    notifyUser(tx, dispute.requestorId, {
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
 * Moves one user's legacy `walletBalanceSen` (on the user doc) into their
 * private wallet and deletes the field, in one transaction. Safe to re-run:
 * once the field is gone there is nothing left to move. Returns true if a
 * field was moved.
 */
function migrateLegacyWallet(db, userRef) {
  return db.runTransaction(async (tx) => {
    const legacy = (await tx.get(userRef)).data()?.walletBalanceSen;
    if (legacy === undefined) return false;
    if (Number.isFinite(legacy) && legacy !== 0) {
      adjustWallet(tx, db, userRef.id, legacy);
    }
    tx.update(userRef, {walletBalanceSen: FieldValue.delete()});
    return true;
  });
}

/**
 * What:   Admin callable that recounts every user's trust counters and moves
 *         legacy wallet balances.
 * Input:  None (stats_repository.dart); safe to re-run.
 * Output: `jobsCompleted` and `disputesLost` rewritten from jobs and disputes
 *         with the live rules (bundle once per person; auto-closed disputes
 *         don't count), then every user's Trust Score recomputed. Each user's
 *         old `walletBalanceSen` on the user doc is moved to
 *         `users/{uid}/private/wallet` (one transaction each). Returns
 *         {users, walletsMoved}.
 */
exports.backfillTrust = functions.https.onCall(async (data, context) => {
  await assertAdmin(callerUid(context));
  const db = admin.firestore();
  const [users, jobs, refunds] = await Promise.all([
    db.collection("users").get(),
    db.collection("jobs").where("status", "==", "completed").get(),
    db.collection("disputes").where("resolution", "==", "refund").get(),
  ]);

  const completed = new Map(); // uid -> job ids (a bundle counts as one)
  for (const doc of jobs.docs) {
    const job = doc.data();
    const key = job.bundleId ? `bundle:${job.bundleId}` : doc.id;
    for (const uid of [job.acceptedProviderId, job.requestorId]) {
      if (uid) completed.set(uid, (completed.get(uid) ?? new Set()).add(key));
    }
  }
  const lost = new Map(); // providerId -> disputes ruled against them
  for (const doc of refunds.docs) {
    const {providerId, rulingNote} = doc.data();
    if (rulingNote !== AUTO_CLOSED_NOTE) {
      lost.set(providerId, (lost.get(providerId) ?? 0) + 1);
    }
  }

  // Fix the counters, then recompute the score directly: a write that
  // changes nothing does not fire the trust trigger.
  let walletsMoved = 0;
  for (const doc of users.docs) {
    if (await migrateLegacyWallet(db, doc.ref)) walletsMoved++;
    await doc.ref.update({
      jobsCompleted: completed.get(doc.id)?.size ?? 0,
      disputesLost: lost.get(doc.id) ?? 0,
    });
    await refreshTrust(doc.ref);
  }
  return {users: users.size, walletsMoved};
});

// Job cancellation: one side asks, the other accepts (an admin can override).
// It never strands escrow: it is blocked, or the money is refunded.

const STAGE_DELIVERED_MESSAGE =
    "A delivered or disputed stage must be released or resolved before " +
    "this job can be cancelled.";

/**
 * What:   Cancellation guard.
 * Input:  A milestones query snapshot.
 * Output: Why the job can't be cancelled now, or null if it can.
 */
function cancellationBlocker(milestonesSnap) {
  return canCancelFunded(milestoneRows(milestonesSnap)) ?
    null : STAGE_DELIVERED_MESSAGE;
}

/**
 * What:   Cancels the job and settles its money.
 * Input:  [tx], [jobRef], [job] data, the milestones snapshot and the
 *         [cancelledBy] value.
 * Output: Unfunded stages deleted, funded stages refunded to the requestor's
 *         wallet with ledger entries, job set to "cancelled".
 * Notes:  The caller checks authority and cancellationBlocker() first.
 */
function finaliseCancellation(tx, jobRef, job, milestonesSnap, cancelledBy) {
  const plan = cancellationPlan(milestoneRows(milestonesSnap));
  for (const id of plan.deleteIds) {
    tx.delete(jobRef.collection("milestones").doc(id));
  }
  const refundSen = plan.refunds.reduce((sum, r) => sum + r.amountSen, 0);
  if (refundSen > 0) {
    adjustWallet(tx, admin.firestore(), job.requestorId, refundSen);
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
    cancelledAt: FieldValue.serverTimestamp(),
    cancellationRequestedBy: null,
    cancellationRequestedAt: null,
    priceChangeRequest: null,
  });
}

/**
 * What:   Callable for either party to ask to cancel an in-progress job.
 * Input:  {jobId, reason?} from job_repository.dart.
 * Output: `cancellationRequestedBy` set and the other side notified.
 * Notes:  Refused while a stage is delivered or disputed.
 */
exports.requestJobCancellation =
  functions.https.onCall(async (data, context) => {
    const uid = callerUid(context);
    const jobId = docId(data.jobId, "jobId");
    const reason = typeof data.reason === "string" ? data.reason.trim() : "";
    const db = admin.firestore();
    const jobRef = db.doc(`jobs/${jobId}`);
    const milestonesRef = jobRef.collection("milestones");

    await db.runTransaction(async (tx) => {
      await assertNotSuspended(tx, uid);
      const [jobSnap, milestones] = await Promise.all([
        tx.get(jobRef),
        tx.get(milestonesRef),
      ]);
      const job = jobSnap.data();
      const role = jobRole(job, uid);
      if (!role) {
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
        cancellationRequestedBy: role,
        cancellationReason: reason || null,
        cancellationRequestedAt: FieldValue.serverTimestamp(),
      });
      notifyUser(tx, counterpartyUid(job, role), {
        type: "cancellation",
        title: "Cancellation requested",
        body: `The ${role === "requestor" ? "client" : "provider"} asked to ` +
            `cancel "${job.title}". Accept or decline from the job page.`,
        route: `/jobs/${jobId}`,
      });
    });
  });

/**
 * What:   Callable for the other party to accept or decline a cancellation.
 * Input:  {jobId, accept} from job_repository.dart.
 * Output: Accept re-checks the escrow guard, refunds held stages and cancels
 *         the job; decline clears the request. The requester is notified.
 */
exports.respondToJobCancellation =
  functions.https.onCall(async (data, context) => {
    const uid = callerUid(context);
    const jobId = docId(data.jobId, "jobId");
    const accept = data.accept === true;
    const db = admin.firestore();
    const jobRef = db.doc(`jobs/${jobId}`);
    const milestonesRef = jobRef.collection("milestones");

    await db.runTransaction(async (tx) => {
      await assertNotSuspended(tx, uid);
      const [jobSnap, milestones] = await Promise.all([
        tx.get(jobRef),
        tx.get(milestonesRef),
      ]);
      const job = jobSnap.data();
      if (job?.status !== "in_progress" || !job.cancellationRequestedBy) {
        throw new functions.https.HttpsError(
            "failed-precondition", "There is no pending cancellation request.");
      }
      const role = jobRole(job, uid);
      if (!role) {
        throw new functions.https.HttpsError(
            "permission-denied", "Only the job's participants can respond.");
      }
      if (role === job.cancellationRequestedBy) {
        throw new functions.https.HttpsError(
            "failed-precondition",
            "You raised this request; the other party must respond.");
      }

      const requesterUid = counterpartyUid(job, role);
      if (!accept) {
        tx.update(jobRef, {
          cancellationRequestedBy: null,
          cancellationReason: null,
          cancellationRequestedAt: null,
        });
        notifyUser(tx, requesterUid, {
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
      finaliseCancellation(tx, jobRef, job, milestones, uid);
      notifyUser(tx, requesterUid, {
        type: "cancellation",
        title: "Job cancelled",
        body: `Both parties agreed: "${job.title}" has been cancelled.`,
        route: `/jobs/${jobId}`,
      });
    });
  });

// Price change. Either party proposes a new price; the other accepts or declines.
// `acceptedBidAmountSen` is the live price; checks are in price_change.js.

/**
 * What:   Callable for either party to propose a new job price.
 * Input:  {jobId, newAmountSen, reason} from job_repository.dart.
 * Output: `priceChangeRequest` set and the other side notified; nothing else
 *         changes until they accept.
 */
exports.requestPriceChange = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = docId(data.jobId, "jobId");
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
    await assertNotSuspended(tx, uid);
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
        requestedAt: FieldValue.serverTimestamp(),
      },
    });
    notifyUser(tx, counterpartyUid(job, role), {
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
 * What:   Money move for an accepted price change on a funded-at-award job.
 * Input:  [tx] and {job, jobRef, milestonesRef, rows, delta} where [delta] is
 *         the new price minus the old, in sen.
 * Output: Increase: private wallet to escrow, growing the only funded stage or
 *         adding a "Price change" stage. Decrease: refund from funded stages.
 *         Ledger entry written; returns true when the decrease finished the
 *         job.
 */
function repriceFundedStages(tx, {job, jobRef, milestonesRef, rows, delta}) {
  const db = admin.firestore();
  const ledger = {
    jobId: jobRef.id,
    jobTitle: job.title || null,
    participantIds: [job.requestorId],
  };
  if (delta > 0) {
    adjustWallet(tx, db, job.requestorId, -delta);
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
  adjustWallet(tx, db, job.requestorId, refundSen);
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
 * What:   Callable for the other party to accept or decline a price change.
 * Input:  {jobId, accept} from job_repository.dart.
 * Output: Accept re-checks the change, moves the money, updates the price and
 *         logs it; decline clears the request. Both sides are notified.
 * Notes:  Throws failed-precondition with reason "insufficient_balance".
 */
exports.respondToPriceChange =
  functions.https.onCall(async (data, context) => {
    const uid = callerUid(context);
    const jobId = docId(data.jobId, "jobId");
    const accept = data.accept === true;
    const db = admin.firestore();
    const jobRef = db.doc(`jobs/${jobId}`);
    const milestonesRef = jobRef.collection("milestones");

    await db.runTransaction(async (tx) => {
      await assertNotSuspended(tx, uid);
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
        notifyUser(tx, requesterUid, {
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
      const [requestorSnap, walletSnap] = await Promise.all([
        tx.get(db.doc(`users/${job.requestorId}`)),
        tx.get(walletRef(db, job.requestorId)),
      ]);
      const problem = validatePriceChange({
        job, milestones: milestones.docs.map((d) => d.data()),
        newAmountSen: newSen,
      });
      if (problem) {
        throw new functions.https.HttpsError("failed-precondition", problem);
      }
      const delta = newSen - oldSen;
      if (delta > 0) {
        assertCanPay(walletSnap, requestorSnap.data() || {}, delta,
            "Insufficient available balance to accept this price change.");
      }

      const completed = repriceFundedStages(tx, {
        job, jobRef, milestonesRef, rows: milestoneRows(milestones), delta,
      });
      const count = (job.priceChangeCount || 0) + 1;
      tx.update(jobRef, {
        acceptedBidAmountSen: newSen,
        originalBidAmountSen: job.originalBidAmountSen ?? oldSen,
        priceChangeCount: count,
        priceChangeRequest: null,
        ...(completed ? {status: "completed"} : {}),
      });
      logJobEvent(jobId, `price_change_${count}`, "price_changed",
          `Price changed: ${rm(oldSen)} → ${rm(newSen)}`, tx);
      const body = `The price of "${job.title}" is now ${rm(newSen)}. ` +
          (delta > 0 ?
              "The extra amount has been moved into escrow." :
              "The difference was refunded to the client.");
      notifyUser(tx, requesterUid, {
        type: "price_change", title: "Price change accepted", body,
        route: `/jobs/${jobId}`,
      });
      notifyUser(tx, uid, {
        type: "price_change", title: "Price changed", body,
        route: `/jobs/${jobId}`,
      });
    });
  });

/**
 * What:   Callable for the proposer to take back a price change.
 * Input:  {jobId} from job_repository.dart.
 * Output: `priceChangeRequest` cleared and the other party notified.
 */
exports.withdrawPriceChange = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = docId(data.jobId, "jobId");
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
    notifyUser(tx, counterpartyUid(job, role), {
      type: "price_change",
      title: "Price change withdrawn",
      body: `The price change request for "${job.title}" was withdrawn.`,
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * What:   Scheduled sweep (every 6 hours) for open jobs past their deadline.
 * Input:  Jobs with status "open" and `deadline` in the past (needs the index
 *         in firestore.indexes.json, Cloud Scheduler and the Blaze plan).
 * Output: Each is cancelled with cancelledBy "system".
 */
exports.closeExpiredJobs = functions.pubsub
    .schedule("every 6 hours")
    .onRun(async () => {
      const db = admin.firestore();
      const snap = await db.collection("jobs")
          .where("status", "==", "open")
          .where("deadline", "<=", Timestamp.now())
          .get();
      // A batch holds at most 500 writes.
      for (let i = 0; i < snap.docs.length; i += 500) {
        const batch = db.batch();
        snap.docs.slice(i, i + 500).forEach((doc) => batch.update(doc.ref, {
          status: "cancelled",
          cancelledBy: "system",
          cancelledAt: FieldValue.serverTimestamp(),
          cancellationReason: "Bidding deadline passed, no bid was accepted.",
        }));
        await batch.commit();
      }
      functions.logger.info(`closeExpiredJobs: closed ${snap.size} job(s)`);
    });

/**
 * What:   Chat grace period after a job ends.
 * Output: 14 days in ms; after it the chat is read-only (kept as evidence).
 */
const CHAT_GRACE_MS = 14 * 24 * 60 * 60 * 1000;

/**
 * What:   Trigger that closes a job's chat 14 days after the job ends.
 * Input:  A `jobs/{jobId}` update that moves it to or from completed/cancelled.
 * Output: The conversation's `chatClosesAt` set (or cleared); it never creates
 *         a conversation or deletes messages.
 */
exports.closeChatOnJobEnd = functions.firestore
    .document("jobs/{jobId}")
    .onUpdate(async (change, context) => {
      const before = change.before.data();
      const after = change.after.data();
      const ended = after.status === "completed" || after.status === "cancelled";
      const wasEnded =
          before.status === "completed" || before.status === "cancelled";
      if (ended === wasEnded) return;
      if (!after.acceptedProviderId) return;

      const convRef = admin.firestore().doc(
          `conversations/${context.params.jobId}_${after.acceptedProviderId}`);
      const snap = await convRef.get();
      if (!snap.exists) return;
      await convRef.update({
        chatClosesAt: ended ?
            Timestamp.fromMillis(Date.now() + CHAT_GRACE_MS) :
            null,
      });
    });

// Notifications. Code queues them with notifyUser (common.js); a trigger
// then sends the FCM push.

/**
 * What:   Money formatter for notification copy.
 * Input:  [sen].
 * Output: e.g. `RM 1,234.50`.
 */
function rm(sen) {
  return `RM ${(sen / 100).toLocaleString("en-MY",
      {minimumFractionDigits: 2, maximumFractionDigits: 2})}`;
}

/**
 * What:   FCM error codes that mean a device token is dead.
 * Output: Strings; onNotificationCreated removes tokens that return them.
 */
const DEAD_TOKEN_CODES = [
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
];

/**
 * What:   Trigger that send notification as an FCM push.
 * Input:  A new `users/{uid}/notifications/{id}` doc.
 * Output: A push to the user's devices; dead tokens are removed.
 * Notes:  Best-effort; the in-app list is the source of truth.
 */
exports.onNotificationCreated = functions.firestore
    .document("users/{uid}/notifications/{notificationId}")
    .onCreate(async (snap, context) => {
      const {uid} = context.params;
      const n = snap.data();
      const userRef = admin.firestore().doc(`users/${uid}`);
      const tokens = (await userRef.get()).data()?.fcmTokens || [];
      if (tokens.length === 0) return;

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

      const dead = tokens.filter((_, i) =>
        DEAD_TOKEN_CODES.includes(res.responses[i].error?.code));
      if (dead.length > 0) {
        await userRef.update({fcmTokens: FieldValue.arrayRemove(...dead)});
      }
    });

/**
 * What:   Trigger that tells the requestor about a new bid.
 * Input:  A new `jobs/{jobId}/bids/{bidId}` doc (a client write).
 * Output: A "bid_received" notification.
 */
exports.onBidCreated = functions.firestore
    .document("jobs/{jobId}/bids/{bidId}")
    .onCreate(async (snap, context) => {
      const bid = snap.data();
      const jobSnap = await admin.firestore()
          .doc(`jobs/${context.params.jobId}`).get();
      const job = jobSnap.data();
      if (!job?.requestorId) return;
      await notifyUser(null, job.requestorId, {
        type: "bid_received",
        title: "New bid on your job",
        body: `${bid.providerName || "A provider"} bid ` +
            `${rm(bid.amountSen || 0)} on "${job.title}".`,
        route: `/jobs/${context.params.jobId}`,
      });
    });

/**
 * What:   Trigger that tells the winning provider their bid was accepted.
 * Input:  A bid update whose status became "accepted".
 * Output: A "bid_accepted" notification; losers aren't notified.
 */
exports.onBidAccepted = functions.firestore
    .document("jobs/{jobId}/bids/{bidId}")
    .onUpdate(async (change, context) => {
      const before = change.before.data();
      const after = change.after.data();
      if (before.status === after.status || after.status !== "accepted") return;
      const jobSnap = await admin.firestore()
          .doc(`jobs/${context.params.jobId}`).get();
      await notifyUser(null, context.params.bidId, {
        type: "bid_accepted",
        title: "Your bid was accepted!",
        body: `You won "${jobSnap.data()?.title || "a job"}" for ` +
            `${rm(after.amountSen || 0)}. The payment is secured in escrow ` +
            "- you can get started.",
        route: `/jobs/${context.params.jobId}`,
      });
    });

/**
 * What:   Trigger that tells the requestor work was delivered.
 * Input:  A milestone update whose status became "submitted".
 * Output: A "milestone" notification asking them to review and release.
 */
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
      await notifyUser(null, job.requestorId, {
        type: "milestone",
        title: "Work delivered",
        body: `${job.acceptedProviderName || "Your provider"} marked ` +
            `"${after.description || job.title}" as delivered. Review it ` +
            `and release ${rm(after.amountSen || 0)}.`,
        route: `/jobs/${context.params.jobId}`,
      });
    });

/**
 * What:   Trigger that notifies the other chat participant.
 * Input:  A new message in `conversations/{id}/messages`.
 * Output: A "message" notification to everyone but the sender.
 */
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
      await notifyUser(null, recipientId, {
        type: "message",
        title: senderName || "New message",
        body: (message.text || "").length > 80 ?
            `${message.text.slice(0, 77)}...` : (message.text || ""),
        route: `/messages/${context.params.conversationId}`,
      });
    });

/**
 * What:   Trigger that tells the applicant their verification was decided.
 * Input:  A `users/{uid}` update that changed `verificationStatus` to
 *         "approved" or "rejected".
 * Output: A "verification" notification; the uploaded ID and SSM documents are
 *         deleted now that a human has ruled.
 */
exports.onVerificationDecided = functions.firestore
    .document("users/{uid}")
    .onUpdate(async (change, context) => {
      const before = change.before.data().verificationStatus;
      const after = change.after.data().verificationStatus;
      if (before === after) return;
      if (after !== "approved" && after !== "rejected") return;
      const approved = after === "approved";
      await notifyUser(null, context.params.uid, {
        type: "verification",
        title: approved ? "You're verified!" : "Verification rejected",
        body: approved ?
            "Your documents were approved. You now have full marketplace " +
            "access." :
            "Your documents were not approved. Re-submit them from your " +
            "profile to unlock the marketplace.",
        route: "/home",
      });
      await ssm.deleteSsmDocument(context.params.uid);
      await idcheck.deleteIdDocuments(context.params.uid);
    });

/**
 * What:   Trigger that tells a user they received a review.
 * Input:  A new `users/{revieweeId}/reviews/{id}` doc.
 * Output: A "review" notification.
 */
exports.onReviewCreated = functions.firestore
    .document("users/{revieweeId}/reviews/{reviewId}")
    .onCreate(async (snap, context) => {
      const review = snap.data();
      await notifyUser(null, context.params.revieweeId, {
        type: "review",
        title: "You received a review",
        body: `${review.reviewerName || "Someone"} rated you ` +
            `${review.rating}★${review.jobTitle ?
                ` on "${review.jobTitle}"` : ""}.`,
        route: "/profile",
      });
    });

// Job timeline: server-written events at `jobs/{jobId}/events/{eventId}`.
// Fixed event ids make trigger retries safe (overwrite, not duplicate).

/**
 * What:   Trigger that starts a job's timeline.
 * Input:  A new `jobs/{jobId}` doc.
 * Output: A "Job posted" event.
 */
exports.logJobPosted = functions.firestore.document("jobs/{jobId}")
    .onCreate((snap, ctx) =>
      logJobEvent(ctx.params.jobId, "posted", "posted", "Job posted"));

/**
 * What:   Trigger that logs job status changes on the timeline.
 * Input:  A `jobs/{jobId}` update; only assigned, completed and cancelled count.
 * Output: One timeline event for the change.
 */
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

/**
 * What:   Trigger that logs milestone status changes on the timeline.
 * Input:  A write to `jobs/{jobId}/milestones/{milestoneId}`.
 * Output: One timeline event per status change; deletions are ignored.
 */
exports.logMilestoneStatusChange = functions.firestore
    .document("jobs/{jobId}/milestones/{milestoneId}")
    .onWrite((change, ctx) => {
      const before = change.before.exists ? change.before.data() : null;
      const after = change.after.exists ? change.after.data() : null;
      if (!after || before?.status === after.status) return null;
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

const geminiKey = defineSecret("GEMINI_KEY");
const GEMINI_MODEL = "gemini-3.1-flash-lite";

/**
 * What:   System instruction for the fair-price guide.
 * Output: Prompt text sent to Gemini by suggestJobDetails.
 */
const PRICE_SYSTEM = "You estimate fair market prices for home services " +
    "in Malaysia. Give a realistic ringgit range for the job described, " +
    "based only on what it states. If a photo is provided, factor it in. " +
    "Never invent a price from an assumed brand name, measurement, or " +
    "detail the description does not give. Do not use em dashes.";

/**
 * What:   System instruction for the one-shot post draft.
 * Output: Prompt text sent to Gemini by suggestJobDetails.
 */
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

/**
 * What:   Structured-output schema for the one-shot draft.
 * Output: Gemini must reply with title, category, description, minRm, maxRm.
 */
const DRAFT_SCHEMA = {
  type: Type.OBJECT,
  properties: {
    title: {type: Type.STRING},
    category: {type: Type.STRING, enum: bundles.CATEGORIES},
    description: {type: Type.STRING},
    minRm: {type: Type.NUMBER},
    maxRm: {type: Type.NUMBER},
  },
  required: ["title", "category", "description", "minRm", "maxRm"],
  propertyOrdering: ["title", "category", "description", "minRm", "maxRm"],
};

/**
 * What:   Structured-output schema for the fair-price guide.
 * Output: Gemini must reply with a ringgit range, minRm and maxRm.
 */
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
 * What:   Parser for the model's price reply.
 * Input:  The reply [text] (JSON).
 * Output: `{minSen, maxSen}`, or null when bad (not numbers, min not above 0,
 *         max under min or over RM 1,000,000).
 * Notes:  try/catch because a cut-off reply can still throw.
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

/**
 * What:   Parser for the model's draft reply.
 * Input:  The reply [text] (JSON).
 * Output: `{title, category, description, minSen, maxSen}`, or null when
 *         unusable (blank title or description, unknown category).
 * Notes:  The price range may be null; it reuses parsePriceJson's checks.
 */
function parseDraftJson(text) {
  try {
    const draft = JSON.parse(String(text));
    const title = String(draft.title || "").trim().slice(0, 120);
    const description = String(draft.description || "").trim();
    const category = String(draft.category || "").trim();
    if (title === "" || description === "") return null;
    if (!bundles.CATEGORIES.includes(category)) return null;
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

/**
 * What:   Size limit for a photo sent to the model.
 * Output: 5 MB, in bytes.
 */
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

/**
 * What:   Photo fetcher for the model.
 * Input:  A job [photoUrl]; only URLs in our own bucket (IMG_PREFIX) pass.
 * Output: `{mimeType, data}` with base64 data, or null on any failure,
 *         non-image or size over MAX_IMAGE_BYTES.
 */
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
 * What:   Callable for the post-a-job assists.
 * Input:  {kind: "price"|"draft", roughText, category?, photoUrl?} from
 *         assist_repository.dart.
 * Output: The parsed suggestion, or null; the client treats null as a soft miss.
 */
exports.suggestJobDetails = functions
    .runWith({secrets: [geminiKey]})
    .https.onCall(async (data, context) => {
      const uid = callerUid(context); // signed-in users only
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
      // Daily allowance: one unit per button press, taken before Gemini is
      // asked. The busy retries in withBusyRetry happen inside this same
      // call, so they never use up the allowance.
      const db = admin.firestore();
      if (!(await aiQuota.reserveAiCall(db, uid))) {
        throw new functions.https.HttpsError("resource-exhausted",
            `You have used today's ${aiQuota.DAILY_AI_LIMIT} AI ` +
            "suggestions. Please try again tomorrow.");
      }



      try {
        const ai = new GoogleGenAI({apiKey: geminiKey.value()});

        const draft = kind === "draft";
        const config = {
          systemInstruction: draft ? DRAFT_SYSTEM : PRICE_SYSTEM,
          temperature: draft ? 0.4 : 0.2,
          maxOutputTokens: draft ? 768 : 256,
          responseMimeType: "application/json",
          responseSchema: draft ? DRAFT_SCHEMA : PRICE_SCHEMA,
          thinkingConfig: {thinkingLevel: ThinkingLevel.MINIMAL},
        };
        // A draft has no category yet; the model picks it.
        const text = draft ?
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

        // Gemini often answers 503/429 for a moment, so retry those briefly.
        const response = await withBusyRetry(
            () => ai.models.generateContent({
              model: GEMINI_MODEL,
              contents,
              config,
            }),
            {
              onRetry: ({status, attempt}) => functions.logger.info(
                  "assist retrying after busy reply", {status, attempt, kind}),
            });
        // `response.text` is a getter, so read it once.
        const reply = response.text;
        const result = draft ? parseDraftJson(reply) : parsePriceJson(reply);
        if (result === null) {
          // Metadata only: the reply text echoes the user's note.
          functions.logger.warn("assist unusable reply", {
            kind,
            replyLength: typeof reply === "string" ? reply.length : null,
            finishReason: response.candidates?.[0]?.finishReason ?? null,
          });
        }
        return result;
      } catch (err) {
        const status = errorStatus(err);
        // 400/403/404 are config bugs, so log them as errors; other failures
        // are soft misses. Never log the API key or request body.
        if (status === 400 || status === 403 || status === 404) {
          functions.logger.error("assist MISCONFIGURED",
              {status, model: GEMINI_MODEL, kind});
        } else {
          functions.logger.info("assist soft-miss (quota/offline/transient)",
              {status, kind});
        }
        // Gemini gave no answer, so give the unit back (best effort).
        await aiQuota.refundAiCall(db, uid).catch(() => {});
        return null;
      }
    });

// Functions defined in other modules, re-exported so the Firebase CLI finds them.

exports.extractSsmDocument = ssm.extractSsmDocument;
exports.extractIdDocument = idcheck.extractIdDocument;
exports.savePayoutMethod = payoutMethod.savePayoutMethod;

exports.createBundle = bundles.createBundle;
exports.submitBundleBid = bundles.submitBundleBid;
exports.withdrawBundleBid = bundles.withdrawBundleBid;
exports.cancelBundle = bundles.cancelBundle;
exports.closeExpiredBundles = bundles.closeExpiredBundles;
exports.previewBundleAward = bundleAward.previewBundleAward;
exports.awardBundle = bundleAward.awardBundle;

exports.proposeAppointment = scheduling.proposeAppointment;
exports.respondToAppointment = scheduling.respondToAppointment;
exports.withdrawAppointmentProposal = scheduling.withdrawAppointmentProposal;
exports.markOnTheWay = scheduling.markOnTheWay;
exports.markArrived = scheduling.markArrived;
exports.sendVisitReminders = scheduling.sendVisitReminders;
