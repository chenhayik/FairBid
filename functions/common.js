// Leaf module: helpers shared by every backend file. Requires only
// firebase-admin and firebase-functions, so it can't create a require cycle.

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const {FieldValue} = require("firebase-admin/firestore");

/**
 * What:   Firebase Storage URL prefix our uploaded images start with.
 * Output: A string; fetchInlineImage() only accepts URLs that start with it.
 */
const IMG_PREFIX =
  "https://firebasestorage.googleapis.com/v0/b/fairbid-c9340.firebasestorage.app/o/";

/**
 * What:   Auth guard for callables.
 * Input:  The callable [context].
 * Output: The caller's uid; throws `unauthenticated` when signed out and
 *         `failed-precondition` when the email is not verified.
 * Notes:  Reads `email_verified` from the ID token, so it costs no lookup.
 */
function callerUid(context) {
  if (!context.auth) {
    throw new functions.https.HttpsError(
        "unauthenticated", "You must be signed in.");
  }
  if (context.auth.token?.email_verified !== true) {
    throw new functions.https.HttpsError(
        "failed-precondition", "Verify your email address first.");
  }
  return context.auth.uid;
}

/**
 * What:   Error builder.
 * Input:  A message the user can read.
 * Output: An `invalid-argument` HttpsError, used as `throw bad("...")`.
 */
function bad(message) {
  return new functions.https.HttpsError("invalid-argument", message);
}

/**
 * What:   Validator for a client-sent document id.
 * Input:  [value] and the field [name] for the error message.
 * Output: [value]; throws `invalid-argument` if it isn't a safe id.
 */
function docId(value, name) {
  if (typeof value !== "string" || value.trim() === "" ||
      value.length > 1500 || value.includes("/")) {
    throw bad(`${name} is missing.`);
  }
  return value;
}

/**
 * What:   Admin guard.
 * Input:  [uid]; optional [tx] to read inside a transaction.
 * Output: Nothing; throws `permission-denied` unless `users/{uid}` is an
 *         admin, and `failed-precondition` if that admin has no 2FA.
 */
async function assertAdmin(uid, tx = null) {
  const ref = admin.firestore().doc(`users/${uid}`);
  const snap = await (tx ? tx.get(ref) : ref.get());
  if (snap.data()?.role !== "admin") {
    throw new functions.https.HttpsError(
        "permission-denied", "Only an admin can do this.");
  }
  await assertTwoFactor(uid, "admin");
}

/**
 * What:   Two-factor guard for providers and admins.
 * Input:  [uid] and the [role] from their user doc; Firebase Auth getUser().
 * Output: Nothing; throws `failed-precondition` when a provider or admin has
 *         no second factor enrolled.
 * Notes:  Requestors pass, since 2FA is optional for them.
 */
async function assertTwoFactor(uid, role) {
  if (role !== "provider" && role !== "admin") return;
  const user = await admin.auth().getUser(uid);
  if (!user.multiFactor?.enrolledFactors?.length) {
    throw new functions.https.HttpsError("failed-precondition",
        "Turn on two-factor authentication first.");
  }
}

/**
 * What:   Suspension guard.
 * Input:  A user doc's data (read earlier, before any writes).
 * Output: Nothing; throws `permission-denied` when `suspended` is true.
 */
function throwIfSuspended(user) {
  if (user?.suspended === true) {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Your account is suspended. Contact support if you think this is " +
        "a mistake.");
  }
}

/**
 * What:   Where a user's spendable balance lives.
 * Input:  The Firestore [db] and a [uid].
 * Output: The ref `users/{uid}/private/wallet` (only the owner and admins can
 *         read it; clients can never write it).
 */
function walletRef(db, uid) {
  return db.doc(`users/${uid}/private/wallet`);
}


/**
 * What:   Adds or takes money from a user's private wallet.
 * Input:  A transaction or batch, the [db], a [uid] and [deltaSen] (negative
 *         to debit).
 * Output: Nothing; a merge-set increment, so it works if the doc is missing.
 */
function adjustWallet(txOrBatch, db, uid, deltaSen) {
  txOrBatch.set(walletRef(db, uid),
      {walletBalanceSen: FieldValue.increment(deltaSen)}, {merge: true});
}
/**
 * What:   A user's balance in sen.
 * Input:  The private wallet snapshot and the user doc's data (both read in
 *         the same transaction; either may be missing).
 * Output: private `walletBalanceSen` + legacy `walletBalanceSen` on the user
 *         doc. The legacy part is moved by the admin backfill; until then the
 *         private number can be negative and only the sum counts.
 */
function balanceOf(walletSnap, userData) {
  return (walletSnap?.data()?.walletBalanceSen || 0) +
      (userData?.walletBalanceSen || 0);
}


