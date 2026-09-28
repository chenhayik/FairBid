// Bundled job postings - phases 1 and 2 of docs/BUNDLE_BIDDING.md.
// A bundle groups 2-6 tasks, each stored as an ordinary job (tagged
// bundleId/bundleOrder) so nothing downstream needs a new shape.

const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
// Imported modularly rather than via admin.firestore.* - the legacy
// accessor reads undefined once the Functions emulator proxies the SDK.
const {FieldValue, Timestamp} = require("firebase-admin/firestore");
const {notifyUser, IMG_PREFIX} = require("./common");

// Bundle size limits; must match PlatformConfig.min/maxBundleTasks. Upper
// bound keeps the phase-3 award search (2^n subsets) cheap.
const MIN_BUNDLE_TASKS = 2;
const MAX_BUNDLE_TASKS = 6;

// Consolidation cap, snapshotted onto every bundle at creation so an award
// is judged by the rule shown at posting time. Must match PlatformConfig.
const CONSOLIDATION_CAP_PCT = 5;
const CONSOLIDATION_CAP_SEN = 50000; // RM 500

// Same per-amount ceiling the bid rules enforce: RM 1,000,000.
const MAX_AMOUNT_SEN = 100000000;

// Copy of kServiceCategories. A task outside this list would never show in
// the feed's category filter, so it's checked here rather than trusted.
const CATEGORIES = [
  "Cleaning", "Plumbing", "Electrical", "Aircon Servicing", "Home Repair",
  "Moving & Delivery", "Tutoring", "IT & Tech Support", "Design & Creative",
  "Other",
];

const MAX_TITLE_LEN = 120;
const MAX_ADDRESS_LEN = 200;
const MAX_DESCRIPTION_LEN = 5000;
const MAX_PHOTOS = 10;
const MAX_GAP_DAYS = 365;

// Rejects unauthenticated calls; returns the caller's uid.
function callerUid(context) {
  if (!context.auth) {
    throw new functions.https.HttpsError(
        "unauthenticated", "You must be signed in.");
  }
  return context.auth.uid;
}

// An invalid-argument error - every call site does `throw bad("...")`.
function bad(message) {
  return new functions.https.HttpsError("invalid-argument", message);
}

// Returns value trimmed, or throws when it isn't usable text.
function text(value, name, max) {
  if (typeof value !== "string") throw bad(`${name} is required.`);
  const trimmed = value.trim();
  if (trimmed === "") throw bad(`${name} is required.`);
  if (trimmed.length > max) throw bad(`${name} is too long.`);
  return trimmed;
}

// Returns an optional whole-sen amount, or null when absent.
function optionalSen(value, name) {
  if (value == null) return null;
  if (!Number.isInteger(value) || value < 0 || value > MAX_AMOUNT_SEN) {
    throw bad(`${name} is not a valid amount.`);
  }
  return value;
}

// Validates the shared map location and returns the stored shape.
function checkLocation(raw) {
  const m = raw || {};
  const lat = m.lat;
  const lng = m.lng;
  if (!Number.isFinite(lat) || !Number.isFinite(lng) ||
      lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    throw bad("Pick a location on the map.");
  }
  return {
    lat,
    lng,
    address: text(m.address, "Location address", MAX_ADDRESS_LEN),
    districtCode: typeof m.districtCode === "string" ? m.districtCode : null,
    districtName: typeof m.districtName === "string" ? m.districtName : null,
    town: typeof m.town === "string" ? m.town : null,
  };
}

// Optional bidding deadline, sent as epoch millis (callable protocol is
// JSON, which has no date type).
function checkDeadline(value) {
  if (value == null) return null;
  if (!Number.isInteger(value) || value <= Date.now()) {
    throw bad("The bidding deadline must be in the future.");
  }
  return Timestamp.fromMillis(value);
}

// Shared photo URLs, capped so one posting cannot balloon.
function checkPhotos(raw) {
  if (raw == null) return [];
  if (!Array.isArray(raw) || raw.length > MAX_PHOTOS ||
      !raw.every((url) => typeof url === "string" && url !== "")) {
    throw bad("Those bundle photos are not valid.");
  }
  return raw;
}

