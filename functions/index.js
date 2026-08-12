const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");

admin.initializeApp();

/**
 * When a Firebase Auth account is deleted, remove its Firestore profile so no
 * orphaned `users/{uid}` document (and no phantom entry in the admin
 * verification queue) is left behind. `recursiveDelete` also clears any
 * subcollections such as `reviews`.
 *
 * Auth triggers are 1st-gen only, hence `firebase-functions/v1`.
 */
exports.cleanupUserDoc = functions.auth.user().onDelete(async (user) => {
  const ref = admin.firestore().doc(`users/${user.uid}`);
  await admin.firestore().recursiveDelete(ref);
  functions.logger.info(`Deleted Firestore profile for ${user.uid}`);
});

// ---------------------------------------------------------------------------
// Trust Score v2. The math lives in trust.js (dependency-free so `npm test`
// can vector-check it against the Dart mirror); producers below (review
// triggers, job completion, dispute rulings) write only raw aggregates, and
// the single `recomputeTrustOnUserWrite` consumer turns them into the stored
// `trustScore` + `trust` breakdown - no client, and no other function, ever
// computes the score.
// ---------------------------------------------------------------------------

const {computeTrust} = require("./trust");

/**
 * The single trust-score consumer: whenever a user document is written -
 * profile creation, a profile edit, an admin verification decision, or a
 * counter bump from one of the producers below - recompute the breakdown and
 * store it. Writes only when the result actually changed, which both saves
 * writes and terminates the self-trigger loop (our own write recomputes to an
 * identical breakdown and stops).
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
 * Producer: a new review bumps the reviewee's rating aggregates. The consumer
 * above folds them into the Trust Score. (Server-side so a client can't forge
 * ratings - rules deny client writes to these fields.)
 *
 * Idempotent against at-least-once trigger retries: a `countedInTrust` marker
 * on the review doc itself (set in the same transaction as the increment)
 * means a replayed event sees it already true and returns without
 * double-counting. This is isolated from `moderateReview`'s subtract logic
 * (guarded by its own `!review.hidden` check), which is untouched.
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

/**
 * Producer: when a job completes (last milestone released, or a dispute
 * ruling closed it out), both participants earn a completed job toward their
 * track record. One trigger covers every completion path.
 *
 * Idempotent against at-least-once trigger retries: a `completionCounted`
 * marker is read and set on the job doc inside the same transaction as the
 * increments, so a replayed event sees it already true and returns without
 * double-counting. NOTE: that marker write is itself an update to this same
 * job doc, which re-fires this trigger and `closeChatOnJobEnd` - both no-op
 * on it: `before.status === "completed"` is already true here (the job's
 * status doesn't change again), so this trigger's own guard above returns
 * immediately on the replay; `closeChatOnJobEnd` no-ops because
 * `ended === wasEnded` (both true).
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
      await db.runTransaction(async (tx) => {
        const jobSnap = await tx.get(jobRef);
        if (jobSnap.data()?.completionCounted === true) return; // retried event
        const bump = {
          jobsCompleted: admin.firestore.FieldValue.increment(1),
        };
        if (after.acceptedProviderId) {
          tx.update(db.doc(`users/${after.acceptedProviderId}`), bump);
        }
        if (after.requestorId) {
          tx.update(db.doc(`users/${after.requestorId}`), bump);
        }
        tx.update(jobRef, {completionCounted: true});
      });
    });

// ---------------------------------------------------------------------------
// Requestor job-posting counters (jobsPosted / hireRate) - power the public
// profile's client-history strip (lib/features/profile/domain/
// public_profile.dart). Both fields (plus the jobsAssigned they're derived
// from) are server-owned, exactly like the Trust Score fields above - see
// firestore.rules' trustFields().
// ---------------------------------------------------------------------------

/**
 * Applies [postedDelta]/[assignedDelta] to [uid]'s `jobsPosted`/
 * `jobsAssigned` counters and recomputes `hireRate` (0–100 int, the share of
 * posted jobs that reached an assigned/accepted state) from the result,
 * inside one transaction. No jobs posted yet -> `hireRate` is cleared
 * entirely, never a misleading "0%".
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

/**
 * A job posting bumps its requestor's `jobsPosted` counter. Mirrors
 * `logJobPosted` below (same trigger document, a separate function so the
 * timeline write and the counter write stay independent).
 */
exports.bumpJobsPostedOnCreate = functions.firestore
    .document("jobs/{jobId}")
    .onCreate(async (snap) => {
      const requestorId = snap.data()?.requestorId;
      if (!requestorId) return;
      await bumpRequestorCounters(requestorId, {postedDelta: 1});
    });

/**
 * A job reaching an assigned/accepted state (open -> in_progress, i.e. a bid
 * was accepted) bumps its requestor's `jobsAssigned` counter, the numerator
 * behind `hireRate`.
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

// ---------------------------------------------------------------------------
// Wallet + milestone escrow.
//
// Firestore rules reject every client write to `walletBalanceSen`, to a
// milestone's funded/released status and to the `transactions` ledger, so all
// money movement flows through these callables (the admin SDK bypasses
// rules) - exactly how `recomputeTrustScore` protects the Trust Score.
// ---------------------------------------------------------------------------

/** `fromUid`/`toUid` sentinel for the escrow leg of a fund/release entry. */
const ESCROW = "escrow";

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
 * Throws if `users/{uid}` is suspended. Read inside [tx], before any writes.
 * The soft-suspension gate for state-changing callables: a suspended account
 * keeps read access (so it can still see the "account suspended" screen and
 * its reason) but can take no marketplace or money action. Firestore rules
 * block the direct client writes (jobs, bids, reviews, chat, profile); this
 * covers the money/work callables the admin SDK would otherwise let through.
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

