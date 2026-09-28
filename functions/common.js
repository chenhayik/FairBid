// Leaf module: helpers shared by bundles.js and bundle_award.js.
// Requires only firebase-admin, never those two, to avoid a require cycle.

const admin = require("firebase-admin");
const {FieldValue} = require("firebase-admin/firestore");

// The project's Storage download-URL prefix, shared so every "is this one
// of our uploaded images" check (AI assist, handover photos) uses one value.
const IMG_PREFIX =
  "https://firebasestorage.googleapis.com/v0/b/fairbid-c9340.firebasestorage.app/o/";

/**
 * Queues a notification for [uid], written through the caller's transaction
 * so it commits/aborts with the event it describes - mirrors notify() in index.js.
 */
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

exports.notifyUser = notifyUser;
exports.IMG_PREFIX = IMG_PREFIX;