// Validates the task list; startsAfterIndex stays an index here, resolved
// to a real job id by the caller once ids exist.
function checkTasks(list) {
  if (!Array.isArray(list) || list.length < MIN_BUNDLE_TASKS ||
      list.length > MAX_BUNDLE_TASKS) {
    throw bad(`A bundle needs between ${MIN_BUNDLE_TASKS} and ` +
        `${MAX_BUNDLE_TASKS} tasks.`);
  }
  return list.map((entry, i) => {
    const t = entry || {};
    const position = `Task ${i + 1}`;
    if (!CATEGORIES.includes(t.category)) {
      throw bad(`${position} has no valid category.`);
    }
    const minSen = optionalSen(t.budgetMinSen, `${position} budget`);
    const maxSen = optionalSen(t.budgetMaxSen, `${position} budget`);
    if (minSen != null && maxSen != null && minSen > maxSen) {
      throw bad(`${position} has a budget range that is back to front.`);
    }
    // Dependencies are finish-to-start and may only point at an earlier
    // task, so a cycle is impossible and no graph walk is needed.
    const after = t.startsAfterIndex;
    if (after != null &&
        (!Number.isInteger(after) || after < 0 || after >= i)) {
      throw bad(`${position} must follow a task listed before it.`);
    }
    const gapDays = t.gapDays;
    if (gapDays != null &&
        (after == null || !Number.isInteger(gapDays) ||
         gapDays < 0 || gapDays > MAX_GAP_DAYS)) {
      throw bad(`${position} has an invalid gap.`);
    }
    return {
      title: text(t.title, `${position} title`, MAX_TITLE_LEN),
      description:
          text(t.description, `${position} description`, MAX_DESCRIPTION_LEN),
      category: t.category,
      budget: minSen == null && maxSen == null ?
          null :
          {minSen, maxSen, hourly: t.hourly === true},
      lotId: t.lotId == null ?
          null :
          text(t.lotId, `${position} lot`, MAX_TITLE_LEN),
      startsAfterIndex: after == null ? null : after,
      gapDays: gapDays == null ? 0 : gapDays,
    };
  });
}

// Validates a createBundle payload; pure (no Firestore/auth) so
// bundles.test.js can pin every rule without an emulator.
function validateBundle(data) {
  const payload = data || {};
  return {
    title: text(payload.title, "Title", MAX_TITLE_LEN),
    description: text(payload.description, "Description", MAX_DESCRIPTION_LEN),
    location: checkLocation(payload.location),
    photoUrls: checkPhotos(payload.photoUrls),
    deadline: checkDeadline(payload.deadlineMillis),
    tasks: checkTasks(payload.tasks),
  };
}