/**
 * Statuses that end a milestone's lifecycle. A job completes only when every
 * milestone is `released` (paid to the provider). A refunded dispute now
 * returns its milestone to `pending` for rework rather than ending it, so a
 * refund can no longer silently "complete" a job. `resolved` is retained here
 * solely so any pre-existing legacy document - the status a refund used to
 * write - can still complete.
 */
const isTerminal = (status) => status === "released" || status === "resolved";

// Max milestones in one plan. Must stay in sync with
// PlatformConfig.maxMilestones (lib/core/config/platform_config.dart).
const MAX_MILESTONES = 20;

/**
 * Appends an entry to the append-only `transactions` ledger in the same
 * transaction/batch as the balance write. `participantIds` holds the entry's
 * real uids (never the escrow sentinel), for the history query.
 */
function appendLedger(txOrBatch, entry) {
  const ref = admin.firestore().collection("transactions").doc();
  txOrBatch.set(ref, {
    ...entry,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

/** A milestone whose money is committed and so can't be re-planned. */
const isLocked = (status) =>
  status === "funded" || status === "submitted" ||
  status === "disputed" || isTerminal(status);

/**
 * Requestor accepts a provider's bid: the winning bid becomes `accepted`,
 * every other still-pending bid on the job is `rejected`, and the job moves
 * to `in_progress` with the winner's fields set. No money moves yet - that
 * happens at `fundMilestone` - but the accepted amount becomes a commitment
 * against the requestor's wallet, tracked as `escrowLockedSen`, so a
 * requestor can't accept more work than their balance can eventually fund.
 * Server-side (this used to be a client Firestore transaction) because both
 * the balance gate and the amount trusted for it need to be tamper-proof;
 * `onBidAccepted`, a Firestore trigger on the bid write, still notifies the
 * winner.
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

  // Transactions can't run queries, so the candidate pending-bid ids are
  // fetched once outside it; each is re-read (and re-validated) by reference
  // inside the transaction, which is what makes the accept safe against a
  // concurrent accept or withdraw.
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
    // Trust only the server-stored bid amount, never client input - but the
    // rules' own amountSen validation could in principle be bypassed by a
    // stale/legacy doc, so re-validate it here too (defense in depth) before
    // it drives the wallet debit below.
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
      // Skip anything withdrawn/resolved since the pre-fetch - nothing to
      // reject.
      if (otherSnaps[i].data()?.status === "pending") {
        tx.update(otherRefs[i], {status: "rejected"});
      }
    }
    tx.update(walletRef, {
      escrowLockedSen: (wallet.escrowLockedSen || 0) + amount,
    });
    tx.update(jobRef, {
      status: "in_progress",
      acceptedProviderId: providerId,
      acceptedProviderName: winner.providerName || null,
      acceptedBidAmountSen: amount,
    });
  });
});

/**
 * Provider proposes (or amends) the milestone plan for their in-progress job.
 * The plan is authored by the provider but only becomes fundable once the
 * requestor approves it (`approveMilestonePlan`), so every milestone is
 * written `proposed`. Server-owned because the amount split is the money
 * contract: it must total the accepted bid exactly (the check that used to
 * live only in the client), and locked milestones - already funded or beyond -
 * can't be re-priced. Any amendment resets the un-locked tail to `proposed`,
 * forcing fresh approval.
 */
exports.proposeMilestonePlan = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const plan = Array.isArray(data.milestones) ? data.milestones : null;
  if (!plan || plan.length === 0) {
    throw new functions.https.HttpsError(
        "invalid-argument", "Propose at least one milestone.");
  }
  if (plan.length > MAX_MILESTONES) {
    throw new functions.https.HttpsError(
        "invalid-argument", `A plan can have at most ${MAX_MILESTONES} ` +
        "milestones.");
  }
  // Normalise + validate each row, keyed by a 0-based order.
  const rows = plan.map((m, i) => ({
    order: i,
    description: typeof m.description === "string" ? m.description.trim() : "",
    amountSen: m.amountSen,
  }));
  for (const row of rows) {
    if (row.description === "") {
      throw new functions.https.HttpsError(
          "invalid-argument", "Every milestone needs a description.");
    }
    checkAmount(row.amountSen);
  }
  const total = rows.reduce((sum, r) => sum + r.amountSen, 0);

  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestonesRef = jobRef.collection("milestones");

  await db.runTransaction(async (tx) => {
    const [jobSnap, existing] = await Promise.all([
      tx.get(jobRef),
      tx.get(milestonesRef),
    ]);
    const job = jobSnap.data();
    if (job?.acceptedProviderId !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied",
          "Only the accepted provider can propose milestones.");
    }
    if (job.status !== "in_progress") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This job is not in progress.");
    }
    if (typeof job.acceptedBidAmountSen !== "number") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This job has no accepted bid amount.");
    }
    if (total !== job.acceptedBidAmountSen) {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "Milestone amounts must add up to the accepted bid.");
    }

    // Locked milestones (funded or beyond) can't be re-planned: the incoming
    // plan must keep each one at the same order and amount, and can't drop it.
    const byId = new Map(existing.docs.map((d) => [d.id, d.data()]));
    for (const [id, m] of byId) {
      if (!isLocked(m.status)) continue;
      const incoming = rows.find((r) => `m${r.order}` === id);
      if (!incoming || incoming.amountSen !== m.amountSen) {
        throw new functions.https.HttpsError(
            "failed-precondition",
            "Can't change a milestone that is already funded or in progress.");
      }
    }

    // Write the plan. Locked rows are left untouched; every other row is
    // (re)written as `proposed`, so any amendment needs fresh approval.
    for (const row of rows) {
      const id = `m${row.order}`;
      const current = byId.get(id);
      if (current && isLocked(current.status)) continue;
      tx.set(milestonesRef.doc(id), {
        providerId: uid,
        description: row.description,
        amountSen: row.amountSen,
        order: row.order,
        status: "proposed",
        submissionNote: null,
        reworkNote: current?.reworkNote ?? null,
        reworkCount: current?.reworkCount ?? 0,
        createdAt: current?.createdAt ??
            admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    // Drop any previously-proposed/pending milestone the amendment removed.
    for (const [id, m] of byId) {
      const stillThere = rows.some((r) => `m${r.order}` === id);
      if (!stillThere && !isLocked(m.status)) {
        tx.delete(milestonesRef.doc(id));
      }
    }
    // A new plan supersedes any earlier rejection note.
    if (job.planRejectionNote) {
      tx.update(jobRef, {planRejectionNote: null});
    }
    notify(tx, job.requestorId, {
      type: "milestone",
      title: "Milestone plan proposed",
      body: `Review the proposed plan for "${job.title}" and approve it to ` +
          "start funding.",
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * Requestor approves the proposed plan: every `proposed` milestone becomes
 * `pending` (fundable). This is the consent step that the unilateral split
 * used to skip.
 */
exports.approveMilestonePlan = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestonesRef = jobRef.collection("milestones");

  await db.runTransaction(async (tx) => {
    const [jobSnap, milestones] = await Promise.all([
      tx.get(jobRef),
      tx.get(milestonesRef),
    ]);
    if (jobSnap.data()?.requestorId !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied", "Only the job's requestor can approve the plan.");
    }
    if (jobSnap.data().status !== "in_progress") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This job is not in progress.");
    }
    const proposed = milestones.docs.filter(
        (d) => d.data().status === "proposed");
    if (proposed.length === 0) {
      throw new functions.https.HttpsError(
          "failed-precondition", "There is no proposed plan to approve.");
    }
    for (const doc of proposed) {
      tx.update(doc.ref, {status: "pending"});
    }
    notify(tx, jobSnap.data().acceptedProviderId, {
      type: "milestone",
      title: "Milestone plan approved",
      body: `The client approved your plan for ` +
          `"${jobSnap.data().title}". Milestones can now be funded.`,
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * Requestor sends the proposed plan back to the provider with a note: the
 * `proposed` milestones are cleared so the provider re-proposes, and the note
 * is stored on the job for them to see.
 */
exports.rejectMilestonePlan = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const note = typeof data.note === "string" ? data.note.trim() : "";
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestonesRef = jobRef.collection("milestones");

  await db.runTransaction(async (tx) => {
    const [jobSnap, milestones] = await Promise.all([
      tx.get(jobRef),
      tx.get(milestonesRef),
    ]);
    if (jobSnap.data()?.requestorId !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied", "Only the job's requestor can reject the plan.");
    }
    const proposed = milestones.docs.filter(
        (d) => d.data().status === "proposed");
    if (proposed.length === 0) {
      throw new functions.https.HttpsError(
          "failed-precondition", "There is no proposed plan to reject.");
    }
    for (const doc of proposed) {
      tx.delete(doc.ref);
    }
    tx.update(jobRef, {planRejectionNote: note || null});
    notify(tx, jobSnap.data().acceptedProviderId, {
      type: "milestone",
      title: "Milestone plan needs changes",
      body: `The client sent your plan for "${jobSnap.data().title}" back` +
          `${note ? `: "${note}"` : "."}`,
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * Requestor funds a pending milestone: their wallet is debited and the money
 * is held in escrow (tracked on the ledger) until they release it.
 */
exports.fundMilestone = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const milestoneId = checkId(data.milestoneId, "milestoneId");
  functions.logger.info("fundMilestone requested", {uid, jobId, milestoneId});
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestoneRef = jobRef.collection("milestones").doc(milestoneId);
  const walletRef = db.doc(`users/${uid}`);

  await db.runTransaction(async (tx) => {
    await assertNotSuspended(tx, db, uid);
    const [jobSnap, milestoneSnap, walletSnap] = await Promise.all(
        [tx.get(jobRef), tx.get(milestoneRef), tx.get(walletRef)]);
    if (jobSnap.data()?.requestorId !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied", "Only the job's requestor can fund milestones.");
    }
    if (jobSnap.data().status !== "in_progress") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This job is not in progress.");
    }
    const milestone = milestoneSnap.data();
    if (milestone?.status !== "pending") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This milestone is not awaiting funding.");
    }
    const wallet = walletSnap.data() || {};
    const balance = wallet.walletBalanceSen || 0;
    if (balance < milestone.amountSen) {
      functions.logger.error("fundMilestone rejected: insufficient balance",
          {uid, jobId, milestoneId, amountSen: milestone.amountSen, balance});
      throw new functions.https.HttpsError(
          "failed-precondition", "Insufficient wallet balance.");
    }

    tx.update(walletRef, {
      walletBalanceSen: balance - milestone.amountSen,
      // This portion of the accepted-bid commitment is now actually
      // escrowed, not just locked against future funding.
      escrowLockedSen:
          Math.max(0, (wallet.escrowLockedSen || 0) - milestone.amountSen),
    });
    tx.update(milestoneRef, {status: "funded"});
    appendLedger(tx, {
      fromUid: uid,
      toUid: ESCROW,
      amountSen: milestone.amountSen,
      type: "fund",
      jobId,
      jobTitle: jobSnap.data().title || null,
      milestoneId,
      participantIds: [uid],
    });
    notify(tx, jobSnap.data().acceptedProviderId, {
      type: "milestone",
      title: "Milestone funded",
      body: `${rm(milestone.amountSen)} is in escrow for ` +
          `"${milestone.description}". You can start work.`,
      route: `/jobs/${jobId}`,
    });
  });
  functions.logger.info("fundMilestone funded", {uid, jobId, milestoneId});
});

/**
 * Requestor releases a submitted milestone: the provider's wallet is credited
 * and, when this was the job's last unreleased milestone, the job completes -
 * the gate that unlocks reviews for both parties.
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
    const wasLast = allMilestones.docs.every(
        (doc) => doc.id === milestoneId || isTerminal(doc.data().status));
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

// Per-top-up cap. Must stay in sync with PlatformConfig.maxTopUpSen
// (lib/core/config/platform_config.dart), the source of truth.
const MAX_TOPUP_SEN = 1000000; // RM 10,000

// Cumulative cap on a single wallet's balance - otherwise a client could loop
// topUpWallet calls (each under the per-call cap) to mint unlimited balance.
// Must stay in sync with PlatformConfig.maxWalletBalanceSen
// (lib/core/config/platform_config.dart), the source of truth.
const MAX_WALLET_BALANCE_SEN = 5000000; // RM 50,000

/**
 * Demo-only top-up that stands in for a payment gateway: credits the caller's
 * own wallet, capped per call (MAX_TOPUP_SEN) and capped in total
 * (MAX_WALLET_BALANCE_SEN) so a tampered - or merely looping - client can't
 * mint absurd balances. A transaction (not a batch) is needed now: the total
 * cap is a balance precondition, so the current balance must be read and
 * checked atomically with the increment.
 */
exports.topUpWallet = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
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
    const walletSnap = await tx.get(walletRef);
    const wallet = walletSnap.data() || {};
    const balance = wallet.walletBalanceSen || 0;
    // Gate on the AVAILABLE balance - money locked against an accepted bid
    // isn't free to withdraw, even though it hasn't left walletBalanceSen yet.
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
    // A receipt to the actor is deliberate here - money leaving the wallet
    // should always leave a visible trace.
    notify(tx, uid, {
      type: "payment",
      title: "Withdrawal complete",
      body: `${rm(amountSen)} was withdrawn from your FairBid balance.`,
      route: "/profile/earnings",
    });
  });
  functions.logger.info("withdrawFromWallet completed", {uid, amountSen});
});

// ---------------------------------------------------------------------------
// toyyibPay (sandbox) wallet top-up - the real payment-gateway path,
// alongside the demo `topUpWallet` above (left untouched). A requestor
// creates a bill here; toyyibPay's hosted page collects payment in a WebView;
// and the money only ever moves in `creditToyyibpayTopup`, which never trusts
// a caller-supplied status - it re-verifies against toyyibPay's own
// `getBillTransactions` API and credits the amount stored in OUR OWN
// `topups/{billCode}` record, never the gateway's. Both `toyyibpayCallback`
// (the webhook) and `reconcileToyyibpayTopup` (a client-driven safety net for
// a dropped callback) share that one helper so the two paths can't diverge.
// ---------------------------------------------------------------------------

const {defineSecret} = require("firebase-functions/params");
const toyyibpaySecret = defineSecret("TOYYIBPAY_SECRET_KEY");
const TOYYIBPAY_BASE = "https://dev.toyyibpay.com";
const TOYYIBPAY_CATEGORY = "0zghdj8k";
const TOYYIBPAY_RETURN_URL = "https://fairbid-c9340.web.app/payment-return";
const TOYYIBPAY_CALLBACK_URL =
    "https://us-central1-fairbid-c9340.cloudfunctions.net/toyyibpayCallback";

/**
 * Requestor starts a real top-up: creates a toyyibPay sandbox bill for
 * `data.amountSen` and returns its hosted payment page for the client to open
 * in a WebView. Capped exactly like `topUpWallet` (per-call and cumulative),
 * so an over-cap top-up can't even be initiated - but no money moves here;
 * that only happens once the bill is independently confirmed paid.
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
        billExternalReferenceNo: uid,
        billTo: user.displayName || "FairBid user",
        billEmail: user.email || "user@fairbid.app",
        // toyyibPay rejects an empty billPhone; fall back to a placeholder
        // when the profile has no phone (it's only used on the receipt).
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
 * The authoritative verify-and-credit for one bill - the actual money path,
 * shared by `toyyibpayCallback` and `reconcileToyyibpayTopup` so they can't
 * diverge. Always re-fetches the bill's transactions from toyyibPay itself
 * (never trusts a caller-supplied status), matches the paid amount against
 * our own stored `topups/{billCode}` record (crediting THAT amount, never the
 * gateway's), and credits the wallet at most once via a transactional
 * re-read. Returns `{credited, reason}`; `reason` is one of `"not_paid"`,
 * `"unknown_bill"`, `"amount_mismatch"`, `"already_credited"` or `"credited"`.
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

  // getBillTransactions reports the ringgit amount as a decimal string
  // ("10.00") - convert to sen before comparing to our own stored amount.
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
      // Genuinely-paid money is credited regardless - the cap is only ever
      // pre-checked at bill creation, never a reason to refuse real funds.
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
    // Mirrors topUpWallet's ledger write exactly, plus a `ref` back to the
    // bill for support/audit lookups.
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
 * toyyibPay's server-to-server webhook - the money path. Answers 200 for
 * every business-logic outcome (paid-but-forged-billcode, amount mismatch,
 * not yet paid, or a genuine credit) so toyyibPay stops retrying once we've
 * made a decision; only an actual failure to reach toyyibPay's API answers
 * 500, so toyyibPay retries and `reconcileToyyibpayTopup` remains the
 * client-driven backstop for the same gap.
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
 * Client-driven safety net for a callback toyyibPay never delivered: the
 * client calls this once the WebView returns. The caller must own the bill;
 * it then runs the exact same verify-and-credit helper as the webhook, so
 * the two paths can never disagree on when money moves.
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
 * Admin ruling on a flagged review. Hiding removes it from public display
 * AND reverses its rating out of the reviewee's aggregates - otherwise a
 * hidden abusive review would keep poisoning the Trust Score. Keeping just
 * clears the flag. Only this function may write `hidden` (rules forbid it).
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
      // The `!review.hidden` guard prevents a double-subtract if the same
      // review is somehow moderated twice. The Trust Score consumer picks the
      // new aggregates up from this write.
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

// ---------------------------------------------------------------------------
// Account suspension (admin moderation).
//
// A soft ban: `setUserSuspended` flips the `suspended` flag on the target's
// profile (an admin can suspend neither themselves nor another admin). The
// flag is server-owned - Firestore rules deny every client write to it, so a
// suspended user can't lift their own ban - and it gates both the client (the
// router sends a suspended user to the "account suspended" screen) and the
// money/work callables (`assertNotSuspended`). Reversible at any time.
// ---------------------------------------------------------------------------

/**
 * Admin suspends or reinstates a user. `data.suspended` is the target state
 * (true = suspend, false = reinstate); `data.reason` is an optional note shown
 * to the user. Notifies the user either way.
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

// ---------------------------------------------------------------------------
// Dispute resolution (plan §3.3.3). Raising a dispute freezes the milestone;
// an admin ruling pays the escrowed amount out. Both live here so the
// milestone flip and the dispute record (and later the money) move in one
// transaction that clients can't forge.
// ---------------------------------------------------------------------------

/**
 * A job participant disputes a funded/delivered milestone: the milestone is
 * frozen (`→ disputed`) and a `disputes/{id}` doc opens for admin review.
 * No money moves until the admin rules.
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

    tx.update(milestoneRef, {status: "disputed"});
    tx.set(disputeRef, {
      jobId,
      jobTitle: job.title || null,
      milestoneId,
      milestoneDescription: milestone.description || "",
      amountSen: milestone.amountSen,
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
 * Admin ruling on an open dispute. `release` pays the escrowed amount to the
 * provider and marks the milestone `released` - terminal, and if it was the
 * job's last one the job completes, unlocking reviews (mirrors
 * `releaseMilestone`). `refund` returns the money to the requestor and sends
 * the milestone back to `pending` for rework (carrying the ruling note), so
 * the worker can re-deliver instead of being stranded - the job stays in
 * progress and never auto-completes off a refund.
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
          "failed-precondition", "This dispute has already been resolved.");
    }

    const jobRef = db.doc(`jobs/${dispute.jobId}`);
    const milestoneRef =
        jobRef.collection("milestones").doc(dispute.milestoneId);
    const beneficiaryUid = resolution === "release" ?
        dispute.providerId : dispute.requestorId;
    const beneficiaryRef = db.doc(`users/${beneficiaryUid}`);
    const [milestoneSnap, allMilestones, beneficiarySnap] = await Promise.all([
      tx.get(milestoneRef),
      tx.get(jobRef.collection("milestones")),
      tx.get(beneficiaryRef),
    ]);
    if (milestoneSnap.data()?.status !== "disputed") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This milestone is not under dispute.");
    }
    const amountSen = dispute.amountSen;

    const beneficiaryUpdate = {
      walletBalanceSen:
          (beneficiarySnap.data()?.walletBalanceSen || 0) + amountSen,
    };
    if (resolution === "refund") {
      // The milestone reopens to `pending` below (re-fundable), so this
      // amount is a live commitment against the requestor's wallet again -
      // re-lock it.
      beneficiaryUpdate.escrowLockedSen =
          (beneficiarySnap.data()?.escrowLockedSen || 0) + amountSen;
    }
    tx.update(beneficiaryRef, beneficiaryUpdate);
    if (resolution === "release") {
      // Terminal: the provider is paid. Completing the job when this was the
      // last un-released milestone is the review-unlock gate.
      tx.update(milestoneRef, {status: "released"});
      const wasLast = allMilestones.docs.every(
          (doc) => doc.id === dispute.milestoneId ||
              isTerminal(doc.data().status));
      if (wasLast) {
        tx.update(jobRef, {status: "completed"});
      }
    } else {
      // Refund: the requestor gets their money back and the milestone reopens
      // for rework (re-fundable, re-deliverable) with the ruling note attached.
      // The job stays in progress - a refund must never look like success.
      tx.update(milestoneRef, {
        status: "pending",
        submissionNote: null,
        reworkNote: rulingNote || null,
        reworkCount: admin.firestore.FieldValue.increment(1),
      });
      // A ruling against the provider counts against their track record.
      tx.update(db.doc(`users/${dispute.providerId}`), {
        disputesLost: admin.firestore.FieldValue.increment(1),
      });
    }
    tx.update(disputeRef, {
      status: "resolved",
      resolution,
      rulingNote: rulingNote || null,
      resolvedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    appendLedger(tx, {
      fromUid: ESCROW,
      toUid: beneficiaryUid,
      amountSen,
      type: resolution === "release" ? "dispute_release" : "dispute_refund",
      jobId: dispute.jobId,
      jobTitle: dispute.jobTitle || null,
      milestoneId: dispute.milestoneId,
      participantIds: [beneficiaryUid],
    });
    // Both parties learn the outcome; the admin is the actor.
    const released = resolution === "release";
    notify(tx, dispute.providerId, {
      type: "dispute",
      title: "Dispute resolved",
      body: released ?
          `Ruled in your favour: ${rm(amountSen)} was released to you for ` +
          `"${dispute.jobTitle}".` :
          `The client was refunded ${rm(amountSen)} on ` +
          `"${dispute.jobTitle}". The milestone is reopened for rework.`,
      route: `/jobs/${dispute.jobId}`,
    });
    notify(tx, dispute.requestorId, {
      type: "dispute",
      title: "Dispute resolved",
      body: released ?
          `${rm(amountSen)} was released to the provider for ` +
          `"${dispute.jobTitle}".` :
          `You were refunded ${rm(amountSen)} on "${dispute.jobTitle}". ` +
          "The milestone is reopened for rework.",
      route: `/jobs/${dispute.jobId}`,
    });
  });
});

/**
 * Admin-only, idempotent Trust Score v2 backfill: recounts every user's
 * `jobsCompleted` (as provider or requestor) and `disputesLost` from the
 * source collections and writes just those counters - the
 * `recomputeTrustOnUserWrite` consumer then rebuilds each user's breakdown.
 * Safe to re-run; also usable later as a "recount everything" repair tool.
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
    // Unconditional write: fixes the counters AND fires the consumer, which
    // computes the `trust` map for users that predate v2 (and no-ops for
    // anyone already up to date).
    await doc.ref.update({
      jobsCompleted: asProvider + asRequestor,
      disputesLost: refunds,
    });
    updated++;
  }
  return {users: users.size, updated};
});

// ---------------------------------------------------------------------------
// Mid-flight job cancellation.
//
// Cancelling an in-progress job is mutual: either party requests, the
// counterparty accepts (an admin can override). The safety property is that
// cancellation can never strand escrow - it is refused while any milestone
// holds committed money (`funded`/`submitted`/`disputed`); that money must
// first be released, or disputed and ruled on, through the paths above.
// ---------------------------------------------------------------------------

/** True if any milestone still holds committed escrow. */
function hasHeldEscrow(milestonesSnap) {
  return milestonesSnap.docs.some((d) => {
    const s = d.data().status;
    return s === "funded" || s === "submitted" || s === "disputed";
  });
}

const ESCROW_HELD_MESSAGE =
    "This job still has money in escrow. Release each funded milestone, or " +
    "resolve any dispute, before cancelling.";

/**
 * The still-locked portion of [job]'s accepted bid: the total minus whatever
 * has already been funded (which moved that slice from `escrowLockedSen`
 * into actual escrow at `fundMilestone`) - i.e. every terminal (released)
 * milestone. Cancellation is refused while any milestone is
 * funded/submitted/disputed, so those statuses never occur here.
 */
function remainingLockedSen(job, milestonesSnap) {
  const funded = milestonesSnap.docs.reduce((sum, doc) => {
    const m = doc.data();
    return isTerminal(m.status) ? sum + (m.amountSen || 0) : sum;
  }, 0);
  return Math.max(0, (job.acceptedBidAmountSen || 0) - funded);
}

/**
 * Deletes every not-yet-funded milestone, releases the requestor's remaining
 * unfunded commitment on this job (locked at accept, decremented as each
 * milestone was funded) back to their available balance, and marks the job
 * cancelled with an audit trail. Callers must already have verified authority
 * and re-checked the escrow guard inside [tx]; [remainingSen] is
 * [remainingLockedSen] computed by the caller from the same reads.
 */
function finaliseCancellation(tx, jobRef, milestonesSnap, cancelledBy,
    requestorWalletRef, requestorWalletSnap, remainingSen) {
  for (const doc of milestonesSnap.docs) {
    if (!isLocked(doc.data().status)) tx.delete(doc.ref);
  }
  if (remainingSen > 0) {
    const locked = requestorWalletSnap.data()?.escrowLockedSen || 0;
    tx.update(requestorWalletRef, {
      escrowLockedSen: Math.max(0, locked - remainingSen),
    });
  }
  tx.update(jobRef, {
    status: "cancelled",
    cancelledBy,
    cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
    cancellationRequestedBy: null,
    cancellationRequestedAt: null,
  });
}

/**
 * Either party asks to cancel an in-progress job. Records the request for the
 * counterparty to accept; does not change the job status. Refused while escrow
 * is held.
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
      if (hasHeldEscrow(milestones)) {
        throw new functions.https.HttpsError(
            "failed-precondition", ESCROW_HELD_MESSAGE);
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
 * The counterparty answers a pending cancellation request. Accepting cancels
 * the job (re-checking the escrow guard); declining clears the request and
 * leaves the job in progress.
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

      // The requester (the party that is NOT responding) learns the outcome.
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
      if (hasHeldEscrow(milestones)) {
        throw new functions.https.HttpsError(
            "failed-precondition", ESCROW_HELD_MESSAGE);
      }
      const requestorWalletRef = db.doc(`users/${job.requestorId}`);
      const requestorWalletSnap = await tx.get(requestorWalletRef);
      finaliseCancellation(tx, jobRef, milestones, uid, requestorWalletRef,
          requestorWalletSnap, remainingLockedSen(job, milestones));
      notify(tx, requesterUid, {
        type: "cancellation",
        title: "Job cancelled",
        body: `Both parties agreed: "${job.title}" has been cancelled.`,
        route: `/jobs/${jobId}`,
      });
    });
  });

/**
 * Admin override: cancels an in-progress job unilaterally (e.g. as the outcome
 * of an unworkable dispute). Still refused while escrow is held - the admin
 * resolves the dispute first, which settles the money.
 */
exports.adminCancelJob = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const reason = typeof data.reason === "string" ? data.reason.trim() : "";
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestonesRef = jobRef.collection("milestones");

  await db.runTransaction(async (tx) => {
    await assertAdmin(tx, db, uid);
    const [jobSnap, milestones] = await Promise.all([
      tx.get(jobRef),
      tx.get(milestonesRef),
    ]);
    const job = jobSnap.data();
    if (job?.status !== "in_progress") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This job is not in progress.");
    }
    if (hasHeldEscrow(milestones)) {
      throw new functions.https.HttpsError(
          "failed-precondition", ESCROW_HELD_MESSAGE);
    }
    const requestorWalletRef = db.doc(`users/${job.requestorId}`);
    const requestorWalletSnap = await tx.get(requestorWalletRef);
    tx.update(jobRef, {cancellationReason: reason || null});
    finaliseCancellation(tx, jobRef, milestones, "admin", requestorWalletRef,
        requestorWalletSnap, remainingLockedSen(job, milestones));
    for (const partyUid of [job.requestorId, job.acceptedProviderId]) {
      notify(tx, partyUid, {
        type: "cancellation",
        title: "Job cancelled by admin",
        body: `An administrator cancelled "${job.title}"` +
            `${reason ? `: "${reason}"` : "."}`,
        route: `/jobs/${jobId}`,
      });
    }
  });
});

// ---------------------------------------------------------------------------
// Bidding deadline enforcement.
//
// Firestore rules (jobBiddingOpen) already block a new/updated bid once a
// job's deadline passes, but nothing flips the job's own status on its
// own - an open job whose deadline lapsed with no bid accepted would
// otherwise sit "open" forever. This periodic sweep closes those out, reusing
// `cancelled` rather than adding a new terminal status: the existing
// `logJobStatusChange` timeline trigger already logs a cancellation, and
// `closeChatOnJobEnd` is a no-op here (an open job never has a conversation
// yet).
// ---------------------------------------------------------------------------

/**
 * Every 6 hours, cancels any still-open job whose bidding deadline has
 * passed. Requires the Blaze plan and the Cloud Scheduler API, plus the
 * `jobs` composite index on (status ASC, deadline ASC) - see
 * firestore.indexes.json.
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

// Grace window during which a completed/cancelled job's chat stays writable
// for loose ends, after which it becomes read-only (never deleted - the
// history is dispute evidence).
const CHAT_GRACE_MS = 14 * 24 * 60 * 60 * 1000;

/**
 * Closes a job's chat 14 days after the job ends. While the job is in progress
 * (which includes any period a dispute is open, since a disputed job can't
 * complete) the chat stays open. Sets `chatClosesAt` on the conversation, if
 * one exists - never creates the doc, and never deletes messages.
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

// ---------------------------------------------------------------------------
// Notifications (plan §3.4.2).
//
// One pipeline feeds both surfaces: every event writes a doc to
// `users/{uid}/notifications`, which the in-app list and bell badge stream
// directly, and the single `onNotificationCreated` trigger fans out as an FCM
// push. Business logic never talks to FCM itself - it just calls `notify()`
// inside the transaction it already runs, so the notification is atomic with
// the action it describes. Being a subcollection of the user doc, the
// existing `cleanupUserDoc` recursive delete already covers cleanup.
// ---------------------------------------------------------------------------

/** Formats sen as `RM 1,234.50` for notification copy. */
function rm(sen) {
  return `RM ${(sen / 100).toLocaleString("en-MY",
      {minimumFractionDigits: 2, maximumFractionDigits: 2})}`;
}

/**
 * Queues a notification for [uid]. Written through the caller's transaction
 * or batch so it commits (or aborts) together with the event itself. The
 * `onNotificationCreated` trigger turns it into a push afterwards.
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
 * The fan-out: a new notification doc becomes an FCM push to every device
 * token the user has registered. Tokens the platform reports as dead
 * (uninstall, cleared data, rotation) are pruned so the array can't grow
 * stale forever. Delivery is best-effort - the in-app list is the source of
 * truth and already has the doc.
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

/**
 * New bid → tell the requestor. A trigger (not a notify() call) because bids
 * are direct client writes with no callable to hook.
 */
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

/**
 * Bid flipped to accepted → tell the winning provider (the bid doc id is
 * their uid). Rejected bids stay silent - one push per losing bidder on every
 * acceptance would be noise, and the bid list already shows the outcome.
 */
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
            `${rm(after.amountSen || 0)}. Propose your milestone plan to ` +
            "get started.",
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
 * Admin verification decision → tell the applicant. Guarded on the actual
 * status transition so ordinary profile edits (which also fire this
 * user-document trigger) never send a push. Writing the notification into a
 * subcollection does not re-fire user-document triggers, so no loop.
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

// ---------------------------------------------------------------------------
// Job activity timeline: a per-job, server-written event log shown on the job
// detail. Events live at `jobs/{jobId}/events/{eventId}`, written only by the
// triggers below (client writes are denied - see firestore.rules), so the
// timeline can't be forged. Deterministic event ids make at-least-once
// trigger retries idempotent (overwrite instead of duplicate), at the cost of
// collapsing a rare repeat of the same transition (e.g. a re-fund after a
// refund) - acceptable here.
// ---------------------------------------------------------------------------

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

/**
 * Logs the job-level transitions worth surfacing on the timeline. Guarded on
 * an actual `status` change, so the many non-status writes on this doc -
 * bidCount, completionCounted, cancellation request fields - are ignored.
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
 * Logs the meaningful milestone-status transitions on the timeline - skips
 * `proposed`/`pending` from the plan/approve flow (noise), and only logs a
 * `pending` transition when it follows `disputed` (a dispute refund reopening
 * the milestone for rework).
 */
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
      switch (after.status) {
        case "funded":
          return logJobEvent(jobId, `${milestoneId}_funded`, "funded",
              `Funded "${d}": ${rm(amt)}`);
        case "submitted":
          return logJobEvent(jobId, `${milestoneId}_submitted`, "submitted",
              `Work delivered: "${d}"`);
        case "released":
          return logJobEvent(jobId, `${milestoneId}_released`, "released",
              `Payment released: "${d}" (${rm(amt)})`);
        case "disputed":
          return logJobEvent(jobId, `${milestoneId}_disputed`, "disputed",
              `Disputed: "${d}"`);
        case "pending":
          if (before?.status !== "disputed") return null;
          return logJobEvent(jobId, `${milestoneId}_refunded`, "refunded",
              `Refunded & reopened: "${d}"`);
        default:
          return null;
      }
    });

