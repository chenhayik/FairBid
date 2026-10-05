// Leaf module: helpers shared by bundles.js and bundle_award.js.
// Requires only firebase-admin, never those two, to avoid a require cycle.

const admin = require("firebase-admin");
const {FieldValue} = require("firebase-admin/firestore");

// The project's Storage download-URL prefix, for "is this our upload" checks.
const IMG_PREFIX =
  "https://firebasestorage.googleapis.com/v0/b/fairbid-c9340.firebasestorage.app/o/";

/** Queues a notification for [uid] inside the caller's transaction. */
function notifyUser(tx, uid, {type, title, body, route = null}) {
  if (!uid) return; // defensive: never write to users/undefined
  const ref = admin.firestore()
      .collection("users").doc(uid).collection("notifications").doc();
  tx.set(ref, {
    type, title, body, route,
    read: false,
    createdAt: FieldValue.serverTimestamp(),
  });
}

/** `fromUid`/`toUid` sentinel for the escrow leg of a fund/release entry. */
const ESCROW = "escrow";

/** Adds an entry to the `transactions` ledger, in the caller's transaction. */
function appendLedger(txOrBatch, entry) {
  const ref = admin.firestore().collection("transactions").doc();
  txOrBatch.set(ref, {
    ...entry,
    createdAt: FieldValue.serverTimestamp(),
  });
}

/** Writes a funded stage and its `fund` ledger entry (default: "Full job"). */
// The caller writes the wallet and the job's `fundedAtAward` flag.
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

exports.notifyUser = notifyUser;
exports.ESCROW = ESCROW;
exports.appendLedger = appendLedger;
exports.writeFundedMilestone = writeFundedMilestone;
exports.IMG_PREFIX = IMG_PREFIX;