// Creates one bundled posting: the bundles/{bundleId} doc plus one ordinary
// job per task, in a single atomic batch (no read-modify-write to protect,
// unlike acceptBid which re-reads a balance it then changes).
exports.createBundle = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const {title, description, location, photoUrls, deadline, tasks} =
      validateBundle(data);

  const db = admin.firestore();
  const user = (await db.doc(`users/${uid}`).get()).data();
  if (user?.role !== "requestor") {
    throw new functions.https.HttpsError(
        "permission-denied", "Only a requestor can post a bundle.");
  }
  if (user.suspended === true) {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Your account is suspended. Contact support if you think this is " +
        "a mistake.");
  }

  // Ids are minted locally (.doc() with no argument, no round trip) so a
  // task can reference the job id it follows before anything is written.
  const bundleRef = db.collection("bundles").doc();
  const jobRefs = tasks.map(() => db.collection("jobs").doc());
  const requestor = {
    requestorId: uid,
    requestorName: user.displayName || "Requestor",
    ...(user.profilePhotoUrl ? {requestorPhotoUrl: user.profilePhotoUrl} : {}),
  };

  const batch = db.batch();
  tasks.forEach((task, i) => {
    batch.set(jobRefs[i], {
      ...requestor,
      title: task.title,
      description: task.description,
      category: task.category,
      // Copies of the bundle's shared fields, so a task renders as an
      // ordinary job everywhere - no bundle lookup needed.
      location,
      photoUrls,
      ...(deadline ? {deadline} : {}),
      budget: task.budget,
      status: "open",
      bidCount: 0,
      createdAt: FieldValue.serverTimestamp(),
      bundleId: bundleRef.id,
      bundleOrder: i,
      // Denormalised so a task's feed card can say "Part of a 4-task
      // bundle" without reading the bundle document.
      bundleTaskCount: tasks.length,
      ...(task.lotId ? {lotId: task.lotId} : {}),
      ...(task.startsAfterIndex == null ? {} : {
        startsAfterJobId: jobRefs[task.startsAfterIndex].id,
        gapDays: task.gapDays,
      }),
    });
  });
  batch.set(bundleRef, {
    ...requestor,
    title,
    description,
    location,
    photoUrls,
    ...(deadline ? {deadline} : {}),
    status: "open",
    taskIds: jobRefs.map((ref) => ref.id),
    consolidationCapPct: CONSOLIDATION_CAP_PCT,
    consolidationCapSen: CONSOLIDATION_CAP_SEN,
    createdAt: FieldValue.serverTimestamp(),
  });
  await batch.commit();

  return {bundleId: bundleRef.id, taskIds: jobRefs.map((ref) => ref.id)};
});

// ---------------------------------------------------------------------------
// Phase 2: the provider's package bid, and cancelling a bundle.
// ---------------------------------------------------------------------------

/** A proposal message is free text, so cap it. */
const MAX_MESSAGE_LEN = 2000;

/** "Less than 1 week" and friends - a picker's label, not free text. */
const MAX_DURATION_LEN = 40;

/** A document id sent by the app, e.g. the bundle a bid belongs to. */
function docId(value, name) {
  if (typeof value !== "string" || value.trim() === "" ||
      value.length > 1500 || value.includes("/")) {
    throw bad(`${name} is missing.`);
  }
  return value;
}

/**
 * Whether a bundle still takes bids: open AND not past its deadline, the
 * bundle-level twin of the `jobBiddingOpen` rule.
 */
function bundleBiddingOpen(bundle) {
  return bundle.status === "open" &&
      (bundle.deadline == null || bundle.deadline.toMillis() > Date.now());
}

/**
 * The provider's price per picked task (job id to whole sen). Validated
 * here, not in rules, because the rules language cannot walk a map's entries.
 */
function checkTaskPrices(raw) {
  const prices = raw == null ? {} : raw;
  if (typeof prices !== "object" || Array.isArray(prices)) {
    throw bad("Pick at least one task to bid on.");
  }
  const entries = Object.entries(prices);
  if (entries.length === 0) throw bad("Pick at least one task to bid on.");
  if (entries.length > MAX_BUNDLE_TASKS) {
    throw bad(`A bid may cover at most ${MAX_BUNDLE_TASKS} tasks.`);
  }
  entries.forEach(([, sen]) => {
    if (!Number.isInteger(sen) || sen <= 0 || sen > MAX_AMOUNT_SEN) {
      throw bad("Every task you picked needs a price above RM 0.");
    }
  });
  // The keys are checked against the bundle's own taskIds in submitBundleBid,
  // which is also what makes them safe to use as document ids here.
  return Object.fromEntries(entries);
}

/** Adds the per-task prices up. */
function taskTotal(taskPrices) {
  return Object.values(taskPrices).reduce((sum, sen) => sum + sen, 0);
}

/** Splits a bundle price across tasks in proportion to their own prices. */
// The last task absorbs the rounding remainder so amounts add up exactly.
// Lives here (not bundle_award.js) because validateBundleBid needs it too.
function splitBundlePrice(taskPrices, bundlePriceSen) {
  const taskIds = Object.keys(taskPrices);
  const priceTotal = taskIds.reduce((sum, id) => sum + taskPrices[id], 0);
  const amounts = {};
  let allocated = 0;
  taskIds.forEach((taskId, i) => {
    if (i === taskIds.length - 1) {
      amounts[taskId] = bundlePriceSen - allocated;
      return;
    }
    const share = Math.floor(bundlePriceSen * taskPrices[taskId] / priceTotal);
    amounts[taskId] = share;
    allocated += share;
  });
  return amounts;
}