/**
 * What:   Balance guard for taking [requiredSen] out of a wallet.
 * Input:  The private wallet snapshot, the user doc's data, [requiredSen] and
 *         the error [message].
 * Output: Nothing; throws `failed-precondition` with `reason`, `shortfallSen`,
 *         `availableSen` and `requiredSen` (the app reads them) when short.
 * Notes:  Ignores the legacy `escrowLockedSen`: nothing writes or releases it,
 *         so a value left on an old doc would cap the wallet forever.
 */
function assertCanPay(walletSnap, userData, requiredSen, message) {
  const available = balanceOf(walletSnap, userData);
  if (available < requiredSen) {
    throw new functions.https.HttpsError("failed-precondition", message, {
      reason: "insufficient_balance",
      shortfallSen: requiredSen - available,
      availableSen: available,
      requiredSen,
    });
  }
}

/**
 * What:   Writes a funded stage and its `fund` ledger entry.
 * Input:  [tx], and {jobRef, title, requestorId, providerId, amountSen,
 *         order = 0, description = "Full job"}.
 * Output: The stage `m{order}`; the caller writes the wallet and `fundedAtAward`.
 */
function writeFundedMilestone(tx, {jobRef, title, requestorId, providerId,
  amountSen, order = 0, description = "Full job"}) {
  const milestoneRef = jobRef.collection("milestones").doc(`m${order}`);
  tx.set(milestoneRef, {
    providerId,
    description,
    amountSen,
    order,
    status: "funded",
    submissionNote: null,
    reworkNote: null,
    reworkCount: 0,
    createdAt: FieldValue.serverTimestamp(),
  });
  appendLedger(tx, {
    fromUid: requestorId,
    toUid: ESCROW,
    amountSen,
    type: "fund",
    jobId: jobRef.id,
    jobTitle: title || null,
    milestoneId: milestoneRef.id,
    participantIds: [requestorId],
  });
}

/**
 * What:   Role lookup on a job.
 * Input:  Job data and a [uid].
 * Output: "requestor", "provider", or null for anyone else.
 */
function jobRole(job, uid) {
  if (job?.requestorId === uid) return "requestor";
  if (job?.acceptedProviderId === uid) return "provider";
  return null;
}

/**
 * What:   Other party on a job.
 * Input:  Job data and the caller's [role] from jobRole().
 * Output: The other participant's uid.
 */
const counterpartyUid = (job, role) =>
  role === "requestor" ? job.acceptedProviderId : job.requestorId;

/**
 * What:   Queues an in-app notification; a trigger sends the push later.
 * Input:  [tx] (transaction or batch, or null to write now), [uid], and
 *         {type, title, body, route}.
 * Output: Nothing in a [tx]; a promise when [tx] is null.
 */
function notifyUser(tx, uid, {type, title, body, route = null}) {
  if (!uid) return null; // never write to users/undefined
  const ref = admin.firestore()
      .collection("users").doc(uid).collection("notifications").doc();
  const entry = {
    type, title, body, route,
    read: false,
    createdAt: FieldValue.serverTimestamp(),
  };
  return tx ? tx.set(ref, entry) : ref.set(entry);
}

/**
 * What:   Writes one job timeline entry at `jobs/{jobId}/events/{eventId}`.
 * Input:  [jobId], [eventId] (null = fresh id), [type], [title], optional [tx].
 * Output: The write; inside [tx] when given.
 * Notes:  A fixed [eventId] makes trigger retries overwrite, not duplicate.
 */
function logJobEvent(jobId, eventId, type, title, tx = null) {
  const events = admin.firestore().collection(`jobs/${jobId}/events`);
  const ref = eventId ? events.doc(eventId) : events.doc();
  const entry = {type, title, at: FieldValue.serverTimestamp()};
  return tx ? tx.set(ref, entry) : ref.set(entry);
}

/**
 * What:   `fromUid`/`toUid` sentinel for the escrow leg of a ledger entry.
 * Output: The string "escrow", used on fund and release entries.
 */
const ESCROW = "escrow";

/**
 * What:   Adds an entry to the `transactions` ledger.
 * Input:  A transaction or batch, and the entry fields.
 * Output: Nothing; the write is part of the caller's commit.
 */
function appendLedger(txOrBatch, entry) {
  const ref = admin.firestore().collection("transactions").doc();
  txOrBatch.set(ref, {
    ...entry,
    createdAt: FieldValue.serverTimestamp(),
  });
}



exports.callerUid = callerUid;
exports.bad = bad;
exports.docId = docId;
exports.assertAdmin = assertAdmin;
exports.assertTwoFactor = assertTwoFactor;
exports.throwIfSuspended = throwIfSuspended;
exports.assertCanPay = assertCanPay;
exports.walletRef = walletRef;
exports.balanceOf = balanceOf;
exports.adjustWallet = adjustWallet;
exports.jobRole = jobRole;
exports.counterpartyUid = counterpartyUid;
exports.notifyUser = notifyUser;
exports.logJobEvent = logJobEvent;
exports.ESCROW = ESCROW;
exports.appendLedger = appendLedger;
exports.writeFundedMilestone = writeFundedMilestone;
exports.IMG_PREFIX = IMG_PREFIX;
