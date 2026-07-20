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
// `trustScore` + `trust` breakdown — no client, and no other function, ever
// computes the score.
// ---------------------------------------------------------------------------

const {computeTrust} = require("./trust");

/**
 * The single trust-score consumer: whenever a user document is written —
 * profile creation, a profile edit, an admin verification decision, or a
 * counter bump from one of the producers below — recompute the breakdown and
 * store it. Writes only when the result actually changed, which both saves
 * writes and terminates the self-trigger loop (our own write recomputes to an
 * identical breakdown and stops).
 */
exports.recomputeTrustOnUserWrite = functions.firestore
    .document("users/{uid}")
    .onWrite(async (change) => {
      if (!change.after.exists) return; // deletion — nothing to score
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
 * ratings — rules deny client writes to these fields.)
 */
exports.recomputeTrustScore = functions.firestore
    .document("users/{revieweeId}/reviews/{reviewId}")
    .onCreate(async (snapshot, context) => {
      const revieweeId = context.params.revieweeId;
      const rating = snapshot.data().rating;
      const userRef = admin.firestore().doc(`users/${revieweeId}`);

      await admin.firestore().runTransaction(async (tx) => {
        const userSnap = await tx.get(userRef);
        const data = userSnap.data() || {};
        tx.update(userRef, {
          ratingSum: (data.ratingSum || 0) + rating,
          ratingCount: (data.ratingCount || 0) + 1,
        });
      });
    });

/**
 * Producer: when a job completes (last milestone released, or a dispute
 * ruling closed it out), both participants earn a completed job toward their
 * track record. One trigger covers every completion path.
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
      const batch = db.batch();
      const bump = {
        jobsCompleted: admin.firestore.FieldValue.increment(1),
      };
      if (after.acceptedProviderId) {
        batch.update(db.doc(`users/${after.acceptedProviderId}`), bump);
      }
      if (after.requestorId) {
        batch.update(db.doc(`users/${after.requestorId}`), bump);
      }
      await batch.commit();
    });

// ---------------------------------------------------------------------------
// Wallet + milestone escrow.
//
// Firestore rules reject every client write to `walletBalanceSen`, to a
// milestone's funded/released status and to the `transactions` ledger, so all
// money movement flows through these callables (the admin SDK bypasses
// rules) — exactly how `recomputeTrustScore` protects the Trust Score.
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
 * Statuses that end a milestone's lifecycle. A job completes only when every
 * milestone is `released` (paid to the provider). A refunded dispute now
 * returns its milestone to `pending` for rework rather than ending it, so a
 * refund can no longer silently "complete" a job. `resolved` is retained here
 * solely so any pre-existing legacy document — the status a refund used to
 * write — can still complete.
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
 * Provider proposes (or amends) the milestone plan for their in-progress job.
 * The plan is authored by the provider but only becomes fundable once the
 * requestor approves it (`approveMilestonePlan`), so every milestone is
 * written `proposed`. Server-owned because the amount split is the money
 * contract: it must total the accepted bid exactly (the check that used to
 * live only in the client), and locked milestones — already funded or beyond —
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
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestoneRef = jobRef.collection("milestones").doc(milestoneId);
  const walletRef = db.doc(`users/${uid}`);

  await db.runTransaction(async (tx) => {
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
    const balance = walletSnap.data()?.walletBalanceSen || 0;
    if (balance < milestone.amountSen) {
      throw new functions.https.HttpsError(
          "failed-precondition", "Insufficient wallet balance.");
    }

    tx.update(walletRef, {walletBalanceSen: balance - milestone.amountSen});
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
          `"${milestone.description}" — you can start work.`,
      route: `/jobs/${jobId}`,
    });
  });
});

/**
 * Requestor releases a submitted milestone: the provider's wallet is credited
 * and, when this was the job's last unreleased milestone, the job completes —
 * the gate that unlocks reviews for both parties.
 */
exports.releaseMilestone = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = checkId(data.jobId, "jobId");
  const milestoneId = checkId(data.milestoneId, "milestoneId");
  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const milestoneRef = jobRef.collection("milestones").doc(milestoneId);

  await db.runTransaction(async (tx) => {
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
      throw new functions.https.HttpsError(
          "failed-precondition", "This job has no accepted provider.");
    }
    if (milestoneSnap.data()?.status !== "submitted") {
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
          `"${job.title}"${wasLast ? " — job complete!" : "."}`,
      route: `/jobs/${jobId}`,
    });
  });
});