/**
 * Validates a `submitBundleBid` payload; pure so bundles.test.js can pin
 * every rule without an emulator. Bundle-dependent checks live in the callable.
 */
function validateBundleBid(data) {
  const payload = data || {};
  const taskPrices = checkTaskPrices(payload.taskPrices);
  const taskTotalSen = taskTotal(taskPrices);
  const bundlePriceSen = optionalSen(payload.bundlePriceSen, "Bundle price");
  if (bundlePriceSen != null) {
    if (bundlePriceSen === 0) {
      throw bad("Your bundle price must be above RM 0.");
    }
    // A bundle price at or above the task prices summed isn't a discount,
    // and the phase-3 award engine would never pick it - worth catching here.
    if (bundlePriceSen >= taskTotalSen) {
      throw bad("Your bundle price must be lower than your task prices " +
          "added up.");
    }
    // A task whose share rounds below 1 sen would be awarded at RM 0, and
    // proposeMilestonePlan requires every milestone above zero.
    const shares = splitBundlePrice(taskPrices, bundlePriceSen);
    if (Object.values(shares).some((sen) => sen < 1)) {
      throw bad("Your bundle price is too low to share across every task " +
          "you picked.");
    }
  }
  return {
    taskPrices,
    taskTotalSen,
    bundlePriceSen,
    allOrNothing: payload.allOrNothing === true,
    estimatedDuration: text(
        payload.estimatedDuration, "Estimated duration", MAX_DURATION_LEN),
    message: text(payload.message, "Proposal message", MAX_MESSAGE_LEN),
  };
}

/**
 * Tasks sharing a `lotId` are bid on and awarded together, so a bid that
 * picks one of them must pick all of them. Checked against the task docs.
 */
function checkLots(taskSnaps, picked) {
  const lots = {};
  taskSnaps.forEach((snap) => {
    const lotId = snap.data()?.lotId;
    if (!lotId) return;
    lots[lotId] = (lots[lotId] || []).concat(snap.id);
  });
  Object.values(lots).forEach((lot) => {
    const inBid = lot.filter((jobId) => picked.includes(jobId));
    if (inBid.length !== 0 && inBid.length !== lot.length) {
      throw bad("Some of these tasks have to go to the same provider. Pick " +
          "every task in the group, or none of them.");
    }
  });
}

/** The caller's profile, rejected unless they may bid right now. */
async function biddingProvider(db, uid) {
  const user = (await db.doc(`users/${uid}`).get()).data();
  if (user?.role !== "provider" || user.verificationStatus !== "approved") {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Only a verified provider can bid. Finish verification first.");
  }
  if (user.suspended === true) {
    throw new functions.https.HttpsError(
        "permission-denied",
        "Your account is suspended. Contact support if you think this is " +
        "a mistake.");
  }
  return user;
}

/**
 * One provider's sealed package bid on a bundle, stored at
 * `bundles/{bundleId}/bundleBids/{uid}` - written here, not by rules, since
 * the rules language cannot validate a map of per-task prices. A transaction
 * (not a batch): re-bidding reads the existing bid to adjust bidCount.
 */
