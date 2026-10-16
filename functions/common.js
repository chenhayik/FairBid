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
 * Output: The caller's uid; throws `unauthenticated` when signed out.
 */
function callerUid(context) {
  if (!context.auth) {
    throw new functions.https.HttpsError(
        "unauthenticated", "You must be signed in.");
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
 * Output: Nothing; throws `permission-denied` unless `users/{uid}` is an admin.
 */
async function assertAdmin(uid, tx = null) {
  const ref = admin.firestore().doc(`users/${uid}`);
  const snap = await (tx ? tx.get(ref) : ref.get());
  if (snap.data()?.role !== "admin") {
    throw new functions.https.HttpsError(
        "permission-denied", "Only an admin can do this.");
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
 * What:   Balance guard for taking [requiredSen] out of a wallet.
 * Input:  A user doc's data, [requiredSen] and the error [message].
 * Output: Nothing; throws `failed-precondition` with `reason`, `shortfallSen`,
 *         `availableSen` and `requiredSen` (the app reads them) when short.
 * Notes:  Ignores the legacy `escrowLockedSen`: nothing writes or releases it,
 *         so a value left on an old doc would cap the wallet forever.
 */
function assertCanPay(wallet, requiredSen, message) {
  const available = wallet.walletBalanceSen || 0;
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

exports.callerUid = callerUid;
exports.bad = bad;
exports.docId = docId;
exports.assertAdmin = assertAdmin;
exports.throwIfSuspended = throwIfSuspended;
exports.assertCanPay = assertCanPay;
exports.jobRole = jobRole;
exports.counterpartyUid = counterpartyUid;
exports.notifyUser = notifyUser;
exports.logJobEvent = logJobEvent;
exports.ESCROW = ESCROW;
exports.appendLedger = appendLedger;
exports.writeFundedMilestone = writeFundedMilestone;
exports.IMG_PREFIX = IMG_PREFIX;