// ---------------------------------------------------------------------------
// Gemini posting assistant (plan §3.4.5).
//
// Proxied through this callable so the API key never ships in the APK - it
// lives in Cloud Secret Manager (`firebase functions:secrets:set GEMINI_KEY`),
// the same reasoning that keeps wallet writes server-side. Both assists are
// advisory: every failure path returns null rather than throwing, so the
// post-job form keeps working when the quota is hit or the model misbehaves.
// ---------------------------------------------------------------------------

// `defineSecret` is already required above, for `toyyibpaySecret`.
const {GoogleGenAI, Type, ThinkingLevel, MediaResolution} =
    require("@google/genai");
const geminiKey = defineSecret("GEMINI_KEY");
// Current Gemini Flash-Lite id; requires the @google/genai SDK.
const GEMINI_MODEL = "gemini-3.1-flash-lite";

/** System instruction for the description helper: rough text → a short,
 * scannable, up-to-three-section description (What needs doing / Access &
 * details / Expected outcome). Tuned for directness: plain words, no
 * filler/preamble, fragments over full sentences, and a section is dropped
 * rather than padded when the note gives it no basis. */
const DESCRIPTION_SYSTEM = "You help customers on FairBid, a Malaysian " +
    "home-services marketplace, turn a rough note into a job posting a " +
    "provider can scan in seconds. Use plain, everyday words. No preamble, " +
    "no greeting, no restating the category, no closing pleasantries, no " +
    "filler. Aim for about 50 to 80 words total. Use up to three " +
    "sections, in this order, each starting with its label on its own " +
    "line: What needs doing, then Access & details, then Expected " +
    "outcome. Drop a section entirely, rather than padding it, when the " +
    "note gives no basis for it. Under 'What needs doing', lead with the " +
    "action or the object: one short sentence or fragment naming the " +
    "problem or task. Under 'Access & details', list only the practical " +
    "things a provider should confirm that the note actually supports " +
    "(for example property type, floor or unit, parking, whether parts " +
    "or materials are provided, pets, or timing constraints), one short " +
    "fragment per line, each starting with the bullet character '•'. " +
    "Under 'Expected outcome', name what a good result looks like in one " +
    "short sentence or fragment. Put a blank line between sections. " +
    "Write in plain prose, favouring short sentence fragments over full " +
    "sentences. Do not use markdown, headings syntax, or bold. Do not " +
    "use em dashes. Never invent prices, deadlines, brand names, " +
    "measurements, or commitments the customer did not state; if " +
    "something is unknown, leave it out rather than guessing. If a photo " +
    "is provided, use it to make the description more specific and " +
    "accurate.";