exports.submitBundleBid = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");
  const bid = validateBundleBid(data);
  const picked = Object.keys(bid.taskPrices);

  const db = admin.firestore();
  const user = await biddingProvider(db, uid);

  const bundleRef = db.doc(`bundles/${bundleId}`);
  const bidRef = db.doc(`bundles/${bundleId}/bundleBids/${uid}`);
  const providerName = user.displayName || "Provider";

  // Cheap pre-check outside the transaction so an obviously-doomed call
  // fails fast; the authoritative checks repeat inside the transaction below.
  const cheapBundle = (await bundleRef.get()).data();
  if (!cheapBundle) {
    throw new functions.https.HttpsError(
        "not-found", "That bundle no longer exists.");
  }

  await db.runTransaction(async (tx) => {
    // The bundle must be read first: its taskIds turn `picked` into task
    // refs, and a transaction may not read after it has written.
    const bundleSnap = await tx.get(bundleRef);
    const bundle = bundleSnap.data();
    if (!bundle) {
      throw new functions.https.HttpsError(
          "not-found", "That bundle no longer exists.");
    }
    if (bundle.requestorId === uid) {
      throw new functions.https.HttpsError(
          "permission-denied", "You cannot bid on your own bundle.");
    }
    if (!bundleBiddingOpen(bundle)) {
      throw new functions.https.HttpsError(
          "failed-precondition", "This bundle is no longer taking bids.");
    }

    const taskIds = Array.isArray(bundle.taskIds) ? bundle.taskIds : [];
    if (picked.some((jobId) => !taskIds.includes(jobId))) {
      throw bad("Those tasks are not part of this bundle.");
    }

    const taskRefs = taskIds.map((jobId) => db.doc(`jobs/${jobId}`));
    const [existing, ...taskSnaps] = taskRefs.length === 0 ?
        [await tx.get(bidRef)] :
        await tx.getAll(bidRef, ...taskRefs);
    if (taskSnaps.some((snap) =>
      picked.includes(snap.id) && snap.data()?.status !== "open")) {
      throw bad("One of the tasks you picked is no longer open.");
    }
    checkLots(taskSnaps, picked);

    const before = existing.exists ?
        Object.keys(existing.data().taskPrices || {}) :
        [];
    if (existing.exists && existing.data().status !== "pending") {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "This bid has already been decided, so it can no longer be " +
          "changed.");
    }
    tx.set(bidRef, {
      providerId: uid,
      providerName,
      ...(user.profilePhotoUrl ? {providerPhotoUrl: user.profilePhotoUrl} : {}),
      // Stamped from the profile, never from the payload: a provider must not
      // be able to dress their own bid in a better Trust Score.
      providerTrustScore: user.trustScore || 0,
      providerScoreVisible: user.trust?.scoreVisible === true,
      taskPrices: bid.taskPrices,
      ...(bid.bundlePriceSen == null ?
          {} :
          {bundlePriceSen: bid.bundlePriceSen}),
      allOrNothing: bid.allOrNothing,
      estimatedDuration: bid.estimatedDuration,
      message: bid.message,
      // So the provider's Pending Bids list can show which bundle this is
      // without reading the bundle document itself.
      bundleTitle: bundle.title || "Bundle",
      status: "pending",
      // An edit keeps the original submission time; only a brand-new bid
      // gets a fresh createdAt.
      createdAt: existing.exists ?
          existing.data().createdAt :
          FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    // Each task counts the bids that cover it, so only the tasks that joined
    // or left this bid move - re-bidding the same tasks changes nothing.
    picked.filter((jobId) => !before.includes(jobId)).forEach((jobId) =>
      tx.update(db.doc(`jobs/${jobId}`), {bidCount: FieldValue.increment(1)}));
    before.filter((jobId) => !picked.includes(jobId)).forEach((jobId) =>
      tx.update(db.doc(`jobs/${jobId}`), {bidCount: FieldValue.increment(-1)}));

    // Only a brand-new bid is announced - an edit doesn't need a second
    // notification, and bids are sealed, so the price never appears here.
    if (!existing.exists) {
      notifyUser(tx, bundle.requestorId, {
        type: "bid_received",
        title: "New bid on your bundle",
        body: `${providerName} bid on ${picked.length} task(s) of ` +
            `"${bundle.title || "a bundle"}".`,
        route: `/bundles/${bundleId}`,
      });
    }
  });

  return {
    taskCount: picked.length,
    totalSen: bid.bundlePriceSen == null ?
        bid.taskTotalSen :
        bid.bundlePriceSen,
  };
});

/**
 * Withdraws the caller's own bundle bid and gives back the `bidCount` it
 * added. Allowed only while bidding is open - once closed, a vanishing bid
 * could pull a task out of an award the requestor was about to make.
 */