// Per-top-up cap. Must stay in sync with PlatformConfig.maxTopUpSen
// (lib/core/config/platform_config.dart), the source of truth.
const MAX_TOPUP_SEN = 1000000; // RM 10,000

/**
 * Demo-only top-up that stands in for a payment gateway: credits the caller's
 * own wallet, capped per call so a tampered client can't mint absurd
 * balances. A batch (not a transaction) is enough — increment is atomic and
 * there is no balance precondition.
 */
exports.topUpWallet = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const amountSen = checkAmount(data.amountSen);
  if (amountSen > MAX_TOPUP_SEN) {
    throw new functions.https.HttpsError(
        "invalid-argument", "Top-ups are capped at RM 10,000.");
  }
  const db = admin.firestore();
  const batch = db.batch();
  batch.update(db.doc(`users/${uid}`), {
    walletBalanceSen: admin.firestore.FieldValue.increment(amountSen),
  });
  appendLedger(batch, {
    fromUid: null,
    toUid: uid,
    amountSen,
    type: "topup",
    participantIds: [uid],
  });
  await batch.commit();
});

/** Withdraws from the caller's available balance; rejects overdrafts. */
exports.withdrawFromWallet = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const amountSen = checkAmount(data.amountSen);
  const db = admin.firestore();
  const walletRef = db.doc(`users/${uid}`);

  await db.runTransaction(async (tx) => {
    const walletSnap = await tx.get(walletRef);
    const balance = walletSnap.data()?.walletBalanceSen || 0;
    if (balance < amountSen) {
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
    // A receipt to the actor is deliberate here — money leaving the wallet
    // should always leave a visible trace.
    notify(tx, uid, {
      type: "payment",
      title: "Withdrawal complete",
      body: `${rm(amountSen)} was withdrawn from your FairBid balance.`,
      route: "/profile/earnings",
    });
  });
});

/**
 * Admin ruling on a flagged review. Hiding removes it from public display
 * AND reverses its rating out of the reviewee's aggregates — otherwise a
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
 * provider and marks the milestone `released` — terminal, and if it was the
 * job's last one the job completes, unlocking reviews (mirrors
 * `releaseMilestone`). `refund` returns the money to the requestor and sends
 * the milestone back to `pending` for rework (carrying the ruling note), so
 * the worker can re-deliver instead of being stranded — the job stays in
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

    tx.update(beneficiaryRef, {
      walletBalanceSen:
          (beneficiarySnap.data()?.walletBalanceSen || 0) + amountSen,
    });
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
      // The job stays in progress — a refund must never look like success.
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
 * source collections and writes just those counters — the
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
// cancellation can never strand escrow — it is refused while any milestone
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
 * Deletes every not-yet-funded milestone and marks the job cancelled with an
 * audit trail. Callers must already have verified authority and re-checked the
 * escrow guard inside [tx].
 */
function finaliseCancellation(tx, jobRef, milestonesSnap, cancelledBy) {
  for (const doc of milestonesSnap.docs) {
    if (!isLocked(doc.data().status)) tx.delete(doc.ref);
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
          body: `The other party declined to cancel "${job.title}" — the ` +
              "job continues.",
          route: `/jobs/${jobId}`,
        });
        return;
      }
      if (hasHeldEscrow(milestones)) {
        throw new functions.https.HttpsError(
            "failed-precondition", ESCROW_HELD_MESSAGE);
      }
      finaliseCancellation(tx, jobRef, milestones, uid);
      notify(tx, requesterUid, {
        type: "cancellation",
        title: "Job cancelled",
        body: `Both parties agreed — "${job.title}" has been cancelled.`,
        route: `/jobs/${jobId}`,
      });
    });
  });