/** System instruction for the fair-price guide; the JSON shape is enforced
 * by `PRICE_SCHEMA`, so no "reply with ONLY JSON" wording is needed here. */
const PRICE_SYSTEM = "You estimate fair market prices for home services " +
    "in Malaysia. Give a realistic ringgit range for the job described, " +
    "based only on what it states. If a photo is provided, factor it in. " +
    "Never invent a price from an assumed brand name, measurement, or " +
    "detail the description does not give. Do not use em dashes.";

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
 * Parses the model's price reply. `PRICE_SCHEMA` constrains the model to
 * clean JSON, but a truncated body can still throw, so this stays
 * try/catch. Returns `{minSen, maxSen}` (integer sen - the client never
 * handles floating ringgit) or null when unusable.
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

const IMG_PREFIX =
  "https://firebasestorage.googleapis.com/v0/b/fairbid-c9340.firebasestorage.app/o/";
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

/** Fetches a job photo as base64 inline data, or null (→ text-only). SSRF-
 * guarded to this project's Storage bucket; all failures degrade to null. */
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
 * One callable serving both post-a-job assists, keyed by `kind`
 * ('description' | 'price') so the prompt/parse/guard logic lives in one
 * place. Returns `{description}` / `{minSen, maxSen}`, or null for
 * "no suggestion" - the client treats null as a soft miss, never an error.
 */