exports.withdrawBundleBid = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");

  const db = admin.firestore();
  const bundleRef = db.doc(`bundles/${bundleId}`);
  const bidRef = db.doc(`bundles/${bundleId}/bundleBids/${uid}`);
  const taskCount = await db.runTransaction(async (tx) => {
    // Both reads first: a transaction may not read after it has written.
    const [bundleSnap, snap] = await tx.getAll(bundleRef, bidRef);
    if (!snap.exists) return 0; // already gone - nothing left to undo
    const existing = snap.data();
    if (existing.status !== "pending") {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "This bid has already been decided, so it can no longer be " +
          "withdrawn.");
    }
    const bundle = bundleSnap.data();
    if (!bundle || !bundleBiddingOpen(bundle)) {
      throw new functions.https.HttpsError(
          "failed-precondition",
          "Bidding has closed on this bundle, so your bid can no longer be " +
          "withdrawn.");
    }
    const covered = Object.keys(existing.taskPrices || {});
    tx.delete(bidRef);
    covered.forEach((jobId) =>
      tx.update(db.doc(`jobs/${jobId}`), {bidCount: FieldValue.increment(-1)}));
    return covered.length;
  });

  return {taskCount};
});

/**
 * Cancels an open bundle and every still-open task under it, plus every
 * pending bid, in one transaction - cancelling a single task would break an
 * all-or-nothing bid or split a lot. Runs as a transaction (not a batch) so
 * it can't race awardBundle moving the same tasks to 'in_progress'.
 */
exports.cancelBundle = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const bundleId = docId(data?.bundleId, "Bundle");

  const db = admin.firestore();
  const bundleRef = db.doc(`bundles/${bundleId}`);

  const taskCount = await db.runTransaction(async (tx) => {
    // The bundle first: its taskIds are what turns into task refs, and a
    // transaction may not read after it has written.
    const bundleSnap = await tx.get(bundleRef);
    const bundle = bundleSnap.data();
    if (!bundle) {
      throw new functions.https.HttpsError(
          "not-found", "That bundle no longer exists.");
    }
    if (bundle.requestorId !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied",
          "Only the requestor who posted this bundle can cancel it.");
    }
    if (bundle.status !== "open") {
      throw new functions.https.HttpsError(
          "failed-precondition", "This bundle is no longer open.");
    }

    const taskIds = Array.isArray(bundle.taskIds) ? bundle.taskIds : [];
    const taskRefs = taskIds.map((jobId) => db.doc(`jobs/${jobId}`));
    // A query inside a transaction (see awardBundle's pending-bids read)
    // closes a bid submitted in the gap the old batch write left open.
    const [taskSnaps, pendingBids] = await Promise.all([
      taskRefs.length === 0 ? Promise.resolve([]) : tx.getAll(...taskRefs),
      tx.get(db.collection(`bundles/${bundleId}/bundleBids`)
          .where("status", "==", "pending")),
    ]);

    let cancelled = 0;
    taskSnaps.forEach((snap) => {
      if (snap.data()?.status !== "open") return;
      cancelled++;
      tx.update(snap.ref, {
        status: "cancelled",
        cancelledBy: uid,
        cancelledAt: FieldValue.serverTimestamp(),
        cancellationReason:
            "The requestor cancelled the bundle this task was part of.",
      });
    });

    // The bundle was called off, not decided on its merits, so a pending bid
    // is 'closed' rather than 'rejected' - and each bidder is told why.
    pendingBids.docs.forEach((doc) => {
      tx.update(doc.ref, {status: "closed"});
      notifyUser(tx, doc.id, {
        type: "cancellation",
        title: "Bundle cancelled",
        body: `The requestor cancelled "${bundle.title || "a bundle"}", ` +
            "so your bid is closed.",
        route: null,
      });
    });

    tx.update(bundleRef, {
      status: "cancelled",
      cancelledBy: uid,
      cancelledAt: FieldValue.serverTimestamp(),
    });

    return cancelled;
  });

  return {taskCount};
});