/**
 * Admin override: cancels an in-progress job unilaterally (e.g. as the outcome
 * of an unworkable dispute). Still refused while escrow is held — the admin
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
    if (jobSnap.data()?.status !== "in_progress") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This job is not in progress.");
    }
    if (hasHeldEscrow(milestones)) {
      throw new functions.https.HttpsError(
          "failed-precondition", ESCROW_HELD_MESSAGE);
    }
    tx.update(jobRef, {cancellationReason: reason || null});
    finaliseCancellation(tx, jobRef, milestones, "admin");
    const job = jobSnap.data();
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

// Grace window during which a completed/cancelled job's chat stays writable
// for loose ends, after which it becomes read-only (never deleted — the
// history is dispute evidence).
const CHAT_GRACE_MS = 14 * 24 * 60 * 60 * 1000;

/**
 * Closes a job's chat 14 days after the job ends. While the job is in progress
 * (which includes any period a dispute is open, since a disputed job can't
 * complete) the chat stays open. Sets `chatClosesAt` on the conversation, if
 * one exists — never creates the doc, and never deletes messages.
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
// push. Business logic never talks to FCM itself — it just calls `notify()`
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
 * stale forever. Delivery is best-effort — the in-app list is the source of
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
 * their uid). Rejected bids stay silent — one push per losing bidder on every
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
// Gemini posting assistant (plan §3.4.5).
//
// Proxied through this callable so the API key never ships in the APK — it
// lives in Cloud Secret Manager (`firebase functions:secrets:set GEMINI_KEY`),
// the same reasoning that keeps wallet writes server-side. Both assists are
// advisory: every failure path returns null rather than throwing, so the
// post-job form keeps working when the quota is hit or the model misbehaves.
// ---------------------------------------------------------------------------

const {defineSecret} = require("firebase-functions/params");
const geminiKey = defineSecret("GEMINI_KEY");

/** Prompt for the description helper: rough text → structured description. */
function descriptionPrompt(category, roughText) {
  return "You help customers on FairBid, a Malaysian home-services " +
      "marketplace, write clear job postings. Expand the customer's rough " +
      "note into a job description in plain prose (no markdown, no " +
      "headings), under 120 words, covering: what the problem is, any " +
      "access details the provider should confirm, and the expected " +
      "outcome. Never invent prices, deadlines or commitments the customer " +
      `did not state.\n\nCategory: ${category}\n` +
      `Customer's note: ${roughText}`;
}

/** Prompt for the fair-price guide: strict JSON, RM range. */
function pricePrompt(category, roughText) {
  return "You estimate fair market prices for home services in Malaysia. " +
      "Given the job below, reply with ONLY a JSON object — no prose, no " +
      "code fences — of the form {\"minRm\": number, \"maxRm\": number} " +
      "giving a realistic ringgit range a customer should expect to pay.\n\n" +
      `Category: ${category}\nJob description: ${roughText}`;
}

/**
 * Defensively parses the model's price reply. Models return fences or prose
 * despite instructions, so extract the first JSON object and range-check it.
 * Returns `{minSen, maxSen}` (integer sen — the client never handles floating
 * ringgit) or null when unusable.
 */
function parsePriceJson(text) {
  try {
    const match = String(text).match(/\{[^{}]*\}/);
    if (!match) return null;
    const {minRm, maxRm} = JSON.parse(match[0]);
    if (typeof minRm !== "number" || typeof maxRm !== "number") return null;
    if (!(minRm > 0) || !(maxRm >= minRm) || maxRm > 1000000) return null;
    return {minSen: Math.round(minRm * 100), maxSen: Math.round(maxRm * 100)};
  } catch (_) {
    return null;
  }
}

/**
 * One callable serving both post-a-job assists, keyed by `kind`
 * ('description' | 'price') so the prompt/parse/guard logic lives in one
 * place. Returns `{description}` / `{minSen, maxSen}`, or null for
 * "no suggestion" — the client treats null as a soft miss, never an error.
 */
exports.suggestJobDetails = functions
    .runWith({secrets: [geminiKey]})
    .https.onCall(async (data, context) => {
      callerUid(context); // signed-in users only
      const kind = data.kind;
      const category = String(data.category || "").slice(0, 60);
      const roughText = String(data.roughText || "").trim().slice(0, 600);
      if (kind !== "description" && kind !== "price") {
        throw new functions.https.HttpsError(
            "invalid-argument", "Unknown kind.");
      }
      if (roughText.length < 3) {
        throw new functions.https.HttpsError(
            "invalid-argument", "Tell us a bit more first.");
      }

      try {
        const {GoogleGenerativeAI} = require("@google/generative-ai");
        const model = new GoogleGenerativeAI(geminiKey.value())
            .getGenerativeModel({model: "gemini-2.0-flash"});
        const result = await model.generateContent(
            kind === "description" ?
                descriptionPrompt(category, roughText) :
                pricePrompt(category, roughText));
        const text = result.response.text();
        if (kind === "description") {
          const description = text.trim();
          return description === "" ? null : {description};
        }
        return parsePriceJson(text);
      } catch (err) {
        functions.logger.warn("Gemini assist failed", err);
        return null; // advisory only — never a hard failure
      }
    });