exports.suggestJobDetails = functions
    .runWith({secrets: [geminiKey]})
    .https.onCall(async (data, context) => {
      callerUid(context); // signed-in users only
      const kind = data.kind;
      const category = String(data.category || "").slice(0, 60);
      const roughText = String(data.roughText || "").trim().slice(0, 600);
      const photoUrl = data.photoUrl;
      if (kind !== "description" && kind !== "price") {
        throw new functions.https.HttpsError(
            "invalid-argument", "Unknown kind.");
      }
      if (roughText.length < 3) {
        throw new functions.https.HttpsError(
            "invalid-argument", "Tell us a bit more first.");
      }

      try {
        const ai = new GoogleGenAI({apiKey: geminiKey.value()});

        const config = kind === "description" ? {
          systemInstruction: DESCRIPTION_SYSTEM,
          temperature: 0.4,
          maxOutputTokens: 512,
          thinkingConfig: {thinkingLevel: ThinkingLevel.MINIMAL},
        } : {
          systemInstruction: PRICE_SYSTEM,
          temperature: 0.2,
          maxOutputTokens: 256,
          responseMimeType: "application/json",
          responseSchema: PRICE_SCHEMA,
          thinkingConfig: {thinkingLevel: ThinkingLevel.MINIMAL},
        };
        const text = kind === "description" ?
            `Category: ${category}\nCustomer's note: ${roughText}` :
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
        if (kind === "description") {
          const description = (responseText || "").trim();
          return description === "" ? null : {description};
        }
        return parsePriceJson(responseText);
      } catch (err) {
        const status = typeof err?.status === "number" ? err.status :
            (typeof err?.code === "number" ? err.code : null);
        // 400/403/404 = a real config bug (bad model id, permission, API
        // disabled) we must be able to find in logs; 429/network/offline/
        // parse are advisory soft-misses. Never log the API key or the
        // request body.
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