// ---------------------------------------------------------------------------
// Phase 4: bundle expiry, the dependent-task handover, and release/ordering.
// ---------------------------------------------------------------------------

/**
 * Every 6 hours, expires any still-open bundle past its deadline and closes
 * its pending bids; `closeExpiredJobs` already cancels the open tasks.
 */
exports.closeExpiredBundles = functions.pubsub
    .schedule("every 6 hours")
    .onRun(async () => {
      const db = admin.firestore();
      const now = Timestamp.now();
      const snap = await db.collection("bundles")
          .where("status", "==", "open")
          .where("deadline", "<=", now)
          .get();

      let closed = 0;
      for (const doc of snap.docs) {
        const didClose = await db.runTransaction(async (tx) => {
          // Re-read inside the transaction: an award could have landed on
          // this bundle in the gap between the query above and now.
          const bundleSnap = await tx.get(doc.ref);
          const bundle = bundleSnap.data();
          if (!bundle || bundle.status !== "open") return false;

          const pendingBids = await tx.get(db
              .collection(`bundles/${doc.id}/bundleBids`)
              .where("status", "==", "pending"));
          tx.update(doc.ref, {
            status: "expired",
            expiredAt: FieldValue.serverTimestamp(),
          });
          pendingBids.docs.forEach((bidDoc) => {
            tx.update(bidDoc.ref, {status: "closed"});
            notifyUser(tx, bidDoc.id, {
              type: "cancellation",
              title: "Bundle closed",
              body: `Bidding on "${bundle.title || "a bundle"}" closed ` +
                  "without an award, so your bid is closed.",
              route: null,
            });
          });
          return true;
        });
        if (didClose) closed++;
      }
      functions.logger.info(`closeExpiredBundles: closed ${closed} bundle(s)`);
    });

/** "after 3 days" / "now" - the wait a dependent task's provider is told. */
function startsWhenText(gapDays) {
  if (!gapDays || gapDays <= 0) return "now";
  return `after ${gapDays} day${gapDays === 1 ? "" : "s"}`;
}

/**
 * The handover notification body for a dependent task's provider once the
 * task it follows completes. Pure so bundles.test.js can pin the wording.
 */
function handoverNotificationBody(completedTitle, dependentTitle, gapDays) {
  return `"${completedTitle}" is done. "${dependentTitle}" can start ` +
      `${startsWhenText(gapDays)}. Record a site handover before you begin.`;
}

/**
 * When a bundle task completes, tells the provider of any task that starts
 * after it. A retried trigger may double-notify, an acceptable cost.
 */
exports.notifyDependentTask = functions.firestore
    .document("jobs/{jobId}")
    .onUpdate(async (change, context) => {
      const before = change.before.data();
      const after = change.after.data();
      if (before.status === "completed" || after.status !== "completed") {
        return;
      }
      if (!after.bundleId) return; // only bundle tasks have dependents

      const jobId = context.params.jobId;
      const db = admin.firestore();
      const dependents = await db.collection("jobs")
          .where("startsAfterJobId", "==", jobId)
          .get();
      if (dependents.empty) return;

      const batch = db.batch();
      dependents.docs.forEach((doc) => {
        const dependent = doc.data();
        if (!dependent.acceptedProviderId ||
            dependent.status !== "in_progress") {
          return;
        }
        notifyUser(batch, dependent.acceptedProviderId, {
          type: "handover",
          title: "You can start soon",
          body: handoverNotificationBody(
              after.title || "Task", dependent.title || "Task",
              dependent.gapDays || 0),
          route: `/jobs/${doc.id}`,
        });
      });
      await batch.commit();
    });

/** A note is required text; photos are optional Storage download URLs. */
const MAX_HANDOVER_NOTE_LEN = 1000;
const MAX_HANDOVER_PHOTOS = 5;

/** Handover photo URLs: our own Storage uploads only, at most 5 of them. */
function checkHandoverPhotos(raw) {
  if (raw == null) return [];
  if (!Array.isArray(raw) || raw.length > MAX_HANDOVER_PHOTOS ||
      !raw.every((url) =>
        typeof url === "string" && url !== "" && url.startsWith(IMG_PREFIX))) {
    throw bad("Those handover photos are not valid.");
  }
  return raw;
}

/**
 * Validates a `recordHandover` payload. Pure - no Firestore, no auth - so
 * bundles.test.js can pin every rule without an emulator.
 */
function validateHandover(data) {
  const payload = data || {};
  return {
    note: text(payload.note, "Handover note", MAX_HANDOVER_NOTE_LEN),
    photoUrls: checkHandoverPhotos(payload.photoUrls),
  };
}

/**
 * Records the site handover (photos + note) on the job's timeline -
 * evidence for disputes, not a payment gate. One per task: a fixed event id
 * makes a second attempt fail with `already-exists` rather than overwrite.
 */
exports.recordHandover = functions.https.onCall(async (data, context) => {
  const uid = callerUid(context);
  const jobId = docId(data?.jobId, "Job");
  const {note, photoUrls} = validateHandover(data);

  const db = admin.firestore();
  const jobRef = db.doc(`jobs/${jobId}`);
  const userRef = db.doc(`users/${uid}`);
  const eventRef = jobRef.collection("events").doc("handover");

  await db.runTransaction(async (tx) => {
    const [jobSnap, userSnap, eventSnap] =
        await tx.getAll(jobRef, userRef, eventRef);
    const job = jobSnap.data();
    if (!job) {
      throw new functions.https.HttpsError(
          "not-found", "That job no longer exists.");
    }
    if (userSnap.data()?.suspended === true) {
      throw new functions.https.HttpsError(
          "permission-denied",
          "Your account is suspended. Contact support if you think this " +
          "is a mistake.");
    }
    if (job.acceptedProviderId !== uid) {
      throw new functions.https.HttpsError(
          "permission-denied",
          "Only the accepted provider can record a handover.");
    }
    if (job.status !== "in_progress") {
      throw bad("This job is not in progress.");
    }
    if (!job.startsAfterJobId) {
      throw bad("This task does not depend on another task.");
    }
    if (eventSnap.exists) {
      throw new functions.https.HttpsError(
          "already-exists",
          "A handover has already been recorded for this task.");
    }

    tx.set(eventRef, {
      type: "handover",
      title: "Site handover recorded",
      note,
      photoUrls,
      by: uid,
      at: FieldValue.serverTimestamp(),
    });
    notifyUser(tx, job.requestorId, {
      type: "handover",
      title: "Site handover recorded",
      body: `${userSnap.data()?.displayName || "The provider"} recorded ` +
          `the site handover for "${job.title || "a task"}".`,
      route: `/jobs/${jobId}`,
    });
  });

  return {ok: true};
});

// ---------------------------------------------------------------------------
// Phase 5: trust/reviews count a bundle once per participant, not once per
// task.
// ---------------------------------------------------------------------------

/**
 * Which of a completed job's participants are still due their first
 * `jobsCompleted` bump for this bundle. `alreadyCounted` is the subset that
 * already has a `bundles/{bundleId}/completionCounts/{uid}` marker; for a
 * job with no bundle, pass an empty array and everyone is due the bump.
 */
function uidsToCount(participants, alreadyCounted) {
  return participants.filter((uid) => !alreadyCounted.includes(uid));
}

// Exported for bundles.test.js only. index.js re-exports just the
// callables, and the Firebase CLI deploys only what index.js exports.
exports.validateBundle = validateBundle;
exports.validateBundleBid = validateBundleBid;
exports.checkLots = checkLots;
exports.bundleBiddingOpen = bundleBiddingOpen;
exports.splitBundlePrice = splitBundlePrice;
exports.startsWhenText = startsWhenText;
exports.handoverNotificationBody = handoverNotificationBody;
exports.validateHandover = validateHandover;
exports.uidsToCount = uidsToCount;

// Shared with bundle_award.js and the posting assist in index.js.
exports.CATEGORIES = CATEGORIES;
exports.callerUid = callerUid;
exports.bad = bad;
exports.docId = docId;
